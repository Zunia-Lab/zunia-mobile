import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zunia_mobile/crypto/keystore.dart';
import 'package:zunia_mobile/services/deep_link_handler.dart';
import 'package:zunia_mobile/services/wallet_connect_service.dart';

final keystoreProvider = Provider<Keystore>((ref) => Keystore());

final walletConnectProvider = Provider<WalletConnectService>(
  (ref) => createWalletConnectService(),
);

final deepLinkHandlerProvider = Provider<DeepLinkHandler>((ref) {
  return DeepLinkHandler(walletConnect: ref.watch(walletConnectProvider));
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
