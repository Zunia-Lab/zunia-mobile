/// Vault v2: every recovery phrase sealed by the kernel, kept in the
/// platform's secret store, and nothing else.
///
/// Security model
/// --------------
/// - **One kernel `KeyringEnvelope` per phrase** (`WalletKernel.sealKeyring`:
///   Argon2id 64 MiB / 3 passes, XChaCha20-Poly1305, random salt and nonce,
///   parameters bound into the tag). There is no second layer on top: the old
///   XOR "wrap" added nothing to the envelope and was itself broken.
/// - **The password is the only key.** Every envelope is sealed with the same
///   password, so one password unlocks every account (as in extension 0.1.5).
///   It is never stored. Biometric unlock keeps a copy behind a hardware-bound
///   key instead (see `lib/security/biometric_vault.dart`).
/// - **Where the envelopes live**: one secret-store item, `zunia.vault.v2`.
///   iOS: Keychain, `first_unlock_this_device` (never synced to iCloud,
///   never restored onto another device). Android: EncryptedSharedPreferences,
///   whose key is in the Android Keystore, in an app that disables backup.
///   One item means a change of password replaces every envelope in a single
///   write: a crash leaves either the old set or the new one, never a mix.
/// - **What is not secret** (account names, which phrase an account uses, its
///   derivation index, avatar seed, backup status) is the account index in
///   SharedPreferences, kept by `lib/state/wallet_state.dart`.
/// - **Password checks** go through one queue and the persisted backoff in
///   `lib/security/password_throttle.dart`, so parallel guesses cannot all see
///   a clean throttle and a relaunch does not reset it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_core/zunia_core.dart' show ZuniaCoreException;
import 'package:zunia_mobile/crypto/legacy_vault.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/security/password_throttle.dart';

export 'package:zunia_mobile/security/password_throttle.dart'
    show PasswordThrottledException, WrongPasswordException, ThrottleState;

const kVaultKey = 'zunia.vault.v2';
const kThrottleKey = 'zunia.vault.throttle';

/// Set in SharedPreferences next to the vault. iOS keeps Keychain items after
/// the app is deleted, SharedPreferences it does not: a vault without this
/// marker was left behind by an earlier install and is erased, as deleting
/// the app is expected to remove the wallet (Android does that by itself).
const kInstallMarkerKey = 'zunia.vault.installed';
const kMinPasswordLength = 8;

/// Secure storage for anything else that is secret (Connect sessions).
///
/// Kept for the callers that already use it. The vault itself goes through
/// [createVaultStorage], whose options differ on purpose.
FlutterSecureStorage createSecureStorage() {
  return const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      // A read error must not erase the store: on Android every secret the
      // app keeps shares one file, and that file holds the vault.
      resetOnError: false,
    ),
  );
}

/// Secure storage for the vault.
///
/// `first_unlock_this_device` rather than `unlocked_this_device`: the
/// envelopes are useless without the password, and a launch in the background
/// before the first unlock of the day must not make the app think the wallet
/// is gone. Both are `ThisDeviceOnly`, so neither syncs nor migrates.
FlutterSecureStorage createVaultStorage() {
  return const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false,
    ),
  );
}

/// The few operations the keystore needs from a secret store.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStore implements SecretStore {
  PlatformSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? createVaultStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store for tests.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial])
      : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Runs a kernel call that may take a while (Argon2id) off the UI isolate.
typedef KernelRunner = Future<R> Function<R>(R Function() task);

bool _isolatesReachKernel = true;

/// Argon2id costs about 100 ms and 64 MiB per envelope on a current phone; on
/// the UI isolate that is a visible stall per account, so it runs on a
/// short-lived isolate. A host test has the kernel only on the main isolate
/// (it is loaded by path), so the first refusal switches to running inline.
Future<R> runOffUiIsolate<R>(R Function() task) async {
  if (!_isolatesReachKernel) return task();
  try {
    return await Isolate.run(task);
  } on KernelUnavailableException {
    _isolatesReachKernel = false;
    return task();
  } on ArgumentError {
    _isolatesReachKernel = false;
    return task();
  }
}

/// Runs inline; for widget tests, whose fake clock does not deliver isolate
/// messages.
Future<R> runInline<R>(R Function() task) async => task();

class KeystoreException implements Exception {
  KeystoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum VaultFormat { none, legacy, v2 }

/// The previous vault was moved to v2 during this unlock.
@immutable
class LegacyMigration {
  const LegacyMigration({required this.phraseId, required this.backupVerified});

  /// Id the migrated phrase was given.
  final String phraseId;

  /// The old single "backup verified" flag, carried over to that phrase.
  final bool backupVerified;
}

/// Every phrase the password opened, by id, in vault order.
@immutable
class VaultUnlock {
  const VaultUnlock({
    required this.phrases,
    this.unreadable = const [],
    this.migration,
  });

  /// phraseId -> phrase. Never log.
  final Map<String, String> phrases;

  /// Envelopes the password did not open although the first one did. Should
  /// never happen (a password change rewrites every envelope at once); kept
  /// out of the session instead of locking the user out of the others.
  final List<String> unreadable;

  final LegacyMigration? migration;
}

/// The phrases the user unlocked, held only while the app is unlocked.
///
/// Dart cannot overwrite a String in place; locking drops every reference so
/// the collector can reclaim them, and the kernel zeroises its own copies.
@immutable
class UnlockedVault {
  UnlockedVault({required Map<String, String> phrases, DateTime? unlockedAt})
      : phrases = Map.unmodifiable(phrases),
        unlockedAt = unlockedAt ?? DateTime.now();

  final Map<String, String> phrases;
  final DateTime unlockedAt;

  String? phraseFor(String phraseId) => phrases[phraseId];

  UnlockedVault withPhrase(String phraseId, String phrase) => UnlockedVault(
        phrases: {...phrases, phraseId: phrase},
        unlockedAt: unlockedAt,
      );

  UnlockedVault withoutPhrase(String phraseId) => UnlockedVault(
        phrases: {...phrases}..remove(phraseId),
        unlockedAt: unlockedAt,
      );
}

@immutable
class _SealedPhrase {
  const _SealedPhrase(this.id, this.envelope);

  factory _SealedPhrase.fromJson(Map<String, dynamic> json) =>
      _SealedPhrase(json['id'] as String, json['envelope'] as String);

  final String id;

  /// Kernel `KeyringEnvelope` JSON.
  final String envelope;

  Map<String, dynamic> toJson() => {'id': id, 'envelope': envelope};
}

class Keystore {
  Keystore({
    SecretStore? secrets,
    Future<SharedPreferences> Function()? prefsFactory,
    KernelRunner? runner,
    DateTime Function()? clock,
  })  : _secrets = secrets ?? PlatformSecretStore(),
        _prefsFactory = prefsFactory ?? SharedPreferences.getInstance,
        _run = runner ?? runOffUiIsolate,
        _now = clock ?? DateTime.now;

  final SecretStore _secrets;
  final Future<SharedPreferences> Function() _prefsFactory;
  final KernelRunner _run;
  final DateTime Function() _now;

  Future<void> _queue = Future.value();

  /// One vault operation at a time. Password checks in particular: parallel
  /// guesses would otherwise all read the same clean throttle.
  Future<T> _serial<T>(Future<T> Function() task) {
    final run = _queue.then((_) => task());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  // -- reading --------------------------------------------------------------

  Future<VaultFormat> format() async {
    if (await _secrets.read(kVaultKey) != null) return VaultFormat.v2;
    final prefs = await _prefsFactory();
    if (prefs.containsKey(kLegacyEnvelopePrefsKey)) return VaultFormat.legacy;
    return VaultFormat.none;
  }

  Future<bool> get hasVault async => await format() != VaultFormat.none;

  /// Ids of the sealed phrases, oldest first.
  Future<List<String>> phraseIds() async =>
      [for (final p in await _readRecord()) p.id];

  Future<ThrottleState> throttle() async =>
      ThrottleState.decode(await _secrets.read(kThrottleKey), _now());

  Future<List<_SealedPhrase>> _readRecord() async {
    final raw = await _secrets.read(kVaultKey);
    if (raw == null) return const [];
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['v'] != 2) {
      throw KeystoreException('Unknown vault version ${map['v']}');
    }
    return [
      for (final row in map['phrases'] as List<dynamic>)
        _SealedPhrase.fromJson(row as Map<String, dynamic>),
    ];
  }

  Future<void> _writeRecord(List<_SealedPhrase> phrases) async {
    await _secrets.write(
      kVaultKey,
      jsonEncode({
        'v': 2,
        'phrases': [for (final p in phrases) p.toJson()],
      }),
    );
  }

  /// Erases a vault an earlier install left in the Keychain (see
  /// [kInstallMarkerKey]). True when it did.
  Future<bool> forgetIfReinstalled() => _serial(() async {
        final prefs = await _prefsFactory();
        if (prefs.getBool(kInstallMarkerKey) ?? false) return false;
        if (await _secrets.read(kVaultKey) == null) return false;
        await _secrets.delete(kVaultKey);
        await _secrets.delete(kThrottleKey);
        return true;
      });

  /// The old biometric unlock kept the password itself in secure storage.
  /// Deleted at every start, before anything else: the new biometric unlock
  /// does not need it, and the migration only needs the typed password.
  Future<void> purgeLegacyBiometricSecrets() async {
    await _secrets.delete(kLegacyBioPasswordKey);
    await _secrets.delete(kLegacyBioUnlockSecretKey);
  }

  // -- password checks -------------------------------------------------------

  /// Opens every phrase with [password]. A vault in the old format is
  /// migrated to v2 here, on its first unlock.
  Future<VaultUnlock> unlock(String password) =>
      _serial(() => _unlockNow(password));

  /// Checks [password] without opening more than one envelope. Used before
  /// a signature when "password on every signature" is on.
  Future<void> verifyPassword(String password) => _serial(() async {
        final record = await _readRecord();
        if (record.isEmpty) {
          if (await format() == VaultFormat.legacy) {
            await _unlockNow(password);
            return;
          }
          throw KeystoreException('No wallet on this device');
        }
        await _checked(() => _open(record.first.envelope, password));
      });

  /// The phrase [phraseId] holds, after checking [password] against it.
  Future<String> revealPhrase({
    required String phraseId,
    required String password,
  }) =>
      _serial(() async {
        final record = await _readRecord();
        final row = record.where((p) => p.id == phraseId).firstOrNull;
        if (row == null) throw KeystoreException('No such recovery phrase');
        return _checked(() => _open(row.envelope, password));
      });

  /// Runs [open] under the throttle: refused while a wait is in force, a
  /// failure extends the wait, a success clears it.
  Future<T> _checked<T>(Future<T> Function() open) async {
    final state = await throttle();
    final now = _now();
    if (state.isThrottledAt(now)) {
      throw PasswordThrottledException(state.waitAt(now));
    }
    final T result;
    try {
      result = await open();
    } on _WrongPassword {
      final next = recordFailure(state, _now());
      await _secrets.write(kThrottleKey, next.encode());
      throw WrongPasswordException(wait: next.waitAt(_now()));
    }
    if (state.failures > 0) await _secrets.delete(kThrottleKey);
    return result;
  }

  Future<String> _open(String envelope, String password) async {
    try {
      return await _run(_openTask(envelope, password));
    } on ZuniaCoreException {
      throw const _WrongPassword();
    }
  }

  Future<String> _seal(
    String phrase,
    String password,
    Map<String, Object?> metadata,
  ) =>
      _run(_sealTask(phrase, password, metadata));

  // Closures built away from `this`, so an isolate is sent strings only.
  static String Function() _openTask(String envelope, String password) =>
      () => WalletKernel.instance
          .openKeyring(envelopeJson: envelope, password: password);

  static String Function() _sealTask(
    String phrase,
    String password,
    Map<String, Object?> metadata,
  ) =>
      () => WalletKernel.instance.sealKeyring(
            phrase: phrase,
            password: password,
            metadata: metadata,
          );

  Future<VaultUnlock> _unlockNow(String password) async {
    final record = await _readRecord();
    if (record.isEmpty) {
      if (await format() == VaultFormat.legacy) {
        return _migrateLegacy(password);
      }
      throw KeystoreException('No wallet on this device');
    }
    final first = await _checked(() => _open(record.first.envelope, password));
    final phrases = <String, String>{record.first.id: first};
    final unreadable = <String>[];
    for (final row in record.skip(1)) {
      try {
        phrases[row.id] = await _open(row.envelope, password);
      } on _WrongPassword {
        unreadable.add(row.id);
      }
    }
    return VaultUnlock(phrases: phrases, unreadable: unreadable);
  }

  // -- migration from the old format ----------------------------------------

  /// Opens the old wrapped envelope, seals the phrase as v2, checks the new
  /// envelope opens, and only then deletes the old data.
  Future<VaultUnlock> _migrateLegacy(String password) async {
    final prefs = await _prefsFactory();
    final wrapped = prefs.getString(kLegacyEnvelopePrefsKey);
    final wrappingKey = await _secrets.read(kLegacyWrappingKey);
    if (wrapped == null || wrappingKey == null) {
      throw KeystoreException(
        'The wallet stored by the previous version is incomplete. Restore it '
        'from your recovery phrase.',
      );
    }
    final phrase = await _checked(() async {
      final LegacyInner inner;
      try {
        inner = LegacyVault.open(
          wrappedJson: wrapped,
          wrappingKeyB64: wrappingKey,
          password: password,
        );
      } on LegacyVaultMacMismatch {
        throw const _WrongPassword();
      }
      return switch (inner) {
        LegacyKernelEnvelope(:final envelopeJson) =>
          _open(envelopeJson, password),
        LegacyPlainPhrase(:final phrase) => Future.value(phrase),
      };
    });
    final normalized = WalletKernel.normalizePhrase(phrase);
    final id = newPhraseId();
    final envelope = await _seal(normalized, password, _metadataFor(normalized));
    // Paranoid: never delete the only copy before the new one is proven.
    final check = await _open(envelope, password);
    if (check != normalized) {
      throw KeystoreException('Could not move the wallet to the new vault');
    }
    // Marker first: a vault without it is taken for a previous install's.
    await prefs.setBool(kInstallMarkerKey, true);
    await _writeRecord([_SealedPhrase(id, envelope)]);

    final verified = prefs.getBool(kLegacyVerifiedPrefsKey) ?? false;
    await prefs.remove(kLegacyEnvelopePrefsKey);
    await prefs.remove(kLegacyVerifiedPrefsKey);
    await _secrets.delete(kLegacyWrappingKey);
    await purgeLegacyBiometricSecrets();
    return VaultUnlock(
      phrases: {id: normalized},
      migration: LegacyMigration(phraseId: id, backupVerified: verified),
    );
  }

  // -- writing ---------------------------------------------------------------

  /// Seals the first phrase of a new wallet. Refuses when one exists.
  Future<String> createVault({
    required String phrase,
    required String password,
  }) =>
      _serial(() async {
        if (await format() != VaultFormat.none) {
          throw KeystoreException('A wallet already exists on this device');
        }
        _checkPasswordShape(password);
        final normalized = _checkedPhrase(phrase);
        final id = newPhraseId();
        final envelope =
            await _seal(normalized, password, _metadataFor(normalized));
        // Marker first: a vault without it is taken for a previous install's.
        await (await _prefsFactory()).setBool(kInstallMarkerKey, true);
        await _writeRecord([_SealedPhrase(id, envelope)]);
        await _secrets.delete(kThrottleKey);
        return id;
      });

  /// Seals another phrase with the wallet's password. The password is
  /// checked against an existing envelope first: a phrase sealed under a
  /// different password would make the next unlock fail.
  Future<String> addPhrase({
    required String phrase,
    required String password,
  }) =>
      _serial(() async {
        final record = await _readRecord();
        if (record.isEmpty) throw KeystoreException('No wallet on this device');
        await _checked(() => _open(record.first.envelope, password));
        final normalized = _checkedPhrase(phrase);
        final id = newPhraseId();
        final envelope =
            await _seal(normalized, password, _metadataFor(normalized));
        await _writeRecord([...await _readRecord(), _SealedPhrase(id, envelope)]);
        return id;
      });

  /// Deletes one sealed phrase. The last one cannot go this way: removing
  /// the wallet is [wipe].
  Future<void> removePhrase(String phraseId) => _serial(() async {
        final record = await _readRecord();
        final next = record.where((p) => p.id != phraseId).toList();
        if (next.length == record.length) return;
        if (next.isEmpty) {
          throw KeystoreException('Keep at least one account');
        }
        await _writeRecord(next);
      });

  /// Re-seals every phrase under [next] in one write.
  Future<void> changePassword({
    required String current,
    required String next,
  }) =>
      _serial(() async {
        _checkPasswordShape(next);
        final record = await _readRecord();
        if (record.isEmpty) throw KeystoreException('No wallet on this device');
        final phrases = <String>[];
        await _checked(() async {
          for (final row in record) {
            phrases.add(await _open(row.envelope, current));
          }
        });
        final resealed = <_SealedPhrase>[];
        for (var i = 0; i < record.length; i++) {
          resealed.add(
            _SealedPhrase(
              record[i].id,
              await _seal(phrases[i], next, _metadataFor(phrases[i])),
            ),
          );
        }
        // Prove the new set before it replaces the old one.
        if (await _open(resealed.first.envelope, next) != phrases.first) {
          throw KeystoreException('Could not re-seal the vault');
        }
        await _writeRecord(resealed);
      });

  /// Erases the vault, the old format and the throttle.
  Future<void> wipe() => _serial(() async {
        await _secrets.delete(kVaultKey);
        await _secrets.delete(kThrottleKey);
        await _secrets.delete(kLegacyWrappingKey);
        await purgeLegacyBiometricSecrets();
        final prefs = await _prefsFactory();
        await prefs.remove(kLegacyEnvelopePrefsKey);
        await prefs.remove(kLegacyVerifiedPrefsKey);
        await prefs.remove(kInstallMarkerKey);
      });

  static void _checkPasswordShape(String password) {
    if (password.length < kMinPasswordLength) {
      throw KeystoreException(
        'Password must be at least $kMinPasswordLength characters',
      );
    }
  }

  static String _checkedPhrase(String phrase) {
    final normalized = WalletKernel.normalizePhrase(phrase);
    if (!WalletKernel.instance.validateMnemonic(normalized)) {
      throw KeystoreException('Invalid recovery phrase');
    }
    return normalized;
  }

  Map<String, Object?> _metadataFor(String phrase) => {
        'createdAt': _now().millisecondsSinceEpoch,
        'wordCount': phrase.split(' ').length,
      };

  static final Random _random = Random.secure();

  /// Opaque id for a sealed phrase. Not derived from the phrase, so the
  /// account index in SharedPreferences says nothing about it.
  static String newPhraseId() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    return 'p-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

class _WrongPassword implements Exception {
  const _WrongPassword();
}
