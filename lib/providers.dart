import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/security/biometric_vault.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

// The session lives with the account index it belongs to.
export 'package:zunia_mobile/state/wallet_state.dart' show sessionProvider;

final keystoreProvider = Provider<Keystore>((ref) => Keystore());

final biometricVaultProvider =
    Provider<BiometricVault>((ref) => PlatformBiometricVault());

final walletConnectProvider = Provider<WalletConnectService>((ref) {
  final service = createWalletConnectService();
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final nativeConnectProvider = Provider<NativeConnectService>((ref) {
  final service = NativeConnectService(store: SecureConnectSessionStore());
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

final deepLinkHandlerProvider = Provider<DeepLinkHandler>((ref) {
  return DeepLinkHandler(
    walletConnect: ref.watch(walletConnectProvider),
    nativeConnect: ref.watch(nativeConnectProvider),
  );
});

enum AppGate { loading, onboarding, unlock, ready }

final appGateProvider = FutureProvider<AppGate>((ref) async {
  final ks = ref.watch(keystoreProvider);
  // Before anything reads the vault: the old biometric unlock left the
  // password itself in secure storage, and iOS keeps a deleted app's
  // Keychain items for the next install.
  try {
    await ks.purgeLegacyBiometricSecrets();
  } catch (_) {
    // Retried at the next start; it must not keep the wallet from opening.
  }
  if (await ks.forgetIfReinstalled()) {
    await ref.read(biometricVaultProvider).delete();
  }
  final has = await ks.hasVault;
  if (!has) return AppGate.onboarding;
  return AppGate.unlock;
});

/// Whether the active account's recovery phrase was verified (the user
/// picked the right words). A restored phrase starts unverified.
final backupVerifiedProvider = FutureProvider<bool>((ref) async {
  final wallet = ref.watch(walletProvider);
  final account = wallet.active;
  if (account == null) return false;
  return wallet.phraseOf(account)?.backupVerified ?? false;
});
