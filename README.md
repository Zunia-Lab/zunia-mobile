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

Chain metadata comes from [zunia-chain-registry](https://github.com/Zunia-Lab/zunia-chain-registry). Visual tokens follow [zunia-brand](https://github.com/Zunia-Lab/zunia-brand) / [zunia-ui](https://github.com/Zunia-Lab/zunia-ui).

## Secure connect (config only)

Deep links, App / Universal Links, and WalletConnect v2 **settings** are ready; session code is not wired yet.

| Item | Location |
|------|----------|
| Canonical YAML | `config/connect.yaml` |
| Dart constants | `lib/config/connect_config.dart` |
| Env template | `.env.example` |
| Android intents + HTTPS-only | `android/.../AndroidManifest.xml`, `network_security_config.xml` |
| iOS URL schemes + ATS | `ios/Runner/Info.plist` |
| Associated domains | `ios/Runner/Runner.entitlements` |

```bash
cp .env.example .env
# set WALLETCONNECT_PROJECT_ID from https://cloud.walletconnect.com
flutter run --dart-define=WALLETCONNECT_PROJECT_ID=$WALLETCONNECT_PROJECT_ID
```

## Status

In development (alpha). Not on App Store / Play Store yet.

## Related repositories

| Repository | Description |
|------------|-------------|
| [zunia-extension](https://github.com/Zunia-Lab/zunia-extension) | Browser extension (same keys) |
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

```bash
flutter doctor
```

## Quick start

```bash
flutter pub get
flutter run                 # connected device / simulator
flutter run -d ios
flutter run -d android
```

## Build release outputs

```bash
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
  main.dart
  theme/zunia_theme.dart      # Brand colors + typography
  screens/home_screen.dart
  widgets/zunia_widgets.dart  # Amount, Address, Surface
android/                      # Android host
ios/                          # iOS host
assets/brand/                 # App mark from zunia-brand
```

## Development

| Command | Description |
|---------|-------------|
| `flutter run` | Debug on device/simulator |
| `flutter test` | Widget tests |
| `flutter analyze` | Static analysis |
| `flutter build apk` | Android release APK |
| `flutter build ipa` | iOS release IPA |

## Contributing

See [CONTRIBUTING.md](https://github.com/Zunia-Lab/.github/blob/main/CONTRIBUTING.md).

## Security

See [SECURITY.md](./SECURITY.md). Never include seed phrases in issues or PRs.

## License

Apache-2.0. See [LICENSE](LICENSE).
