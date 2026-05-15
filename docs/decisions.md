# Decision log

Append-only. Newest entries at the bottom. Each entry: date, title, context, decision, rationale, alternatives considered.

---

## 2026-05-15 — Phasing rationale

**Context:** Fresh repo with README, LICENSE, CLAUDE.md, and the agent team in place. No Xcode project, no roadmap, no code. Constraints fixed by CLAUDE.md: iOS 17+ SwiftUI, no backend, no analytics, read-only v1, MIT, solo developer with agent assistance, Apple Developer account already owned.

**Decision:** Ship v1.0 in five sequential phases: (0) Foundations — Xcode project, CI, repo polish; (1) Address entry + account snapshot via REST `clearinghouseState`; (2) Open orders and recent fills via REST; (3) Live updates via WebSocket; (4) QA hardening and App Store submission prep.

**Rationale:** Phase 0 buys a green CI and a buildable project before any feature work, so every later phase has a working safety net and we never debug "is it my code or the project setup." Phases 1 and 2 are both REST-only and share a networking layer, so building them before WebSocket lets the live-updates phase reuse a battle-tested decoder and error model rather than inventing both data plane and transport at once. Phase 3 is intentionally last among feature phases because WebSocket lifecycle, reconnect logic, and concurrency are the highest-risk parts of the codebase and benefit from coming after the data shapes are settled. Phase 4 is a dedicated hardening and submission phase rather than a "we'll polish as we go" assumption, because Apple review, accessibility, and the privacy nutrition label all require focused, end-of-cycle attention and they have historically blown up timelines when treated as cross-cutting. Effort sizing (S, M, M, L, M) reflects that Phase 3 is the single largest risk and everything else is bounded by a clear API surface. The phasing also gives natural demo-able milestones for an open-source audience: each phase ends with something a contributor can run and see.

**Alternatives considered:**
- *Build WebSocket first, treat REST as fallback.* Rejected: doubles risk on day one, and a WS-first architecture is hard to retrofit with proper REST reconciliation later.
- *Combine Phases 1 and 2 into one "all read endpoints" phase.* Rejected: too large to land safely solo, and splitting them gives a meaningful intermediate release where positions+PnL alone are already useful.
- *Skip a dedicated hardening phase and submit when feature-complete.* Rejected: privacy nutrition label, accessibility audit, app icon, screenshots, and review-language sweeps consistently slip when bundled into a feature phase.
- *Include WalletConnect/trading inside v1 to launch with a stronger story.* Rejected by CLAUDE.md constraint (read-only v1); also dramatically expands Apple review risk and key-handling responsibility. Trading is captured as post-v1 only.

---

## 2026-05-15 — Xcode project with internal Swift Packages (not pure SwiftPM workspace, not multi-target Xcode)

**Context:** Phase 0 needs a concrete project shape before `ios-developer` creates files. Three credible options: (a) a pure SwiftPM workspace with a tiny host app target, (b) a single `OpenHL.xcodeproj` with multiple Xcode framework targets, (c) a single `OpenHL.xcodeproj` for the app target plus local Swift Packages added as project dependencies for shared modules.

**Decision:** Option (c). One `OpenHL.xcodeproj` owns the iOS app target, signing, entitlements, Info.plist, and asset catalogs. `OpenHLCore` and `HyperliquidAPI` are local Swift Packages under `Packages/`, referenced as project package dependencies.

**Rationale:** Local SwiftPM modules give us linker-enforced boundaries — `HyperliquidAPI` cannot import SwiftUI because it doesn't link it, regardless of intent. That is the property we want for an architecture-first codebase. App-Store-bound iOS apps still need an Xcode app target for signing and capabilities, so the imagined savings of a pure-SwiftPM workspace are not real. Multi-target Xcode framework projects achieve similar boundaries but with heavier build settings, separate Info.plists per framework, and worse `swift test` ergonomics. Local packages are testable headlessly via `swift test` from each package directory, which is faster than spinning up the iOS simulator for unit tests.

**Alternatives considered:**
- *Pure SwiftPM workspace.* Rejected: still need an Xcode app target for App Store signing; loses single-source-of-truth for Info.plist and entitlements.
- *Multi-target Xcode project with framework targets.* Rejected: heavier configuration burden per module, slower test feedback (no `swift test`), Info.plist sprawl.
- *Monolithic single-target app, no modules.* Rejected: zero enforcement of dependency direction; the whole point of the layered architecture evaporates the first time someone imports `SwiftUI` from networking code.

---

## 2026-05-15 — Swift 6 strict concurrency on from day one

**Context:** Swift 6 language mode with complete strict-concurrency checking introduces real friction (Sendable conformances, isolation annotations, no implicit main-thread assumptions). Many teams keep it off for v1 and migrate later.

**Decision:** Swift 6 language mode enabled in the app target and both packages from Phase 0, with strict concurrency checking at the complete level.

**Rationale:** We have zero existing code. Migrations from Swift 5 + minimal checking to Swift 6 + complete checking are documented as painful precisely because they happen mid-flight, when the codebase already encodes assumptions that strict mode rejects. Starting strict means the only code we ever write is code that passes strict — there is no migration. The product also has a WebSocket-driven live store coming in Phase 3, which is exactly the kind of cross-actor mutable state where strict checking pays for itself in bugs not shipped. Friction is bounded by the small surface area (one app target, two small packages).

**Alternatives considered:**
- *Swift 5 language mode for v1, migrate post-launch.* Rejected: migration cost is paid later with interest; we'd ship Phase 3 (the riskiest concurrency code) without the checker.
- *Swift 6 mode, minimal checking only.* Rejected: minimal/targeted modes still let through the race classes we most want caught. If we're paying for Swift 6, we want the full benefit.

---

## 2026-05-15 — `swift format` over SwiftLint for Phase 0

**Context:** The roadmap requires "SwiftLint or built-in Swift formatter wired into the build (one of the two, not both)." Both have established ecosystems; both can fail builds in CI.

**Decision:** Use Apple's built-in `swift format` (the SwiftPM-bundled formatter, invoked via `swift format lint --strict` in CI). SwiftLint not used.

**Rationale:** `swift format` ships with the toolchain — no Homebrew install, no version pinning of a third-party binary, no separate ruleset file to bikeshed. It is the closest thing to "standard Swift style," and being in-tree means contributors get identical behavior with no setup. SwiftLint's rule library is broader, but for a small read-only app written from scratch we do not need the extra rules; the marginal lint value is dwarfed by the operational cost of an extra dependency. The constraint in CLAUDE.md against unnecessary third-party tools also favors the Apple-shipped option.

**Alternatives considered:**
- *SwiftLint.* Rejected for Phase 0: third-party binary to install and version-pin; broader rule set than we need; would itself require a `decisions.md` entry per our dependency policy.
- *Both.* Explicitly forbidden by the roadmap.
- *Neither (rely on review).* Rejected: formatting drift in a multi-contributor open-source repo is real and cheap to prevent in CI.

---

## 2026-05-15 — Swift Testing for unit tests, XCTest only where required

**Context:** Apple ships Swift Testing (the `@Test` macro framework) as the modern unit-test framework. XCTest remains the only option for XCUITest-based UI tests.

**Decision:** All unit tests (in `OpenHLCore`, `HyperliquidAPI`, and the app-target unit test bundle) use Swift Testing. The `OpenHLUITests` target stays on XCTest because XCUITest requires it.

**Rationale:** Swift Testing's macro-based API maps cleanly onto the test shapes this product needs — parameterized tests for address validation, fixture-driven decoder tests, formatter cases — and produces clearer failure output than `XCTAssert*`. Starting greenfield, there is no migration cost. We isolate Swift Testing and XCTest into separate targets to avoid mixing two runtime test discovery models inside one bundle.

**Alternatives considered:**
- *XCTest everywhere.* Rejected: pays nothing for the ceremony of XCTest in greenfield code; loses the parameterized-test ergonomics we will want for decoder fixtures.
- *Swift Testing everywhere including UI tests.* Not possible — XCUITest is still XCTest-only.

---

## 2026-05-15 — UserDefaults (not Keychain) for the saved wallet address in v1

**Context:** The app needs to remember the user's Hyperliquid wallet address between launches. The address is a public on-chain identifier — not a secret. Three credible stores: `UserDefaults`, Keychain, SwiftData.

**Decision:** Store the address in `UserDefaults` via a thin `AddressStore` protocol injected from the composition root. Single string, single key. No Keychain, no SwiftData in v1.

**Rationale:** The address is public information. Keychain exists to protect secrets; using it for non-secrets adds friction (testing, observability, code complexity) without a corresponding security benefit. SwiftData is a database for collections and relationships; using it to store one string is malpractice and forces a migration story we do not need. `UserDefaults` is the right-sized primitive: one string, one key, trivially testable, survives launches. The trade-off — `UserDefaults` is iCloud-backed up by default and readable on an unlocked development device — is acceptable for a non-secret identifier, and the `AddressStore` protocol means migrating to Keychain later (if users ever ask) is a one-file change with no view-code impact.

**Alternatives considered:**
- *Keychain.* Rejected: optimizes for the wrong property (secrecy of a non-secret). Adds testing friction. The privacy concern some users may have about the address appearing in iCloud backup is a UX issue, not a threat-model issue, and we'd address it with the same protocol indirection if it arose.
- *SwiftData.* Rejected: dramatically over-scaled for one string; introduces schema/migration complexity for zero benefit. We will revisit SwiftData if and when multi-address watchlist (post-v1) lands.

---

## 2026-05-15 — MIT SPDX one-line header on every Swift source file

**Context:** Open-source convention is to mark license at the file level so excerpted code travels with its license. Options range from no per-file header (rely on `LICENSE`) to multi-line copyright + license blocks.

**Decision:** Every `.swift` source file in the repository begins with exactly one line: `// SPDX-License-Identifier: MIT`. No copyright line, no multi-line block. A CI check greps for the SPDX line and fails files missing it.

**Rationale:** SPDX is machine-readable, recognized by GitHub, license scanners, and SBOM tooling. A single line is short enough that contributors will actually maintain it — multi-line blocks rot. The repo-root `LICENSE` carries the canonical copyright statement; duplicating it in every file adds noise without adding legal force.

**Alternatives considered:**
- *No per-file header.* Rejected: excerpted snippets lose their license; tooling cannot detect.
- *Multi-line copyright + license block per file.* Rejected: contributor friction; rots silently when authors change; offers no benefit over SPDX for an MIT project with a single canonical LICENSE file.

