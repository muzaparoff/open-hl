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

## 2026-05-15 — `Money` is a typealias for `Decimal`, not a newtype, in Phase 1

**Context:** Phase 1 introduces money handling end-to-end. Options: (a) typealias `Money = Decimal`; (b) a single `Money` struct wrapping `Decimal`; (c) a family of newtypes (`USDValue`, `AssetSize`, `Price`, `PnL`, `Fee`).

**Decision:** Typealias. `Money = Decimal` in `OpenHLCore/Money.swift`. No wrapping struct in v1.

**Rationale:** Hyperliquid mixes several quantity kinds in one response (USD account value, asset position size, mark price, PnL, fees). A single `Money` newtype would lump them all together — no type-level safety, and a wrap/unwrap tax at every call site for no payoff. A family of newtypes is the genuinely useful design, but it is a non-trivial exercise (unit-of-measure tracking, conversion functions, comparable/arithmetic constraints across kinds) and Phase 1 does not do arithmetic across kinds. Phase 1 only reads, formats, and displays. `Decimal` already gives us no-floating-point-rounding, `Codable`, `Sendable`, `Hashable`, `Comparable`, and direct `Decimal.FormatStyle`. The typealias documents intent at use sites (`accountValue: Money`) without imposing a wrap tax. The hard rule against `Double`/`Float` on money paths is enforced by code review, not by the type system — which is the same enforcement we would need anyway with a newtype that exposes `.rawValue: Decimal`.

**Alternatives considered:**
- *Single `Money` newtype.* Rejected: type-soup; obscures the actual kinds; introduces a wrap/unwrap tax for no compile-time safety.
- *Family of newtypes (`USDValue`, `AssetSize`, etc.).* Deferred, not rejected. Revisit if Phase 2/3 introduces meaningful cross-kind arithmetic (e.g. computing PnL as `(markPx - entryPx) * size`). At that point the design is worth doing properly.
- *`Double`.* Rejected by CLAUDE.md and roadmap: no `Double` for money, end-to-end.

---

## 2026-05-15 — `AddressStore` lives in `HyperliquidAPI`, not `OpenHLCore`

**Context:** The address-persistence protocol needs a home. `OpenHLCore` and `HyperliquidAPI` are both plausible: the `Address` type lives in `OpenHLCore` and the protocol traffics in `Address`; the only consumer is a view model that already imports `HyperliquidAPI` for the client.

**Decision:** `AddressStore` lives in `HyperliquidAPI`. Same package as `HyperliquidClient`.

**Rationale:** `OpenHLCore` is a pure-value-types leaf module — no I/O, no `Foundation` beyond `Date`/`Decimal`/`URL`/`UserDefaults` value types. A protocol whose concrete implementations do `UserDefaults` (today) and Keychain (potential future) is not pure; even though the protocol itself has no I/O dependency, co-locating it with its implementations is the convention we want. The Phase 1 consumer (the address-entry view model) already imports `HyperliquidAPI` for `HyperliquidClient`, so co-locating adds no new import edges. If a future consumer in a layer below `HyperliquidAPI` ever needed `AddressStore`, we would extract the protocol to `OpenHLCore` then — premature now.

**Alternatives considered:**
- *Put `AddressStore` in `OpenHLCore`.* Rejected: drags persistence concerns into the pure-value-types module; sets a precedent that "any protocol can go in Core" which erodes the leaf-module invariant.
- *Create a third package `OpenHLPersistence`.* Rejected: one protocol and two implementations do not justify a package. Will reconsider if Phase 3+ adds SwiftData-backed snapshot caching.

---

## 2026-05-15 — No retry/backoff inside the REST client in Phase 1

**Context:** `URLSessionHyperliquidClient` could implement an automatic retry policy on transient failures (offline, timeout, 5xx). Many production clients do.

**Decision:** No retry inside the client. One attempt per call. Pull-to-refresh is the user's retry control. `waitsForConnectivity = true` remains on (one-shot wait inside the resource ceiling — not a retry).

**Rationale:** Retries inside the client hide what is happening from the view model and the user. A user staring at a 45-second spinner on a flaky network is worse UX than a fast error with a "Try again" affordance. Retries also tangle with cancellation: when a user pulls to refresh again, should the in-flight retry chain be cancelled, restarted, or merged? Each answer has edge cases. By keeping retry out of the client we keep the cancellation contract crisp ("a cancelled task means a cancelled HTTP request, full stop"). Phase 3's WebSocket has a genuine reconnect/backoff need (long-lived connection, server-driven push); that gets its own state machine and is not precedent for the REST path.

**Alternatives considered:**
- *Exponential backoff with jitter, 3 attempts, on 5xx and timeout.* Rejected: doubles or triples time-to-error on real outages; tangles cancellation; the user can already retry by pulling to refresh.
- *Single retry on timeout only.* Rejected: a special case is harder to reason about than no retry, and the cancellation tangle is the same.

---

## 2026-05-15 — `HyperliquidError` is closed and view-model-translated

**Context:** Errors from a REST client can be exposed at many levels of abstraction: raw `URLError`/`DecodingError`, a wrapping enum that preserves underlying errors, or fully abstracted user-facing strings.

**Decision:** `HyperliquidError` is a closed enum with six cases: `.offline`, `.timeout`, `.httpStatus(Int)`, `.decoding(underlying:)`, `.unexpectedResponse(reason:)`, `.transport(underlying:)`. View models translate these to a separate `ViewErrorState` enum (`offline`, `timeout`, `badRequest`, `serverError`, `unexpectedResponse`, `unknown`). Views switch on `ViewErrorState`.

**Rationale:** Two distinct enums separate two distinct concerns. `HyperliquidError` is API-shape vocabulary — what went wrong at the transport/decode level. `ViewErrorState` is UI vocabulary — what we render and what action the user can take. Conflating them either pollutes the client with UI knowledge or pollutes the view with transport knowledge. Closed enums on both sides mean exhaustive `switch` at every translation point — adding a new case is a compile-time decision, not a silent fall-through. The `underlying:` payloads on `decoding` and `transport` preserve diagnostic info for `OSLog` without ever being shown to the user.

**Alternatives considered:**
- *Surface `URLError`/`DecodingError` directly.* Rejected: view models would have to know transport vocabulary; every new view duplicates the translation.
- *Single `AppError` shared across layers.* Rejected: forces every layer to import every other layer's error vocabulary and erases the boundary between "what the API said" and "what we should tell the user."
- *Open `Error` protocol with conformances.* Rejected: no exhaustive switch; new cases ship as silent fall-throughs to a default UI state.

---

## 2026-05-15 — `@DecimalString` property wrapper as the single money-decode path

**Context:** Hyperliquid returns numbers as JSON strings (`"1234.5"`, `"-0.000123"`). The default `Decimal: Codable` conformance expects a JSON number token, not a string. Options: (a) per-DTO custom `init(from:)` that reads strings; (b) a `KeyedDecodingContainer` extension; (c) a property wrapper.

**Decision:** Property wrapper `@DecimalString` (and `@OptionalDecimalString` for nullable fields) defined in `OpenHLCore`. Every money field on every DTO uses it.

**Rationale:** A property wrapper is the smallest declaration that puts decoding semantics on the field itself, where a reviewer reads the field. A `KeyedDecodingContainer` extension still requires every DTO author to call the right helper at the right key — easy to forget, hard to grep for. Per-DTO `init(from:)` works but loses the DTO-as-plain-data property and adds boilerplate that scales linearly with DTO count. The wrapper also gives us a single place to enforce the rules (string-only token, no grouping separators, no leading `+`, locale-agnostic) and a single place to fix any bug we find. The cost — a `wrappedValue` indirection per field — is negligible.

**Alternatives considered:**
- *Per-DTO custom `init(from:)`.* Rejected: boilerplate; rule drift across DTOs.
- *`KeyedDecodingContainer` extension.* Rejected: easy to call the wrong helper; not visible on the field.
- *Custom `JSONDecoder` strategy via a global `dateDecodingStrategy`-style hook.* Rejected: no such hook exists for `Decimal`; a custom strategy would need a separate decoder per DTO and re-introduce the per-call discipline problem.

---

## 2026-05-15 — MIT SPDX one-line header on every Swift source file

**Context:** Open-source convention is to mark license at the file level so excerpted code travels with its license. Options range from no per-file header (rely on `LICENSE`) to multi-line copyright + license blocks.

**Decision:** Every `.swift` source file in the repository begins with exactly one line: `// SPDX-License-Identifier: MIT`. No copyright line, no multi-line block. A CI check greps for the SPDX line and fails files missing it.

**Rationale:** SPDX is machine-readable, recognized by GitHub, license scanners, and SBOM tooling. A single line is short enough that contributors will actually maintain it — multi-line blocks rot. The repo-root `LICENSE` carries the canonical copyright statement; duplicating it in every file adds noise without adding legal force.

**Alternatives considered:**
- *No per-file header.* Rejected: excerpted snippets lose their license; tooling cannot detect.
- *Multi-line copyright + license block per file.* Rejected: contributor friction; rots silently when authors change; offers no benefit over SPDX for an MIT project with a single canonical LICENSE file.

---

## 2026-05-15 — Cap `userFills` at 200 in the client; no fetch-more

**Context:** Hyperliquid's `userFills` endpoint does not paginate. A single response can carry thousands of fills for an active account. Three options were credible: (a) cap at the transport layer at a fixed N; (b) pass everything through and let the view show a "Showing recent N" footer above a threshold; (c) infinite-scroll fetch-more.

**Decision:** Option (a). `URLSessionHyperliquidClient.userFills(for:)` slices the response to the first **200** entries (which Hyperliquid returns in reverse-chronological order). The cap is exposed as `public static let userFillsCap: Int = 200` so tests can assert on it and a later phase can change it via a follow-up decision. Views render a footer "Showing 200 most recent fills" only when the returned array's count equals the cap.

**Rationale:** A bounded transport contract is the simplest contract. View models stay trivial — they consume an array and render. Memory and SwiftUI render costs are bounded by construction; we never have to debug "why is the fills tab janky for power users." Option (c) is impossible because the API has no cursor. Option (b) splits the bound across two layers — the client returns unbounded data but the view promises a bound — which is exactly the kind of split responsibility that produces bugs at layer boundaries. 200 is empirical: covers the realistic active-trader case, well below the threshold where `List` lazy-loading complications start to matter, large enough that the "showing most recent" footer rarely fires unfairly. We will revisit the number, not the strategy, if usage data justifies it.

**Alternatives considered:**
- *No cap.* Rejected: unbounded JSON onto a phone is asking for a future crash report.
- *Infinite scroll.* Rejected: the API does not support it. We are not building a fake affordance.
- *Cap at the view layer.* Rejected: layer-split responsibility; either side can break the contract alone.
- *Higher / lower cap (50, 100, 500).* Considered. 50 is too aggressive for an active trader; 500 starts to feel like "why didn't you just stream it." 200 is the comfortable middle.

---

## 2026-05-15 — Canonical `Side` enum (`.buy`/`.sell`) in domain; translate `"B"`/`"A"` at the mapper

**Context:** Hyperliquid encodes order and fill side on the wire as `"B"` (buy) or `"A"` (ask = sell). The domain layer needs a representation that view models and tests can pattern-match cleanly. Options: (a) preserve the wire form (`String` "B"/"A") in domain types; (b) preserve as a typed wire enum `WireSide` re-exported; (c) translate to a Swift-idiomatic `.buy`/`.sell` enum at the DTO -> domain mapper.

**Decision:** Option (c). Both `OpenOrder.Side` and `Fill.Side` are closed enums with cases `.buy` and `.sell`. DTOs hold `side: String`; the client's mapper translates and throws `HyperliquidError.unexpectedResponse(reason:)` for unknown values. Domain types and the rest of the app never see `"B"`/`"A"`.

**Rationale:** Wire encoding is a transport concern. View models should pattern-match on intent (`case .buy: …`), not on protocol minutiae (`case "B": …`). A closed `.buy`/`.sell` enum gives exhaustive switching, no stringly-typed bugs, and a single fail-loud point if Hyperliquid ever introduces a third side encoding. The translation cost is one switch statement in the mapper per endpoint — negligible. Preserving the wire form would force every view-model and test site to either parse the string or know the convention; multiplying that knowledge across screens is exactly the sort of leak the layered architecture exists to prevent. Note this is the same pattern §11.3 already established for `leverage.type` in `clearinghouseState` — consistency, not novelty.

**Alternatives considered:**
- *Preserve wire `String`.* Rejected: stringly-typed at every consumption site; no exhaustive switching; a typo in a view (`"a"` vs `"A"`) silently misrenders.
- *`WireSide { case B, A }`.* Rejected: surfaces the protocol vocabulary into UI code; cosmetic improvement only over the string option.
- *Use the existing `ClearinghouseState.Position.Side` (`.long`/`.short`).* Rejected: a position's side is derived from signed `szi` and means "which direction am I in"; an order's side is `.buy`/`.sell` and means "which direction am I about to move." Conflating them is wrong despite the surface similarity.

---

## 2026-05-15 — `Fill.direction` is a verbatim wire `String`, not a closed enum, in Phase 2

**Context:** Hyperliquid's fill payloads carry a `dir` field with values like `"Open Long"`, `"Close Short"`, `"Liquidated Long"`, `"Open Short"`, `"Close Long"`, `"Liquidated Short"`. This is strictly more informative than the binary `side`. Two design questions: (1) do we surface it at all, given we already surface `side`; (2) if we do, as a closed enum or a verbatim string.

**Decision:** Surface it as `Fill.direction: String`, preserved verbatim from the wire. Do not introduce a closed enum in Phase 2. The fills UI uses `direction` as the primary descriptor for each row (more informative than "Buy/Sell"); `side` remains available for any code that needs the binary distinction.

**Rationale:** The string is what the user wants to see, and what Hyperliquid itself shows in its own UI. We do not want to invent a synonym. A closed enum would be the right shape eventually — exhaustive switching, no typo risk — but enumerating it correctly requires confidence in the full Hyperliquid label set (which is poorly documented and may include cases we have not observed: partial liquidations, ADL, etc.). Phase 2 ships the screen; Phase 3 or later introduces the closed enum with a decision entry when we have confidence in the full set. Until then, preserving the string is honest: it says "we are passing through what the server said." Risk: a typo on Hyperliquid's side becomes a typo on our UI. Acceptable; their string is canonical.

**Alternatives considered:**
- *Closed `FillDirection` enum, throw on unknown.* Rejected for Phase 2: brittle in the face of poorly-documented wire vocabulary; would force `.unexpectedResponse` errors on first contact with any new HL fill label, even for benign new cases like "ADL Long."
- *Closed enum with `.other(String)` fallback.* Considered. Defers the problem rather than solving it; the `.other` case becomes the de-facto string carrier anyway. If we add an enum, it should be exhaustive.
- *Drop the field, render only `side`.* Rejected: loses the "Open" vs "Close" vs "Liquidated" distinction, which is precisely what a fills screen exists to communicate.

---

## 2026-05-15 — Three independent view models, no shared account store, in Phase 2

**Context:** Positions, Orders, and Fills are three tabs sharing one address. A shared `AccountStore` (one source of truth across all three tabs, fanning state out via `@Observable`) is a credible architecture and would set up Phase 3's live store well.

**Decision:** Each tab owns its own `@MainActor @Observable` view model in Phase 2. The composition root constructs `PositionsViewModel`, `OrdersViewModel`, and `FillsViewModel` with the same `(client, address, clock)` triple. No shared store. Each tab refetches on appear via `.task { await vm.load() }` and on pull via `.refreshable { await vm.refresh() }`.

**Rationale:** Phase 2 has no cross-tab state to share. Each REST endpoint is independent; there is no reconciliation across them, no derived state that spans tabs. Introducing a store now would buy zero behavior and add a layer of indirection that does not pay rent. Phase 3 introduces WebSocket-driven updates, where one server event affects multiple screens (a fill closes a position, updates PnL, and appends to fills) — that is the right context to introduce a store, because it has real work to do. Building the store earlier is speculative architecture; we'd be designing for a load profile that does not yet exist. The duplication across three constructors (each takes `client`, `address`, `clock`) is mild and visible — the only cost. View models for the three tabs all share the same `State` enum shape (idle / loading / loaded / error-with-last-loaded), so the pattern is uniform without being unified.

**Alternatives considered:**
- *Single `AccountStore` injected via `@Environment`, view models read from it.* Rejected for Phase 2: ambient injection for no current benefit; would set a precedent that's hard to walk back. Reconsidered in Phase 3.
- *Constructor-injected shared `AccountStore` for all three view models.* Rejected for Phase 2: same lack of justification; introduces a coordinator without a coordination problem.
- *One mega-view-model owning all three lists.* Rejected: violates the per-feature-folder convention from §13.1; a single state machine for three independent endpoints is a worse error model (one endpoint's failure poisons all three views).

---

## 2026-05-15 — No new `HyperliquidError` cases for Phase 2

**Context:** New endpoints could plausibly motivate new error cases (e.g. `.rateLimited`, `.malformedAddress`, `.userNotFound`).

**Decision:** Phase 2 ships with the existing six cases of `HyperliquidError` (`.offline`, `.timeout`, `.httpStatus(Int)`, `.decoding`, `.unexpectedResponse`, `.transport`). No new cases.

**Rationale:** The cases are descriptive of failure *kinds*, not endpoints. Every failure mode the new endpoints exhibit maps to an existing case: a malformed address returns HTTP 422 with an empty body (`.httpStatus(422)` -> view model's `.badRequest`); rate limiting returns 429 (`.httpStatus(429)` -> `.badRequest`); a brand-new wire enum value triggers `.unexpectedResponse`. Adding `.rateLimited` would require either re-mapping 429 specifically (which we'd then need to surface specially in views) or never firing — both bad. If a future product decision wants a distinct "you're being rate-limited, slow down" UI affordance, that gets a decision entry and a closed enum addition; until then, the six-case enum is the right granularity.

**Alternatives considered:**
- *Add `.rateLimited(retryAfter: Date?)`.* Rejected for Phase 2: no UI design exists for it, and Hyperliquid does not consistently emit `Retry-After`. The view-model's `.badRequest` rendering is the honest answer today.
- *Add `.userNotFound`.* Rejected: Hyperliquid does not signal this distinctly from other 4xx; we would be inferring semantics we cannot reliably distinguish.

---

## 2026-05-16 — `CandleInterval.bestFit(for:)` clamp ladder for Custom-mode date ranges

**Context:** Phase 3c adds a Custom date-range picker to the coin-detail chart. The user picks any `(start, end)` pair; the app picks the granularity. Three options were credible: (a) let the user pick both range and granularity independently; (b) auto-clamp granularity from the span via a fixed lookup table; (c) pick the granularity that targets a constant bar count (e.g. always aim for ~150 bars).

**Decision:** Option (b) — a fixed lookup table on `CandleInterval`:

| Span                    | Granularity   |
|-------------------------|---------------|
| ≤ 2 days                | `.oneHour`    |
| ≤ 30 days               | `.fourHour`   |
| ≤ 180 days              | `.oneDay`     |
| ≤ 2 years (≤ 730 days)  | `.oneWeek`    |
| > 2 years               | `.oneDay` (caller clamps span via `validate(customRange:now:)`) |

Implemented as the pure static function `CandleInterval.bestFit(for: DateInterval) -> CandleInterval`. The max span allowed by `validate(customRange:now:)` is **3 years**.

**Rationale:** Option (a) — two independent controls — doubles the picker surface area for a power-user feature most users will never touch, and admits combinations the API can't satisfy (5-minute bars over a year is `~105,000` bars; Hyperliquid returns ~500). Option (c) — constant-bar-count targeting — sounds elegant but produces visually unstable boundaries: dragging the end date one day forward could flip the granularity, redrawing the entire chart. The fixed table has stable, user-comprehensible boundaries: "under a month gets 4-hour bars" is a sentence the user can hold in their head. The ladder rungs are picked so each rung produces between ~48 and ~180 bars at the upper end of its span — comfortably under the 500-bar API cap, comfortably above the threshold where a candlestick chart degenerates into noise. `.fourHour` survives as a `bestFit` rung even though it left `userFacing`; the 2–30 day band is the only range where 4h is the right tradeoff between detail and cap, and dropping it would force that band onto either `.oneHour` (~720 bars; truncated) or `.oneDay` (~30 bars; coarse). The 3-year span cap exists for the same API-cap reason: at `.oneWeek` granularity, 3 years is ~156 bars (safe); 5 years would push to ~260 bars at `.oneWeek` (still safe) but the `bestFit` table doesn't model that band, and the user-experience value of "five years of one coin's price" is dubious enough that we defer rather than re-rung the table.

**Alternatives considered:**
- *Independent range + granularity controls.* Rejected: admits invalid combinations; doubles picker complexity for a power-user feature.
- *Constant-bar-count targeting.* Rejected: visually unstable boundaries; chart redraws on every small range tweak.
- *Add `.fourHour` back to `userFacing`.* Rejected: 4h's place in the preset ladder is precisely the awkward middle that motivated dropping it; the Custom-mode rung is a different question (granularity within an explicit user-chosen span, not a default preset).
- *Cap span at 1 year, not 3.* Considered. `.oneMonth.defaultLookback` is already 3 years; aligning the user-facing cap with the existing internal lookback keeps the codebase coherent and gives `.oneWeek` a justification.

---

## 2026-05-16 — `Mode` enum (not `(interval, range?)` tuple) for coin-detail parameters

**Context:** The Phase 3c coin-detail view model needs to represent two states: "standard preset selected" and "custom range selected." Three credible shapes: (a) `var interval: CandleInterval` + `var customRange: DateInterval?` with `customRange != nil` meaning "Custom mode"; (b) a single `Mode` enum with `.standardInterval(Preset)` and `.customRange(DateInterval)` cases; (c) two separate view models.

**Decision:** Option (b). `CoinDetailViewModel.Mode` is a closed enum; the picker binds to `mode` through `setMode(_:)`. A nested `Preset` enum holds the five standard-mode entries (1h / 1D / 1W / 1M / 1y) because two of them (`.oneMonth`, `.oneYear`) reuse `.oneDay` as the underlying granularity and need distinct labels and lookbacks. `viewModel.interval` survives as a computed read-only property (`mode.interval`) so existing view code (the x-axis label switch) keeps compiling.

**Rationale:** A two-property representation admits ill-formed combinations — a `customRange` set while `interval` still points at a preset's value, or a preset selected while `customRange` is non-nil. The view code would have to nominate one as authoritative or carry guard logic at every read site. A closed enum makes the modes mutually exclusive at the type level: every consumer pattern-matches in a single switch, and the compiler enforces both branches are handled. Two separate view models would duplicate the entire `State` machine, fetch path, error mapping, and `lastLoaded` plumbing for a screen that already exists; mode switching would also have to thread `market`/`client`/`clock` through a parent. The nested `Preset` rather than a `(CandleInterval, lookback)` tuple is the same argument one level down: tuples admit ill-formed values (`.oneWeek` paired with a 30-second lookback); a closed enum doesn't.

**Alternatives considered:**
- *`(interval, customRange?)` two-property representation.* Rejected: admits ill-formed combinations; every read site needs guard logic.
- *Two separate view models.* Rejected: duplicates state machine and fetch plumbing for zero benefit.
- *Flatten `Preset` into the outer `Mode` cases (`.oneHour, .oneDay, .oneWeek, .oneMonth, .oneYear, .custom(DateInterval)`).* Rejected as marginal: `Mode.Preset` exists separately so that `Preset.allCases` drives the picker and the picker doesn't have to know about `.custom`. Keeping the two concerns separate lets the Custom segment be a sibling button rather than a sixth case the picker iterates over.

---

## 2026-05-16 — Favorite coins stored as `Set<String>`, persisted in `OpenHLCore`

**Context:** Phase 3d adds pinned (favorite) coins to the Markets list. Three orthogonal design questions: (1) what data shape do we persist (rich struct vs. simple symbol set vs. address-scoped list); (2) which package owns the persistence protocol (`OpenHLCore` vs. `HyperliquidAPI` vs. a new package); (3) how does the Markets view model learn about toggles.

**Decision:** Persist a `Set<String>` of coin symbols. The `FavoriteCoinsStore` protocol and its `UserDefaults` / in-memory implementations live in `OpenHLCore`. The Markets view model observes changes via an `AsyncStream<Set<String>>` exposed on the protocol (`var didChange`).

**Rationale:**

- *`Set<String>` over `[Address]` or a richer struct.* Favorites are a UI preference, not a per-wallet preference; the pinned set follows the user across any wallet address they enter. `Set` (not `[String]`) because the dominant operation is `isFavorite(coin)`, called once per row on every Markets render — `O(1)` set contains. Phase 3d ships only binary pinned/unpinned state, so a richer struct (`FavoriteCoin { symbol, pinnedAt, … }`) would carry unused fields and force a migration when those fields go unused. Ordering inside the pinned section is alphabetical, not insertion-order; if a later phase wants "most recently pinned first," it gets its own decision entry and a struct upgrade.
- *`OpenHLCore` over `HyperliquidAPI`.* Favorites have nothing to do with the Hyperliquid API — they never travel over the wire, no DTO references them, and the server has no concept of "favorite." Co-locating with `HyperliquidClient` would import a UI preference into a package that exists to model transport. The argument that put `AddressStore` in `HyperliquidAPI` (it traffics in `Address` and may grow a Keychain variant) does not apply: favorites are plain `String` and there is no plausible future implementation that wants Keychain. `OpenHLCore` already exposes value-store-flavored utilities (`Clock`, `MoneyFormatter`, decoder helpers) and its leaf-module invariant (Foundation-only) holds for this file.
- *`AsyncStream` observation.* Keeps `SnapshotViewModel`'s shape intact. The view model adds one method (`applyFavorites(_:)`) and zero new generic constraints. The subscription is bound to view lifetime via SwiftUI `.task`, so there is no manual unsubscribe. The stream emits the current value on subscription, so the view model gets the right initial value before its first `load()` completes. Multiple subscribers (preview + test + production) work because the store fans out across registered continuations behind a lock.

**Alternatives considered:**

- *`[Address: Set<String>]` keyed by wallet.* Rejected: makes the user re-pin their list when they switch wallets, which contradicts the affordance ("these are the coins I care about"). Also forces a migration when an address is cleared.
- *Rich `FavoriteCoin` struct with `pinnedAt`.* Deferred. The only consumer of `pinnedAt` would be a future "sort by recency" view; we'll upgrade the struct when that view exists.
- *Put `FavoriteCoinsStore` in `HyperliquidAPI`.* Rejected: drags a UI preference into the transport module; sets a precedent that "any protocol that does I/O can go in API."
- *Create a new `OpenHLPersistence` package.* Rejected: one protocol and two implementations don't justify a package. If Phase 3e+ adds SwiftData-backed snapshots and Keychain-backed wallets, we revisit then with multiple residents.
- *Closure-based observation (view model takes `onFavoritesChanged:` closure).* Rejected: requires the composition root to wire two directions; adds startup-ordering questions; tests have to drive the closure manually.
- *`NotificationCenter`.* Rejected: ambient global; defeats constructor injection; testability requires faking notifications.
- *Rebuild the view model on every toggle.* Rejected: discards `state` and `lastLoaded`, flashing the spinner on every star tap.

---

## 2026-05-16 — Portfolio endpoint — window selection, `vlm` decoded-but-hidden, tuple-array decoder reuse

**Context:** Phase 3e adds a wallet balance-history graph powered by `POST /info {"type":"portfolio","user":"0x..."}`. The endpoint returns an outer array of 8 entries; each entry is a heterogeneous 2-tuple `["<windowName>", { accountValueHistory, pnlHistory, vlm }]` with window names `day | week | month | allTime | perpDay | perpWeek | perpMonth | perpAllTime`. Three orthogonal questions had to be resolved before writing the DTO: (1) which windows does the user-facing enum expose; (2) what do we do with the `vlm` (daily volume) array that v1 has no UI for; (3) which decoder pattern do we reach for given the mixed-type tuple-of-tuples wire shape.

**Decision:**

1. **Four windows surfaced, four silently dropped.** `PortfolioWindow` exposes only `.day, .week, .month, .allTime`. The `perp*` quartet is decoded and dropped at `PortfolioDTO.toDomain()`. Unknown future window names are also silently dropped.
2. **`vlm` decoded but not surfaced in v1.** The wire field maps into `PortfolioSeries.volume: [PortfolioPoint]`, fully populated, with no UI affordance. View layer never reads it in v1.
3. **Reuse the `unkeyedContainer()` heterogeneous-tuple-array pattern.** No new decoder genre. The outer array, each `(windowName, series)` entry, and each `[ms, "decimal"]` history point all use hand-rolled `unkeyedContainer()` decoders — same pattern `MetaAndAssetCtxsDTO` uses for the two-element `[meta, assetCtxs]` heterogeneous array.

**Rationale:**

- *Why four windows, not eight.* The four "headline" windows (`day/week/month/allTime`) include perp + spot together — they match what the hyperliquid.xyz portfolio chart shows by default. The `perp*` quartet duplicates the perp-only view that v1 already shows everywhere else (positions are perp-only in v1; spot is a Phase 4+ concern). Surfacing eight windows in a four-segment picker would either force a "Spot/Perp" toggle we haven't designed or require labels like "Day (Perp)" that don't match anything else in the app. Cleaner to ship four now and add the four perp-only cases (and a spot/perp toggle) as a deliberate Phase 4 expansion. The drop happens at the DTO boundary — a single switch in `userFacingWindow(for:)` — so the upgrade path is "add four enum cases and stop dropping," not a transport rewrite.
- *Why decode `vlm` we don't draw.* Cost is negligible: seven `PortfolioPoint`s per window × four windows = 28 small structs per refresh. The alternative — decoding only `accountValueHistory` and `pnlHistory` — saves perhaps 100 bytes of RAM and forces a re-fetch the moment any future feature wants a volume chip. The same logic that put `cumFunding` *out* of `PositionDTO` in Phase 1 (no plausible v1+v2 consumer) puts `vlm` *in* here (an obvious near-future consumer exists, payload is tiny, parsing is trivial). Documented in `PortfolioSeries` doc-comments so future readers understand why a public field exists with no caller.
- *Why reuse the `unkeyedContainer()` pattern rather than build a new decoder shape.* The wire form is structurally the same kind of "heterogeneous fixed-arity tuple" that `MetaAndAssetCtxsDTO` decodes for `[meta, assetCtxs]` — just nested one extra level (an array of such tuples). Hand-rolling three small `init(from:)` decoders (`PortfolioDTO` for the outer array, `Entry` for `(windowName, series)`, `PortfolioHistoryPoint` for `[ms, "decimal"]`) is ~30 lines total, all type-safe at the boundary, with no third-party dependency. The alternative — decode into `[JSONValue]` and post-process — defers errors out of the decoder and into runtime conditionals scattered across the mapper. Worth pinning the pattern as the **default** for any future Hyperliquid endpoint that returns a heterogeneous tuple at any nesting level.
- *Decimal parsing without `@DecimalString`.* The mixed-type `[ms, "decimal"]` 2-tuple can't use `@DecimalString` (property wrappers need a `Decodable` field, not an unkeyed-container position). `Decimal(string:)` called directly inside `PortfolioHistoryPoint.init(from:)` with a `DecodingError.dataCorrupted` on `nil` reproduces the same observable error behavior — the `perform()` pipeline maps `DecodingError` to `HyperliquidError.decoding` identically.

**Alternatives considered:**

- *Expose all eight windows in `PortfolioWindow` and let the view model filter.* Rejected: pushes a transport concern (which windows are duplicated by which) into every consumer; couples the view-model layer to API trivia that should live at the boundary.
- *Expose a single `style: .combined | .perp` toggle plus four windows.* Rejected for v1: there's no spot view yet, so the toggle has no meaningful "other side" — and once spot exists in Phase 4+, a richer model is warranted than just a perp/combined boolean.
- *Skip decoding `vlm` until a feature needs it.* Rejected: adding a field later is an `OpenHLCore` ABI change for `PortfolioSeries`, and the parsing cost is in the noise. The cheaper place to defer a decision is in the UI (decode-and-hide), not in the DTO.
- *Decode the outer array as `[JSONValue]` and post-process in pure Swift.* Rejected: defers decoding errors into runtime conditionals; loses the type-safe boundary that the rest of the package keeps.
- *Wrap each `[ms, "decimal"]` tuple in a tiny `Codable` struct backed by `init(from: unkeyedContainer)`.* This is what we did; the rejected alternative was reaching for a third-party "tuple-codable" macro/library — gratuitous given a five-line `init`.

---


## 2026-05-16 — Phase 3f: iCloud Key-Value backup (not CloudKit), default OFF, dual-write decorator

**Context:** Phase 3f introduces the first Settings screen and an optional cross-device backup for the saved wallet address and the favorite-coins set. Options on the table: (a) `NSUbiquitousKeyValueStore` (KVS), (b) a full CloudKit private database with a single record per user, (c) ship Settings without any backup and revisit. Privacy posture is also live: the wallet address is public on-chain but the user may consider it private.

**Decision:** Use `NSUbiquitousKeyValueStore` behind a decorator pattern. Both `AddressStore` and `FavoriteCoinsStore` are wrapped by `iCloudBacked…Store` types that dual-write to their underlying UserDefaults-backed store *and* to KVS. A separate `ICloudBackupToggle` (UserDefaults-backed, single bool) gates the dual-write; it defaults to OFF. The toggle state itself is **not** synced across devices (the user must opt in on each device). Reconciliation on init and on `NSUbiquitousKeyValueStore.didChangeExternallyNotification` uses last-writer-wins via a parallel `updatedAt` epoch-ms key in both stores.

**Rationale:**
- *Why not CloudKit:* the payload is ~80 bytes total. CloudKit requires a schema, a container, record-zone configuration, conflict resolution, and a per-record subscription if we want push. KVS gives us automatic background sync, conflict-free key-value semantics, and a 1 MB / 1024-key quota that we will not approach in v1. Trading "engineering velocity now" for "schema flexibility later" is the right call when there is no use case demanding schema flexibility.
- *Why decorator (vs. baking it into `UserDefaultsAddressStore`):* the bare stores are already used by UI tests and previews; mixing iCloud I/O into them would force every test to either mock `NSUbiquitousKeyValueStore.default` or set up an entitlement. The decorator pattern keeps the bare stores trivial and lets us inject `InMemoryUbiquitousKeyValueStore` for tests.
- *Why default OFF:* the wallet address is public on-chain but the user has not consented to it leaving the device when they install the app. CLAUDE.md's "no analytics, no tracking" posture extends here by analogy.
- *Why not sync the toggle:* "you turned on iCloud backup on device A; device B now writes to iCloud without you ever opening Settings on B" is a consent surprise. Each device opts in independently.
- *Why epoch-ms `Int64` timestamps (not `Date`, not `Clock`):* the only operations are integer compare and JSON round-trip. A `Date`-based design would drag time-zone considerations into the reconciliation switch for zero benefit.
- *Why the address decorator lives in `HyperliquidAPI` and the favorites decorator in `OpenHLCore`:* the underlying protocols already live in different modules per Phase 1/3d decisions. Co-locating each decorator with its protocol keeps the module dependency graph (§2 of `architecture.md`) downward-only. The "shared" reconciliation logic is copied across the two decorators, not extracted, because the alternative would invert the dependency direction.

**Alternatives considered:**
- *CloudKit private DB.* Rejected on engineering-velocity grounds (above). Logged as the obvious migration path if we ever need richer schema (per-device sessions, server-side history, etc.).
- *Default ON.* Rejected on privacy posture grounds.
- *Sync the toggle state across devices.* Rejected on consent-surprise grounds.
- *Async API surface for the stores.* Rejected: KVS reads and writes are synchronous (the cache is in-process); adding `async` would force every caller into `await` for no behavioral benefit. Existing `AddressStore` / `FavoriteCoinsStore` shapes are preserved.
- *Skip backup entirely in v1.* Rejected: the address-entry friction on a new device is real and KVS is the cheapest possible cure.
- *Encrypt the payload before writing to KVS.* Rejected: KVS is already inside the user's iCloud account (per-Apple-ID, encrypted at rest by Apple). Adding app-layer encryption only matters under a threat model where the user's Apple ID is compromised, in which case the attacker already has every other app's KVS payload too. Not worth the key-management complexity for a public address + a set of coin symbols.

---

## 2026-05-17 — Phase 4: WebSocket live prices over `URLSessionWebSocketTask`

**Context:** Phase 4 brings live data over `wss://api.hyperliquid.xyz/ws`. Architecture §3 always anticipated this — REST is for cold-start, WebSocket is for "stays current." Open choices: (a) `URLSessionWebSocketTask` vs `Network.framework`; (b) whether the live store is an actor or a `@MainActor` class; (c) one shared transport multiplexed across channels vs one connection per channel; (d) the buffer/drop policy when subscribers fall behind; (e) the stale-data threshold.

**Decision:** `URLSessionWebSocketTask` wrapped in a `protocol WebSocketTransport` for testability. Live store is `actor URLSessionHyperliquidStream` in `HyperliquidAPI` (transport-level) plus `final class LiveStore` in the app target (lifecycle + view-model fan-out). **One shared transport** multiplexes every subscription. Buffer policy is "latest-wins" per channel (`allMids`, `activeAssetCtx`, `webData2`) with `AsyncStream.continuation.bufferingPolicy = .unbounded` — Swift's runtime drops if subscribers fall behind. Staleness threshold is **10 s without any message** while the socket is "connected"; `LiveStore.connectionState` projects `.connected | .stale | .reconnecting | .disconnected`. View-model integration is **side-channel `apply*` methods** that mutate `state.loaded` in place — no state-machine rewrites.

**Rationale:**
- *Why `URLSessionWebSocketTask` over `Network.framework`:* same `URLSession` pattern we use for REST (consistent error mapping, lifecycle, proxy/captive-portal handling). `Network.framework` is lower-level than we need. CLAUDE.md says no third-party SDKs — `URLSessionWebSocketTask` keeps us in the Apple-stdlib lane.
- *Why one shared transport:* Hyperliquid's WS multiplexes — the `subscribe` message carries a discriminator and emits messages with a `channel` field. One transport means one reconnect machine, one heartbeat, one TLS handshake.
- *Why `actor` for the stream layer, `final class` for `LiveStore`:* the stream actor serializes mutable subscription state and reconnect attempts — exactly what actors are for. `LiveStore` doesn't have shared mutable state of its own; it composes the stream and bridges to `@MainActor` views. Making `LiveStore` an actor would force `await` into every view's `.task` for no concurrency benefit.
- *Why "latest-wins" not bounded queue:* the data is presentational. A user looking at the BTC mid does not benefit from seeing every tick during a redraw — only the most recent. `AsyncStream.unbounded` + SwiftUI's natural diff cycle is simpler than an explicit ring buffer.
- *Why side-channel `apply*` methods on view models:* the existing state machines are correct for "fetch a snapshot and show it." Live updates are not transitions; they refine already-`.loaded` data. Forcing every WS tick through the state machine would either flicker (`.loaded → .loading → .loaded`) or require new "refreshing-in-place" cases the rest of the app doesn't need.
- *Why 10 s staleness threshold:* observed `allMids` cadence is roughly every 1 s but bursty; a 3 s threshold flapped on normal gaps in capture testing, a 30 s threshold left a dead socket undetected for half a minute. 10 s sits in the middle.
- *Why no live updates on the Balance segment in Wallet:* `webData2` carries `clearinghouseState` and `openOrders` but NOT the `portfolio` time series. Trying to derive a time series from a single point-in-time `webData2` would mean re-querying REST anyway; cleaner to leave Balance on its existing REST pull-to-refresh path.

**Alternatives considered:**
- *Per-channel WebSocket connections.* Rejected: 4× the TLS handshakes and reconnect storms with zero benefit.
- *`actor LiveStore` with `@MainActor` projection.* Rejected as overkill — `LiveStore` doesn't have mutable state worth serializing.
- *Bounded queue per subscriber.* Rejected: dropping the freshest message during a backlog is worse UX than dropping older ones.
- *Apply WS updates through the state machine (a `.refreshing` state).* Rejected: every screen would need a new case the rest of the app doesn't understand, and the chart would flicker.
- *Keep the socket alive in background to deliver alerts.* Rejected: iOS kills the socket within seconds anyway. Phase 3g's `BGAppRefreshTask` is the right primitive for background alerts.
