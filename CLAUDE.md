# open-hl — agent context

This file is loaded into every Claude Code conversation in this repo.

## Product

**open-hl** is an open-source iOS app that displays a user's Hyperliquid trading account read-only. The user enters their public wallet address; the app shows positions, PnL, open orders, and recent fills by calling `api.hyperliquid.xyz` directly from the device.

## Non-negotiable constraints

- **iOS 17+ minimum**, SwiftUI-native, Swift 5.10+/Swift 6 where compatible.
- **No backend.** All API calls go device → `api.hyperliquid.xyz` and `wss://api.hyperliquid.xyz/ws`.
- **No third-party analytics, no crash reporters that phone home, no tracking SDKs.**
- **Read-only in v1.** Trading (which would require WalletConnect + EIP-712 signing) is a later phase.
- **MIT licensed, open source from day one.**
- **No marketing language about returns/gains** — Apple review safety.

## Team (Claude Code agents in `.claude/agents/`)

| Agent | Role |
|---|---|
| `product-manager` | Owns roadmap, phasing, scope. Invoke FIRST for anything new. |
| `uxui-designer` | Wireframes, flows, accessibility, design specs. |
| `swift-expert` | Architecture, concurrency, networking, code review. |
| `ios-developer` | Feature implementation in SwiftUI within the architecture. |
| `qa-automation` | Unit/UI tests, CI, fixtures. |
| `qa-manual` | Exploratory testing, device matrix, pre-release checklists. |

Default routing: PM plans → designer specs → swift-expert sets architecture → ios-developer implements → qa-automation tests → qa-manual verifies.

## Where things live (or will live)

- `docs/roadmap.md` — phased plan, source of truth for what we're building next
- `docs/decisions.md` — append-only decision log (date, decision, rationale)
- `docs/architecture.md` — architecture rules (set by swift-expert)
- `docs/design/<feature>.md` — design specs (set by uxui-designer)
- `docs/qa/<feature>.md` — automation test plans
- `docs/qa/manual/` — manual QA checklists and bug reports

## Hyperliquid API quick reference

- REST: `POST https://api.hyperliquid.xyz/info` with JSON body
  - `{"type":"clearinghouseState","user":"0x..."}` — account snapshot
  - `{"type":"openOrders","user":"0x..."}`
  - `{"type":"userFills","user":"0x..."}`
- WebSocket: `wss://api.hyperliquid.xyz/ws` — subscribe to channels for live updates
- No auth required for read endpoints.
