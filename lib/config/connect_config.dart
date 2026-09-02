/// Secure connect / dApp session configuration.
///
/// Values mirror [config/connect.yaml]. Deep-link registration lives in
/// [DeepLinkHandler]; WalletConnect uses [WalletConnectService].
library;

/// WalletConnect Cloud project id from `--dart-define=WALLETCONNECT_PROJECT_ID=...`
const String kWalletConnectProjectId = String.fromEnvironment(
  'WALLETCONNECT_PROJECT_ID',
  defaultValue: '',
);

const String kWalletConnectRelayUrl = 'wss://relay.walletconnect.com';

const String kWalletName = 'Zunia';
const String kWalletUrl = 'https://zuniawallet.com';
const String kWalletIconUrl =
    'https://raw.githubusercontent.com/Zunia-Lab/zunia-brand/main/png/icons/app/zunia-icon-512.png';

const String kAndroidApplicationId = 'com.zuniawallet.zunia_mobile';
const String kIosBundleId = 'com.zuniawallet.zuniaMobile';

/// Custom URL schemes registered in AndroidManifest / Info.plist.
const List<String> kCustomUrlSchemes = ['zunia', 'zuniamobile'];

/// HTTPS paths claimed via Universal Links / App Links.
const List<String> kUniversalLinkHosts = [
  'zuniawallet.com',
  'link.zuniawallet.com',
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
