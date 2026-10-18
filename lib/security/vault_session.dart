/// Everything that opens, changes or closes the vault, in one place: unlock
/// (password or biometrics), lock, accounts (add, restore, remove, switch,
/// rename), change password, reveal phrase, biometric set-up, and removing
/// the wallet from the device.
///
/// Screens call this rather than the keystore so the session ([sessionProvider],
/// [phraseProvider]), the account index ([walletProvider]) and the biometric
/// secret never drift apart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/crypto/wallet_kernel.dart';
import 'package:zunia_mobile/providers.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/security/clipboard_guard.dart';
import 'package:zunia_mobile/state/security_settings.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

/// True once the wallet was unlocked in this run of the app. From then on a
/// lock covers the app instead of replacing it, so navigation survives.
final hasUnlockedProvider = StateProvider<bool>((ref) => false);

/// Bumped on every lock. Screens that hold a secret of their own (a revealed
/// phrase) listen and drop it.
final lockEpochProvider = StateProvider<int>((ref) => 0);

/// What [VaultSession.changePassword] could keep.
enum BiometricOutcome { notEnabled, kept, turnedOff }

class VaultSession {
  VaultSession(this._ref, {Future<void> Function()? wipeOtherSecrets})
      : _wipeOtherSecrets = wipeOtherSecrets ?? _wipePlatformSecrets;

  final Ref _ref;
  final Future<void> Function() _wipeOtherSecrets;

  Keystore get _keystore => _ref.read(keystoreProvider);
  BiometricVault get _bio => _ref.read(biometricVaultProvider);
  WalletController get _wallet => _ref.read(walletProvider.notifier);
  SecuritySettingsController get _settings =>
      _ref.read(securitySettingsProvider.notifier);

  bool get isUnlocked => _ref.read(sessionProvider) != null;

  // -- unlock / lock ---------------------------------------------------------

  /// Throws [WrongPasswordException], [PasswordThrottledException] or
  /// [KeystoreException].
  Future<void> unlockWithPassword(String password) async =>
      begin(await openVault(password));

  /// The first half of an unlock: opens every phrase (and migrates an old
  /// vault) without touching the session, so a screen can show an error
  /// while it is still on screen, then call [begin].
  Future<VaultUnlock> openVault(String password) => _keystore.unlock(password);

  /// The second half: makes [result] the unlocked session.
  Future<void> begin(VaultUnlock result) => _open(result);

  /// Reads the password from the hardware-bound store and unlocks with it.
  /// Throws [BiometricException]; a stored password that no longer opens the
  /// vault turns biometric unlock off and reports
  /// [BiometricFailure.invalidated].
  Future<void> unlockWithBiometrics(BiometricPromptText prompt) async {
    final password = await passwordFromBiometrics(prompt);
    try {
      await unlockWithPassword(password);
    } on WrongPasswordException {
      await disableBiometrics();
      throw const BiometricException(BiometricFailure.invalidated);
    }
  }

  Future<void> _open(VaultUnlock result) async {
    await _wallet.reconcile(result);
    final wallet = _ref.read(walletProvider);
    final active = wallet.active;
    // Phrase before session: the gate swaps to the wallet on the session, and
    // the wallet's first frame should already have its addresses.
    _ref.read(phraseProvider.notifier).state =
        active == null ? null : result.phrases[active.phraseId];
    _ref.read(sessionProvider.notifier).state =
        UnlockedVault(phrases: result.phrases);
    _ref.read(hasUnlockedProvider.notifier).state = true;
  }

  /// Wipes the phrases from memory. The lock screen covers whatever was open.
  void lock() {
    if (_ref.read(sessionProvider) == null &&
        _ref.read(phraseProvider) == null) {
      return;
    }
    _ref.read(phraseProvider.notifier).state = null;
    _ref.read(sessionProvider.notifier).state = null;
    _ref.read(lockEpochProvider.notifier).state++;
    unawaited(ClipboardGuard.clearIfArmed());
  }

  // -- password checks -------------------------------------------------------

  /// Throttled, like every password check.
  Future<void> verifyPassword(String password) =>
      _keystore.verifyPassword(password);

  Future<ThrottleState> throttle() => _keystore.throttle();

  // -- biometrics ------------------------------------------------------------

  Future<BiometricAvailability> biometricAvailability() => _bio.availability();

  /// Biometric unlock is on and its secret is still there. Notices when
  /// enrolment changed (the secret vanished) and turns the setting off.
  Future<bool> biometricsReady() async {
    await _settings.ready;
    if (!_ref.read(securitySettingsProvider).biometricUnlock) return false;
    if (await _bio.hasSecret()) return true;
    biometricsWereInvalidated = true;
    await _settings.setBiometricUnlock(false);
    return false;
  }

  /// True when biometric unlock was on and the device's enrolment changed
  /// since; [biometricsReady] turned it off. Shown once on the unlock screen.
  bool biometricsWereInvalidated = false;

  Future<String> passwordFromBiometrics(BiometricPromptText prompt) async {
    try {
      return await _bio.read(prompt);
    } on BiometricException catch (e) {
      if (e.failure == BiometricFailure.invalidated ||
          e.failure == BiometricFailure.notFound) {
        biometricsWereInvalidated = true;
        await disableBiometrics();
        throw const BiometricException(BiometricFailure.invalidated);
      }
      rethrow;
    }
  }

  /// Checks [password], then stores it behind the biometric key (prompts).
  Future<void> enableBiometrics(
    String password,
    BiometricPromptText prompt,
  ) async {
    final availability = await _bio.availability();
    if (!availability.available) {
      throw const BiometricException(BiometricFailure.unavailable);
    }
    await _keystore.verifyPassword(password);
    await _bio.store(password, prompt);
    biometricsWereInvalidated = false;
    await _settings.setBiometricUnlock(true);
  }

  Future<void> disableBiometrics() async {
    await _bio.delete();
    await _settings.setBiometricUnlock(false);
  }

  // -- accounts --------------------------------------------------------------

  /// Seals [phrase] as a new account and switches to it. [password] must be
  /// the wallet's (checked, throttled). Refuses a phrase already present.
  Future<WalletAccount> addAccount({
    required String phrase,
    required String password,
    required String name,
    List<String>? enabledChainIds,
    bool backupVerified = false,
  }) async {
    final session = _ref.read(sessionProvider);
    if (session == null) throw KeystoreException('Unlock the wallet first');
    final normalized = WalletKernel.normalizePhrase(phrase);
    if (session.phrases.values.contains(normalized)) {
      throw KeystoreException('This recovery phrase is already in this wallet.');
    }
    final phraseId =
        await _keystore.addPhrase(phrase: normalized, password: password);
    _ref.read(sessionProvider.notifier).state =
        session.withPhrase(phraseId, normalized);
    return _wallet.addPhraseAccount(
      name: name,
      phraseId: phraseId,
      wordCount: normalized.split(' ').length,
      enabledChainIds: enabledChainIds,
      backupVerified: backupVerified,
    );
  }

  /// Removes an account after checking [password]. Its phrase is erased from
  /// the device when no other account uses it. Refuses the last account.
  Future<void> removeAccount(String accountId, String password) async {
    final wallet = _ref.read(walletProvider);
    if (wallet.accounts.length <= 1) {
      throw KeystoreException(
        'Keep at least one account. Remove the wallet to remove the last one.',
      );
    }
    await _keystore.verifyPassword(password);
    final orphan = await _wallet.removeAccount(accountId);
    if (orphan == null) return;
    await _keystore.removePhrase(orphan);
    final session = _ref.read(sessionProvider);
    if (session != null) {
      _ref.read(sessionProvider.notifier).state = session.withoutPhrase(orphan);
    }
  }

  Future<void> switchAccount(String accountId) =>
      _wallet.selectAccount(accountId);

  Future<void> renameAccount(String accountId, String name) =>
      _wallet.renameAccount(accountId, name);

  Future<void> markBackupVerified(String phraseId) =>
      _wallet.setBackupVerified(phraseId, true);

  /// The phrase of [phraseId], after checking [password] against it.
  Future<String> revealPhrase(String phraseId, String password) =>
      _keystore.revealPhrase(phraseId: phraseId, password: password);

  // -- password --------------------------------------------------------------

  /// Re-seals every phrase under [next]. Biometric unlock keeps working only
  /// if the new password can be stored behind the biometric key (Android
  /// asks for the fingerprint again); otherwise it is turned off.
  Future<BiometricOutcome> changePassword({
    required String current,
    required String next,
    required BiometricPromptText prompt,
  }) async {
    await _keystore.changePassword(current: current, next: next);
    await _settings.ready;
    if (!_ref.read(securitySettingsProvider).biometricUnlock) {
      return BiometricOutcome.notEnabled;
    }
    try {
      await _bio.store(next, prompt);
      return BiometricOutcome.kept;
    } on BiometricException {
      // The old password must not stay behind the biometric key.
      await disableBiometrics();
      return BiometricOutcome.turnedOff;
    }
  }

  // -- removal ---------------------------------------------------------------

  /// Erases the wallet from this device: every sealed phrase, the biometric
  /// secret, Connect and WalletConnect sessions, site permissions, address
  /// book, account index and caches. Display preferences and security
  /// settings stay, as in the extension. With [password], it is checked
  /// first; without (forgotten password), the caller made the user confirm.
  Future<void> removeWallet({String? password}) async {
    if (password != null) await _keystore.verifyPassword(password);
    try {
      await _ref.read(nativeConnectProvider).disconnectAll();
    } catch (e) {
      debugPrint('remove wallet: connect sessions: $e');
    }
    try {
      await _ref.read(walletConnectProvider).disconnectAll();
    } catch (e) {
      debugPrint('remove wallet: walletconnect sessions: $e');
    }
    lock();
    await _keystore.wipe();
    await _bio.delete();
    await _settings.setBiometricUnlock(false);
    await _wallet.clear();
    await _wipeOtherSecrets();
    await clearWalletPreferences(await SharedPreferences.getInstance());
    _ref.read(hasUnlockedProvider.notifier).state = false;
  }

  static Future<void> _wipePlatformSecrets() async {
    // Every secret the app keeps is in this store (Connect sessions too).
    try {
      await createSecureStorage().deleteAll();
      await createVaultStorage().deleteAll();
    } catch (e) {
      debugPrint('remove wallet: secure storage: $e');
    }
  }
}

/// Keys under `zunia.` that survive removing the wallet: how the app looks
/// and how it locks. Everything else (accounts, address book, site
/// permissions, custom chains, caches) belongs to the wallet that is gone.
const _keptPrefixes = ['zunia.prefs.', 'zunia.security.'];

@visibleForTesting
Future<void> clearWalletPreferences(SharedPreferences prefs) async {
  for (final key in prefs.getKeys().toList()) {
    if (!key.startsWith('zunia.')) continue;
    if (_keptPrefixes.any(key.startsWith)) continue;
    await prefs.remove(key);
  }
}

final vaultSessionProvider = Provider<VaultSession>((ref) => VaultSession(ref));
