import 'package:zunia_mobile/config/connect_config.dart';

/// WalletConnect / Reown session surface.
///
/// [StubWalletConnectService] is the default. Wire [ReownWalletConnectService]
/// once a project id is present and platform plugins are initialized.
abstract class WalletConnectService {
  Future<void> init();
  Future<void> pair(String uri);
  Future<void> disconnectAll();
  Stream<Uri> get pendingPairings;
  bool get isReady;
}

/// No-op implementation used until Reown is configured.
class StubWalletConnectService implements WalletConnectService {
  @override
  bool get isReady => false;

  @override
  Stream<Uri> get pendingPairings => const Stream.empty();

  @override
  Future<void> init() async {}

  @override
  Future<void> pair(String uri) async {
    throw UnsupportedError(
      'WalletConnect is not configured. Set WALLETCONNECT_PROJECT_ID.',
    );
  }

  @override
  Future<void> disconnectAll() async {}
}

/// Placeholder that records intent to use `reown_walletkit` once project id is set.
///
/// Importing ReownWalletKit eagerly pulls heavy native deps; construct this only
/// after [kWalletConnectProjectId] is non-empty and call platform init from UI.
class ReownWalletConnectService implements WalletConnectService {
  ReownWalletConnectService({String? projectId})
      : projectId = projectId ?? kWalletConnectProjectId;

  final String projectId;
  bool _ready = false;

  @override
  bool get isReady => _ready && projectId.isNotEmpty;

  @override
  Stream<Uri> get pendingPairings => const Stream.empty();

  @override
  Future<void> init() async {
    if (projectId.isEmpty) {
      throw StateError('WALLETCONNECT_PROJECT_ID is empty');
    }
    // Wire ReownWalletKit.init(projectId: projectId, metadata: ...) here.
    // Kept as a stub body so analyze/test stay free of mandatory WC runtime.
    _ready = true;
  }

  @override
  Future<void> pair(String uri) async {
    if (!isReady) await init();
    // await _kit.pair(uri: Uri.parse(uri));
  }

  @override
  Future<void> disconnectAll() async {}
}

WalletConnectService createWalletConnectService() {
  if (kWalletConnectProjectId.isEmpty) {
    return StubWalletConnectService();
  }
  return ReownWalletConnectService();
}
