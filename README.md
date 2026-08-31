# zunia-mobile

> iOS and Android wallet for Zunia (React Native + Expo). Same keys as the browser extension.

[![License](https://img.shields.io/github/license/Zunia-Lab/zunia-mobile)](LICENSE)
[![Website](https://img.shields.io/badge/website-zuniawallet.com-2050C4)](https://zuniawallet.com)

## Overview

Non-custodial mobile wallet for the Cosmos ecosystem. Connects to dApps via WalletConnect. Chain lists come from [zunia-chain-registry](https://github.com/Zunia-Lab/zunia-chain-registry).

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
| [zunia-ui](https://github.com/Zunia-Lab/zunia-ui) | Shared UI components |

## Quick start

```bash
npm install
npx expo start
```

Scan with Expo Go, or press `i` / `a` for simulator.

## Development

| Command | Description |
|---------|-------------|
| `npm start` | Expo dev server |
| `npm run ios` | iOS simulator |
| `npm run android` | Android emulator |

Requires Node.js 20+. WalletConnect and hardware wallet support land in later milestones.

## Deployment

EAS Build / Submit for App Store and Play Store. Deep link scheme: `zunia://`. Bundle IDs: `com.zuniawallet.mobile`.

## Contributing

See [CONTRIBUTING.md](https://github.com/Zunia-Lab/.github/blob/main/CONTRIBUTING.md).

## Security

See [SECURITY.md](https://github.com/Zunia-Lab/.github/blob/main/SECURITY.md). Never include seed phrases in issues or PRs.

## License

Apache-2.0. See [LICENSE](LICENSE).
