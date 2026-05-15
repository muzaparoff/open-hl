# open-hl

**Open-source, privacy-first iOS viewer for Hyperliquid trading accounts.**

Paste a wallet address, see your positions, PnL, open orders, and recent fills. No backend, no analytics, no tracking. The app talks directly to `api.hyperliquid.xyz` from your device.

## Status

🚧 Early development. See [`docs/roadmap.md`](docs/roadmap.md) for the phased plan.

## Why

Hyperliquid has no official iOS app. Third-party iOS apps exist but none are open-source and none commit to zero-tracking. open-hl fills that gap.

## Principles

- **Read-only in v1.** No trading, no signing, no private keys. The app needs only your public wallet address.
- **No backend.** All API calls go directly from your device to Hyperliquid.
- **No analytics, no crash reporters that phone home, no third-party SDKs.**
- **Open source, MIT licensed.**
- **iOS 17+, SwiftUI-native.**

## Building

Will be documented once the Xcode project is scaffolded in Phase 0.

## Contributing

Project is in early phase planning. Roadmap is the source of truth for what's open for contribution.

## License

MIT — see [LICENSE](LICENSE).
