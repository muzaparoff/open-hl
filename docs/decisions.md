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

