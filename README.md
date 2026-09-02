# zunia-mobile

> iOS and Android wallet for Zunia, built with **Flutter**. Same keys as the browser extension.

[![License](https://img.shields.io/github/license/Zunia-Lab/zunia-mobile)](LICENSE)
[![Website](https://img.shields.io/badge/website-zuniawallet.com-2050C4)](https://zuniawallet.com)

## Overview

Non-custodial multi-chain Cosmos wallet. Targets:

| Platform | Output |
|----------|--------|
| Android | APK / App Bundle (`com.zuniawallet.zunia_mobile`) |
| iOS | IPA (`com.zuniawallet.zuniaMobile`) |

Chain metadata comes from [zunia-chain-registry](https://github.com/Zunia-Lab/zunia-chain-registry). Visual tokens follow [zunia-brand](https://github.com/Zunia-Lab/zunia-brand) / [zunia-ui](https://github.com/Zunia-Lab/zunia-ui). Native crypto comes from [zunia-core](https://github.com/Zunia-Lab/zunia-core) GitHub Release artifacts.

## Native FFI (`zunia_core`)

Dart bindings live at `../zunia-core/packages/dart` (path dependency `zunia_core`). Prebuilt Android `.so` libs and the iOS `ZuniaCore.xcframework` are **not** built in this repo. Download them from a signed zunia-core release:

```bash
# Requires GitHub CLI (`gh`) authenticated for private releases; public tags need no token.
export ZUNIA_CORE_TAG=v0.1.0   # pin to the release you want
./scripts/fetch-native.sh
```

The script:

1. Downloads `android-libs.tar.gz`, `ZuniaCore.xcframework.tar.gz`, and `SHA256SUMS`
2. Verifies SHA-256 for those archives
3. Installs into `android/app/src/main/jniLibs/` and `ios/Frameworks/`

Those directories are gitignored. CI can set repository variable `ZUNIA_CORE_TAG` to run the same step; if unset, analyze/test still run without native libs.

## Secure connect

Deep links, App / Universal Links, and WalletConnect v2 settings are registered; session code uses a stub/`reown_walletkit` interface until a project id is set.

| Item | Location |
|------|----------|
| Canonical YAML | `config/connect.yaml` |
| Dart constants | `lib/config/connect_config.dart` |
| Deep link handler | `lib/services/deep_link_handler.dart` |
| WC service | `lib/services/wallet_connect_service.dart` |
| Env template | `.env.example` |
| Android intents + HTTPS-only | `android/.../AndroidManifest.xml`, `network_security_config.xml` |
| iOS URL schemes + ATS + camera | `ios/Runner/Info.plist` |
| Associated domains | `ios/Runner/Runner.entitlements` |

```bash
cp .env.example .env
# set WALLETCONNECT_PROJECT_ID from https://cloud.walletconnect.com
flutter run --dart-define=WALLETCONNECT_PROJECT_ID=$WALLETCONNECT_PROJECT_ID
```

## Mnemonic / screen security

Policy: `config/mnemonic_security.yaml`. Enforcement lives under `lib/security/` and `lib/crypto/keystore.dart` (secure storage wrapping key, biometrics gate, FLAG_SECURE channel, hold-to-reveal, clipboard auto-clear, 4-word verify, root warning stub).

## Status

In development (alpha). Not on App Store / Play Store yet.

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

- [Flutter](https://docs.flutter.dev/get-started/install) 3.24+ (stable)
- Xcode (iOS) / Android Studio SDK (Android)
- Optional: `gh` CLI to fetch native release artifacts

```bash
flutter doctor
```

## Quick start

```bash
# Optional when a zunia-core release exists:
# ZUNIA_CORE_TAG=v0.1.0 ./scripts/fetch-native.sh

flutter pub get
flutter run                 # connected device / simulator
flutter run -d ios
flutter run -d android
```

## Build release outputs

```bash
ZUNIA_CORE_TAG=v0.1.0 ./scripts/fetch-native.sh

# Android App Bundle (Play Store)
flutter build appbundle --release

# Android APK
flutter build apk --release

# iOS (requires signing in Xcode; link ios/Frameworks/ZuniaCore.xcframework)
flutter build ipa --release
```

Artifacts:

- `build/app/outputs/bundle/release/app-release.aab`
- `build/app/outputs/flutter-apk/app-release.apk`
- `build/ios/ipa/*.ipa`

## Project layout

```
lib/
  main.dart
  crypto/keystore.dart
  security/                 # FLAG_SECURE, clipboard, integrity, screen blur
  services/                 # deep links, WC, push stub
  screens/                  # onboarding, unlock, portfolio, send/receive, QR, settings
  theme/zunia_theme.dart
  widgets/
scripts/fetch-native.sh
config/connect.yaml
config/mnemonic_security.yaml
android/                    # Android host + jniLibs (fetched)
ios/                        # iOS host + Frameworks (fetched)
assets/brand/
```

## Development

| Command | Description |
|---------|-------------|
| `flutter run` | Debug on device/simulator |
| `flutter test` | Widget tests |
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
