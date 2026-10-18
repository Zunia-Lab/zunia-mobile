<p align="center">
  <img src="https://raw.githubusercontent.com/Zunia-Lab/zunia-brand/main/png/icons/app/zunia-icon-256.png" alt="Zunia" width="96" />
</p>

# zunia-mobile

> iOS and Android wallet for Zunia, built with **Flutter**. Same keys as the browser extension.

[![License](https://img.shields.io/github/license/Zunia-Lab/zunia-mobile)](LICENSE)
[![Website](https://img.shields.io/badge/website-zunialab.com-FF1B0C)](https://zunialab.com)

## Overview

Non-custodial multi-chain Cosmos wallet, version **0.1.0**, with the features of the Zunia browser extension 0.1.5 and what a phone adds: pairing with sites and apps by QR code or same-phone link, an in-app dApp browser, biometric unlock and local notifications. iOS follows iOS conventions and Android follows Material 3.

| Platform | Output | App id |
|----------|--------|--------|
| Android | APK / App Bundle | `com.zuniawallet.zunia_mobile` |
| iOS | IPA | `com.zuniawallet.zuniaMobile` |

Chain metadata comes from [zunia-chain-registry](https://github.com/Zunia-Lab/zunia-chain-registry). Token names, IBC channels, the swap fee policy and explorer links are copied from the extension by `scripts/sync-extension-data.mjs` into `assets/data/`. Visual tokens and widgets come from [zunia-ui](https://github.com/Zunia-Lab/zunia-ui) (`packages/ui-flutter`, including its per-platform layer). User documentation: [docs.zunialab.com/docs/use-wallet/mobile](https://docs.zunialab.com/docs/use-wallet/mobile/).

## The kernel (`zunia_core`)

Every derivation, seal and signature goes through the Rust kernel, [zunia-core](https://github.com/Zunia-Lab/zunia-core) 0.1.1, the same code the extension runs as WebAssembly. There is no Dart fallback: a build whose kernel does not load shows "This build cannot sign" instead of opening the wallet.

- Dart bindings: `../zunia-core/packages/dart` (path dependency `zunia_core`). On iOS the plugin force-loads the vendored `ZuniaCore.xcframework` slice into its framework.
- Android `.so` libraries come from a signed zunia-core release. The tag is pinned in `config/core_native.env`:

```bash
./scripts/fetch-native.sh            # uses config/core_native.env (ZUNIA_CORE_TAG=v0.1.1)
ZUNIA_CORE_TAG=v0.1.1 ./scripts/fetch-native.sh
```

The script verifies `SHA256SUMS` and installs into `android/app/src/main/jniLibs/` and `ios/Frameworks/` (gitignored).

- Tests load a kernel built for the host: `cargo build -p zunia-ffi --release` in `../zunia-core` (or set `ZUNIA_FFI_LIB`). Tests that need it are skipped when it is missing.
- `lib/tx/tx_engine.dart` is the only transaction path: read the account, simulate, price at the chosen speed, have the kernel preview, check the sign bytes match the preview, sign Direct, broadcast.

## Connecting sites and apps

| What | Where |
|------|-------|
| Zunia Connect v2 (QR or same-phone link, end-to-end encrypted over `wss://api.zunialab.com`) | `lib/services/native_connect_service.dart`, `lib/connect/` |
| Return to the calling app (`ret`) and wake links (`zunia://connect/wake?sid=`) | `lib/connect/app_return.dart`, `lib/connect/connect_links.dart` |
| WalletConnect v2 (`cosmos_getAccounts`, `cosmos_signDirect`, `cosmos_signAmino`, `cosmos_signArbitrary`) | `lib/services/wallet_connect_service.dart` |
| In-app browser provider (`window.zunia`, opt-in `window.keplr`) | `lib/browser/` |
| One review sheet for every request | `lib/screens/native_request_sheets.dart` |
| Deep links, App Links, Universal Links | `lib/services/deep_link_handler.dart`, `AndroidManifest.xml`, `ios/Runner/*.entitlements` |

WalletConnect is active only in builds made with a project id:

```bash
flutter run --dart-define=WALLETCONNECT_PROJECT_ID=$WALLETCONNECT_PROJECT_ID
```

Universal Links and Android App Links need `apple-app-site-association` and `assetlinks.json` on zunialab.com and link.zunialab.com (zunia-infra). Until they are published, only `zunia://` links open the app.

## Keys and security

- Vault: each recovery phrase sealed by the kernel (Argon2id + XChaCha20-Poly1305), kept in the Keychain (this device only) or EncryptedSharedPreferences; no cloud backup or device transfer (`data_extraction_rules.xml`).
- Biometric unlock is hardware-bound: a Keychain item with `.biometryCurrentSet` on iOS, an Android Keystore key used through `BiometricPrompt` with a `CryptoObject` (`ZuniaSecurity.kt`, `AppDelegate.swift`).
- Auto-lock, a password throttle, "password on every signature", change password, screenshot blocking on phrase and password screens, an app-switcher cover. Policy: `config/mnemonic_security.yaml`; code: `lib/crypto/keystore.dart`, `lib/security/`.

## Status

In development. Not on the App Store or Google Play yet.

## Related repositories

| Repository | Description |
|------------|-------------|
| [zunia-extension](https://github.com/Zunia-Lab/zunia-extension) | Browser extension (same keys) |
| [zunia-core](https://github.com/Zunia-Lab/zunia-core) | Wallet kernel + native FFI |
| [zunia-dashboard](https://github.com/Zunia-Lab/zunia-dashboard) | Web portfolio |
| [zunia-chain-registry](https://github.com/Zunia-Lab/zunia-chain-registry) | Chain metadata |
| [zunia-docs](https://github.com/Zunia-Lab/zunia-docs) | Documentation |
| [zunia-website](https://github.com/Zunia-Lab/zunia-website) | Marketing site |
| [zunia-brand](https://github.com/Zunia-Lab/zunia-brand) | Brand assets |
| [zunia-ui](https://github.com/Zunia-Lab/zunia-ui) | Shared design tokens / web UI |
| [zunia-sdk](https://github.com/Zunia-Lab/zunia-sdk) | Developer SDKs (web / Flutter) |

## Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) 3.41+ (stable), Dart 3.11+
- Rust (for host tests only; `rust-toolchain.toml` in zunia-core pins it)
- Xcode (iOS) / Android Studio SDK (Android)
- Optional: `gh` CLI to fetch native release artifacts

```bash
flutter doctor
```

## Quick start

```bash
./scripts/fetch-native.sh   # Android kernel libraries, pinned in config/core_native.env

flutter pub get
flutter run                 # connected device / simulator
flutter run -d ios
flutter run -d android
```

## Build release outputs

```bash
./scripts/fetch-native.sh

# Android App Bundle (Play Store)
flutter build appbundle --release

# Android APK
flutter build apk --release

# iOS (requires signing in Xcode)
flutter build ipa --release
```

Artifacts:

- `build/app/outputs/bundle/release/app-release.aab`
- `build/app/outputs/flutter-apk/app-release.apk`
- `build/ios/ipa/*.ipa`

## Project layout

```
lib/
  main.dart                 # boot: catalog, custom chains, preferences, token table
  crypto/                   # WalletKernel (the Rust kernel), keystore v2, legacy migration
  tx/                       # TxMsg, TxEngine (simulate, preview, sign, broadcast)
  security/                 # vault session, biometrics, auto-lock, signing gate, capture
  connect/                  # Zunia Connect crypto, pairing and wake links, app return
  services/                 # Connect v2, WalletConnect, deep links, chain clients
  browser/                  # in-app provider, grants, review model, origin risk
  tokens/ prices/ portfolio/ transfers/ activity/ swap/ notifications/
  state/                    # Riverpod state
  screens/                  # every screen; screens/tabs/ for the five root tabs
  ui/ widgets/              # app widgets (zunia_ui holds the shared ones)
assets/data/                # copied from the extension (sync-extension-data.mjs)
integration_test/           # screenshot tour
scripts/                    # fetch-native.sh, sync-extension-data.mjs, brand-assets.py
config/                     # core_native.env, connect, interchain, security policy
```

## Development

| Command | Description |
|---------|-------------|
| `flutter run` | Debug on device/simulator |
| `flutter test` | Unit and widget tests (build the host kernel first) |
| `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/tour_test.dart -d <device>` | Walk a real build and save screenshots to `build/shots` (never signs) |
| `node scripts/sync-extension-data.mjs` | Refresh `assets/data/` from the extension |
| `flutter analyze` | Static analysis |
| `./scripts/fetch-native.sh` | Download pinned zunia-core natives |
| `flutter build apk` | Android release APK |
| `flutter build ipa` | iOS release IPA |

## Contributing

See [CONTRIBUTING.md](https://github.com/Zunia-Lab/.github/blob/main/CONTRIBUTING.md).

## Security

See [SECURITY.md](./SECURITY.md). Never include seed phrases in issues or PRs.

## License

Apache-2.0. See [LICENSE](LICENSE).
