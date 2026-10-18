import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/services/connect_session_store.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/native_connect_service.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';
import 'package:zunia_mobile/state/wallet_state.dart';

final keystoreProvider = Provider<Keystore>((ref) => Keystore());

final walletConnectProvider = Provider<WalletConnectService>((ref) {
  final service = createWalletConnectService(
    native: ref.watch(nativeConnectProvider),
    activeAccountIndex: () => ref.read(walletProvider).active?.index ?? 0,
  );
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
  final has = await ks.hasVault;
  if (!has) return AppGate.onboarding;
  return AppGate.unlock;
});

/// Session after unlock; null when locked.
final sessionProvider = StateProvider<UnlockedVault?>((ref) => null);

final backupVerifiedProvider = FutureProvider<bool>((ref) async {
  return ref.watch(keystoreProvider).isBackupVerified;
});
