/// Secure connect / dApp session configuration.
///
/// Values mirror [config/connect.yaml]. Deep-link registration lives in
/// [DeepLinkHandler]; WalletConnect uses [WalletConnectService]; first-party
/// pairing uses [NativeConnectService].
library;

/// WalletConnect Cloud project id from `--dart-define=WALLETCONNECT_PROJECT_ID=...`
const String kWalletConnectProjectId = String.fromEnvironment(
  'WALLETCONNECT_PROJECT_ID',
  defaultValue: '',
);

const String kWalletConnectRelayUrl = 'wss://relay.walletconnect.com';

const String kWalletName = 'Zunia';
const String kWalletDescription = 'Multi-chain Cosmos wallet';
const String kWalletUrl = 'https://zunialab.com';
const String kWalletIconUrl =
    'https://raw.githubusercontent.com/Zunia-Lab/zunia-brand/main/png/icons/app/zunia-icon-512.png';

const String kAndroidApplicationId = 'com.zuniawallet.zunia_mobile';
const String kIosBundleId = 'com.zuniawallet.zuniaMobile';

/// Custom URL schemes registered in AndroidManifest / Info.plist.
const List<String> kCustomUrlSchemes = ['zunia', 'zuniamobile'];

/// HTTPS paths claimed via Universal Links / App Links.
const List<String> kUniversalLinkHosts = [
  'zunialab.com',
  'link.zunialab.com',
];

const List<String> kUniversalLinkPaths = ['/wc', '/connect'];

/// Cosmos WalletConnect methods the wallet intends to support.
const List<String> kCosmosWcMethods = [
  'cosmos_getAccounts',
  'cosmos_signAmino',
  'cosmos_signDirect',
  'cosmos_signArbitrary',
];

const List<String> kCosmosWcEvents = [
  'accountsChanged',
  'chainChanged',
];

const bool kRequireUserApproval = true;
const bool kRequireTxPreview = true;
const bool kStrictNamespace = true;
const bool kCleartextTrafficAllowed = false;

/// Public WebSocket base for native connect (no trailing slash).
/// Override with `--dart-define=CONNECT_WS_PUBLIC_URL=wss://api.example`.
const String kConnectWsPublicUrl = String.fromEnvironment(
  'CONNECT_WS_PUBLIC_URL',
  defaultValue: 'ws://localhost:8788',
);

/// HTTP API base for native connect session lookup.
/// Override with `--dart-define=ZUNIA_CONNECT_API_BASE=https://api.example`.
/// When empty, derived from [kConnectWsPublicUrl].
const String kConnectApiBase = String.fromEnvironment(
  'ZUNIA_CONNECT_API_BASE',
  defaultValue: '',
);

const String kConnectProtocolVersion = 'zunia.connect.v1';
const String kConnectWsPath = '/v1/connect/ws';
const String kConnectHttpPath = '/v1/connect/sessions';
const int kConnectPairedTtlSeconds = 86400;

/// Resolved HTTP origin for session create/get/delete.
String connectApiBaseUrl() {
  final explicit = kConnectApiBase.trim();
  if (explicit.isNotEmpty) return explicit.replaceAll(RegExp(r'/+$'), '');
  final ws = kConnectWsPublicUrl.replaceAll(RegExp(r'/+$'), '');
  if (ws.startsWith('wss://')) return 'https://${ws.substring(6)}';
  if (ws.startsWith('ws://')) return 'http://${ws.substring(5)}';
  return 'http://localhost:8788';
}

String connectWsBaseUrl() =>
    kConnectWsPublicUrl.replaceAll(RegExp(r'/+$'), '');

/// Wallet role WS URL for a pairing secret.
String connectWalletWsUrl({
  required String sessionId,
  required String pairingSecret,
}) {
  final base = connectWsBaseUrl();
  final sid = Uri.encodeComponent(sessionId);
  final token = Uri.encodeComponent(pairingSecret);
  return '$base$kConnectWsPath?sid=$sid&role=wallet&token=$token';
}

String connectSessionHttpUrl(String sessionId) =>
    '${connectApiBaseUrl()}$kConnectHttpPath/${Uri.encodeComponent(sessionId)}';
