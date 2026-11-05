/// What this build is, as sites and the About screen see it.
library;

/// The app release. Kept equal to `version:` in pubspec.yaml.
const appVersion = '0.1.0';

/// The provider API a site talks to: the same contract the extension's
/// `window.zunia` implements (`version` there). It changes only when the API
/// does, never with a release.
const providerApiVersion = '0.1.0';

/// `mode` on the provider: how the site reached this wallet.
const providerMode = 'mobile';

/// What this build can sign beyond the 0.1.0 baseline, in the extension's
/// vocabulary (zunia-extension/lib/provider-identity.ts), so a site can ask
/// one question of either product. The kernel is zunia-core 0.1.1, the same
/// one extension 0.1.5 ships, so the list is the same.
const providerFeatures = <String>[
  'sign-direct:wasm-contract-32',
  'sign-direct:send-32',
  'sign-direct:osmosis-poolmanager',
  'sign-direct:osmosis-exact-out',
  'sign-amino:escaped',
  'sign-amino:osmosis-poolmanager',
];

/// The extension release whose behaviour this build matches.
const extensionParity = '0.1.5';
