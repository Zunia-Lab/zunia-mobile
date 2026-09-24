/// Secure connect / dApp session configuration.
///
/// Values mirror [config/connect.yaml]. Deep-link registration lives in
/// [DeepLinkHandler]; WalletConnect uses [WalletConnectService]; first-party
/// pairing uses [NativeConnectService].
library;

import 'package:flutter/foundation.dart';
import 'package:zunia_mobile/connect/pairing_uri.dart';

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

/// The relay the Zunia SDK pairs through by default.
const String kDefaultConnectRelay = 'wss://api.zunialab.com';

/// A self-hosted relay, e.g. for development:
/// `--dart-define=CONNECT_WS_PUBLIC_URL=ws://192.168.1.10:8788`.
const String kConnectWsPublicUrl = String.fromEnvironment('CONNECT_WS_PUBLIC_URL');

/// More relays to trust, comma separated:
/// `--dart-define=ZUNIA_CONNECT_TRUSTED_RELAYS=wss://relay.example.com`.
const String kExtraTrustedRelays =
    String.fromEnvironment('ZUNIA_CONNECT_TRUSTED_RELAYS');

/// Relays the wallet pairs through. A relay tells the wallet which site
/// created a session, so an untrusted relay could lie about it: codes that
/// name any other relay are refused.
List<String> trustedConnectRelays() => [
      kDefaultConnectRelay,
      for (final relay in kExtraTrustedRelays.split(','))
        if (relay.trim().isNotEmpty) relay.trim(),
      if (kConnectWsPublicUrl.trim().isNotEmpty) kConnectWsPublicUrl.trim(),
    ];

/// Debug builds also accept relays on this machine or the local network.
RelayPolicy connectRelayPolicy() =>
    RelayPolicy(trusted: trustedConnectRelays(), allowLocal: kDebugMode);
