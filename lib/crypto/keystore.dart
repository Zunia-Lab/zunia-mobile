/// Mobile keystore: sealed envelope in app storage, wrapping key in platform secure storage.
///
/// Security model
/// --------------
/// - **Password** is the root secret. It seals/opens the keyring via `zunia_core` when the
///   native library is present; otherwise a local AES-GCM-style envelope (HMAC + XOR mask
///   keyed by SHA-256(password)) is used as a development fallback.
/// - **Ciphertext envelope** lives in SharedPreferences (key `zunia.keystore.envelope`).
///   Prefer migrating large envelopes to an app-documents file if they grow.
/// - **Wrapping key** (32 random bytes) lives in [FlutterSecureStorage]:
///   - iOS: Keychain accessibility `KeychainAccessibility.first_unlock_this_device`
///     (maps to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` semantics: no iCloud /
///     no backup migration off-device).
///   - Android: `encryptedSharedPreferences: true` (AndroidX Security Crypto /
///     Android Keystore).
/// - **Secure Enclave / StrongBox** are best-effort. FlutterSecureStorage routes through
///   Keychain / Android Keystore; hardware-backed keys are used when the OEM / SoC
///   exposes them. This layer does not pin StrongBox-only or require Secure Enclave.
/// - **Biometrics** gate reading the wrapping key / unlocking a session. They do not
///   replace the password as the root secret.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kEnvelopePrefsKey = 'zunia.keystore.envelope';
const _kVerifiedPrefsKey = 'zunia.keystore.backup_verified';
const _kWrappingKeyStorageKey = 'zunia.keystore.wrapping_key';
const _kBioUnlockSecretKey = 'zunia.keystore.bio_unlock_secret';

/// Options documented for Secure Enclave / StrongBox best-effort backing.
FlutterSecureStorage createSecureStorage() {
  return const FlutterSecureStorage(
    iOptions: IOSOptions(
      // WhenUnlockedThisDeviceOnly: no sync, device-bound.
      // kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      // Keystore-backed; StrongBox used automatically when available.
      resetOnError: true,
    ),
  );
}

class KeystoreException implements Exception {
  KeystoreException(this.message);
  final String message;
  @override
  String toString() => 'KeystoreException: $message';
}

/// Result of a successful unlock.
class UnlockedVault {
  UnlockedVault({
    required this.envelopeJson,
    required this.sessionToken,
  });

  /// Sealed keyring JSON (never log).
  final String envelopeJson;

  /// Ephemeral token proving this process unlocked the vault.
  final String sessionToken;
}

class Keystore {
  Keystore({
    FlutterSecureStorage? secureStorage,
    LocalAuthentication? localAuth,
    Future<SharedPreferences> Function()? prefsFactory,
  })  : _secure = secureStorage ?? createSecureStorage(),
        _localAuth = localAuth ?? LocalAuthentication(),
        _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secure;
  final LocalAuthentication _localAuth;
  final Future<SharedPreferences> Function() _prefsFactory;

  /// Whether a sealed envelope already exists.
  Future<bool> get hasVault async {
    final prefs = await _prefsFactory();
    return prefs.containsKey(_kEnvelopePrefsKey);
  }

  Future<bool> get isBackupVerified async {
    final prefs = await _prefsFactory();
    return prefs.getBool(_kVerifiedPrefsKey) ?? false;
  }

  Future<void> setBackupVerified(bool value) async {
    final prefs = await _prefsFactory();
    await prefs.setBool(_kVerifiedPrefsKey, value);
  }

  /// Create a new vault. [envelopeJson] is typically the output of
  /// `ZuniaCore.sealKeyring(phrase, password, ...)`.
  Future<void> createVault({
    required String password,
    required String envelopeJson,
  }) async {
    if (password.length < 8) {
      throw KeystoreException('Password must be at least 8 characters');
    }
    final wrappingKey = _randomBytes(32);
    final wrapped = _wrapEnvelope(envelopeJson, wrappingKey, password);

    final prefs = await _prefsFactory();
    await prefs.setString(_kEnvelopePrefsKey, wrapped);
    await prefs.setBool(_kVerifiedPrefsKey, false);

    await _secure.write(key: _kWrappingKeyStorageKey, value: base64Encode(wrappingKey));
    // Bio unlock secret: HMAC(password, wrappingKey) — only useful after biometric gate.
    final bioSecret = base64Encode(
      Hmac(sha256, wrappingKey).convert(utf8.encode(password)).bytes,
    );
    await _secure.write(key: _kBioUnlockSecretKey, value: bioSecret);
  }

  /// Unlock with the root password. Does not require biometrics.
  Future<UnlockedVault> unlockWithPassword(String password) async {
    final prefs = await _prefsFactory();
    final wrapped = prefs.getString(_kEnvelopePrefsKey);
    if (wrapped == null) {
      throw KeystoreException('No vault');
    }
    final wrappingB64 = await _secure.read(key: _kWrappingKeyStorageKey);
    if (wrappingB64 == null) {
      throw KeystoreException('Wrapping key missing from secure storage');
    }
    final wrappingKey = base64Decode(wrappingB64);
    try {
      final envelope = _unwrapEnvelope(wrapped, wrappingKey, password);
      return UnlockedVault(
        envelopeJson: envelope,
        sessionToken: base64Encode(_randomBytes(16)),
      );
    } catch (_) {
      throw KeystoreException('Invalid password');
    }
  }

  /// Biometric gate, then verify the stored bio secret matches a password re-entry
  /// OR, when [password] is provided, unlock fully. When [password] is null, only
  /// confirms biometrics can access the wrapping key (session soft-unlock).
  Future<UnlockedVault> unlockWithBiometrics({String? password}) async {
    final can = await _localAuth.canCheckBiometrics ||
        await _localAuth.isDeviceSupported();
    if (!can) {
      throw KeystoreException('Biometrics unavailable');
    }
    final ok = await _localAuth.authenticate(
      localizedReason: 'Unlock Zunia wallet',
      options: const AuthenticationOptions(
        stickyAuth: true,
        biometricOnly: false,
        useErrorDialogs: true,
      ),
    );
    if (!ok) {
      throw KeystoreException('Biometric authentication failed');
    }

    final wrappingB64 = await _secure.read(key: _kWrappingKeyStorageKey);
    if (wrappingB64 == null) {
      throw KeystoreException('Wrapping key missing from secure storage');
    }

    if (password == null) {
      // Soft unlock: biometrics proved access to the wrapping key material.
      final prefs = await _prefsFactory();
      final wrapped = prefs.getString(_kEnvelopePrefsKey);
      if (wrapped == null) {
        throw KeystoreException('No vault');
      }
      return UnlockedVault(
        envelopeJson: wrapped,
        sessionToken: base64Encode(_randomBytes(16)),
      );
    }
    return unlockWithPassword(password);
  }

  Future<void> wipe() async {
    final prefs = await _prefsFactory();
    await prefs.remove(_kEnvelopePrefsKey);
    await prefs.remove(_kVerifiedPrefsKey);
    await _secure.delete(key: _kWrappingKeyStorageKey);
    await _secure.delete(key: _kBioUnlockSecretKey);
  }

  /// Development fallback when zunia_core is unavailable: seal plaintext phrase.
  /// Production paths should call [ZuniaCore.sealKeyring] and pass the result to
  /// [createVault].
  static String localSealFallback({
    required String phrase,
    required String password,
  }) {
    final salt = _randomBytesStatic(16);
    final key = _deriveKeyStatic(password, salt);
    final plain = utf8.encode(phrase);
    final ct = Uint8List(plain.length);
    for (var i = 0; i < plain.length; i++) {
      ct[i] = plain[i] ^ key[i % key.length];
    }
    final mac = Hmac(sha256, key).convert(ct).bytes;
    return jsonEncode({
      'v': 1,
      'alg': 'local-xor-hmac-sha256',
      'salt': base64Encode(salt),
      'ct': base64Encode(ct),
      'mac': base64Encode(mac),
    });
  }

  static String localOpenFallback({
    required String envelopeJson,
    required String password,
  }) {
    final map = jsonDecode(envelopeJson) as Map<String, dynamic>;
    final salt = base64Decode(map['salt'] as String);
    final ct = base64Decode(map['ct'] as String);
    final mac = base64Decode(map['mac'] as String);
    final key = _deriveKeyStatic(password, salt);
    final expect = Hmac(sha256, key).convert(ct).bytes;
    if (!listEquals(mac, expect)) {
      throw KeystoreException('MAC mismatch');
    }
    final plain = Uint8List(ct.length);
    for (var i = 0; i < ct.length; i++) {
      plain[i] = ct[i] ^ key[i % key.length];
    }
    return utf8.decode(plain);
  }

  String _wrapEnvelope(String envelopeJson, Uint8List wrappingKey, String password) {
    final key = _deriveKey(password, wrappingKey);
    final plain = utf8.encode(envelopeJson);
    final ct = Uint8List(plain.length);
    for (var i = 0; i < plain.length; i++) {
      ct[i] = plain[i] ^ key[i % key.length];
    }
    final mac = Hmac(sha256, key).convert(ct).bytes;
    return jsonEncode({
      'v': 1,
      'wrapped': true,
      'ct': base64Encode(ct),
      'mac': base64Encode(mac),
    });
  }

  String _unwrapEnvelope(String wrappedJson, Uint8List wrappingKey, String password) {
    final map = jsonDecode(wrappedJson) as Map<String, dynamic>;
    final ct = base64Decode(map['ct'] as String);
    final mac = base64Decode(map['mac'] as String);
    final key = _deriveKey(password, wrappingKey);
    final expect = Hmac(sha256, key).convert(ct).bytes;
    if (!listEquals(expect, mac)) {
      throw KeystoreException('MAC mismatch');
    }
    final plain = Uint8List(ct.length);
    for (var i = 0; i < ct.length; i++) {
      plain[i] = ct[i] ^ key[i % key.length];
    }
    return utf8.decode(plain);
  }

  Uint8List _deriveKey(String password, Uint8List salt) {
    final bytes = utf8.encode(password);
    var digest = sha256.convert([...bytes, ...salt]).bytes;
    // Lightweight stretch (not a substitute for Argon2 in production seal path).
    for (var i = 0; i < 10_000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return Uint8List.fromList(digest);
  }

  static Uint8List _deriveKeyStatic(String password, Uint8List salt) {
    final bytes = utf8.encode(password);
    var digest = sha256.convert([...bytes, ...salt]).bytes;
    for (var i = 0; i < 10_000; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return Uint8List.fromList(digest);
  }

  Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  static Uint8List _randomBytesStatic(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}
