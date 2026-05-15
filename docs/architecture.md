# open-hl architecture (v0)

Owner: swift-expert. Versioned alongside the codebase. Phase 0 establishes posture; Phases 1–3 fill in detail. Anything contradicting CLAUDE.md loses.

---

## 1. Xcode project layout

**Decision:** A single `OpenHL.xcodeproj` at the repo root with one iOS app target, plus **internal Swift Packages** for shared modules. Not a SwiftPM-driven workspace; not a multi-target Xcode project with framework targets.

**Justification:**
- Xcode project owns the app target — signing, entitlements, Info.plist, app-target build settings, and asset catalogs live where Xcode expects them. App-Store-bound iOS apps in pure SwiftPM workspaces still need a host target; the savings are not real.
- Internal Swift Packages (sibling folders, added to the project as local packages) give us hard module boundaries: a `HyperliquidAPI` target literally cannot `import SwiftUI` because we don't link it. That is the enforcement we want.
- Local packages build inside Xcode without an extra workspace file; they are easy to test in isolation with `swift test` from the package directory; CI builds them via `xcodebuild -scheme OpenHL`.
- Single project file means one source of truth for signing, capabilities, and scheme management.

**On-disk layout:**

```
open-hl/
  OpenHL.xcodeproj/
  OpenHL/                          # app target sources (folder reference)
    OpenHLApp.swift                # @main, composition root
    Screens/                       # SwiftUI screens, one folder per feature
      AddressEntry/
      Positions/
      Orders/
      Fills/
    Resources/
      Assets.xcassets
      Info.plist
  OpenHLTests/                     # app-target unit tests (Swift Testing)
  OpenHLUITests/                   # XCUITest (must remain XCTest)
  Packages/
    OpenHLCore/                    # local SwiftPM package
      Package.swift
      Sources/OpenHLCore/
      Tests/OpenHLCoreTests/
    HyperliquidAPI/                # local SwiftPM package
      Package.swift
      Sources/HyperliquidAPI/
      Tests/HyperliquidAPITests/
  docs/
  .github/workflows/
  README.md
  LICENSE
  CLAUDE.md
```

There is no separate `Features` package in Phase 0. Feature view models live next to their SwiftUI screens inside the `OpenHL` app target, one folder per feature (see Section 5). A `Features` package may be extracted later if app-target compile time or test isolation demand it; that extraction is a no-op from a code-shape perspective because the dependency direction is already correct.

---

## 2. Module split and dependencies

| Module | Kind | Imports allowed | Imports forbidden |
|---|---|---|---|
| `App` (the `OpenHL` Xcode app target) | iOS app target | `SwiftUI`, `SwiftData`, `OpenHLCore`, `HyperliquidAPI` | direct `URLSession` use in view models; `Foundation.UserDefaults` outside the composition root |
| `Features` (folders inside `App`, not a package in v1) | folder-grouped Swift files | same as `App` | same as `App` |
| `OpenHLCore` | local SwiftPM library | `Foundation` only | `SwiftUI`, `UIKit`, `SwiftData`, `URLSession` business logic, `HyperliquidAPI` |
| `HyperliquidAPI` | local SwiftPM library | `Foundation`, `OpenHLCore` | `SwiftUI`, `UIKit`, `SwiftData` |

**Dependency graph (strict, downward only):**

```
App / Features
        │
        ├──────────────────┐
        ▼                  ▼
  HyperliquidAPI  ───▶  OpenHLCore
                        ▲
                        │ (no outgoing edges)
```

- `OpenHLCore` is a leaf. It holds: `Decimal`-based money types, the `Address` value type with 0x-hex validation, error types shared across layers, formatters, time helpers. Pure value types and pure functions. No I/O.
- `HyperliquidAPI` depends on `OpenHLCore` for shared types (e.g. `Address`, `Money`). It owns: REST request/response DTOs, `URLSession` client, WebSocket client (Phase 3), DTO-to-domain mappers, transport-level errors. It is testable headlessly with fixture JSON and a stubbed `URLProtocol`.
- View models in `App` consume `HyperliquidAPI` types via constructor-injected protocols and convert results into UI state. View models import `SwiftUI` only for `@Observable` exposure; they never import `URLSession`.
- SwiftUI views consume view models. Views never import `HyperliquidAPI` directly.

This split holds in Phase 0 by convention (folder-as-module for features) and by linker (real SPM packages for `OpenHLCore` and `HyperliquidAPI`). Phase 0 wires both packages even though `HyperliquidAPI` will be empty until Phase 1 — the goal is to land the boundaries before any code can violate them.

---

## 3. Swift 6 concurrency posture

- **Language mode:** Swift 6 enabled in the app target and both packages. Strict concurrency checking **on**, complete mode, from Phase 0. We are starting fresh; paying the strictness tax now is cheaper than retrofitting later.
- **Sendable:**
  - All `OpenHLCore` value types (`Address`, money types, domain models, error enums) are `Sendable`.
  - All DTOs in `HyperliquidAPI` are `Sendable` (`struct` + `Codable` + `Sendable` conformances; `final class` only if forced by `Codable`, in which case explicit `Sendable` with documented rationale).
  - View models are `@MainActor` and therefore `Sendable` by isolation.
- **Actor boundaries:**
  - `HyperliquidAPI` client types are not `@MainActor`. REST calls are plain `async` methods on a `struct` or `actor` — preference for a `struct` with `Sendable` dependencies (no shared mutable state until WebSocket arrives in Phase 3). The WebSocket client in Phase 3 will be an `actor` to serialize subscription state and reconnection.
  - View models are `@MainActor`. They call `await api.fetchX()`, then assign to `@Observable` properties — assignment is on the main actor because the view model is.
  - No `DispatchQueue.main.async` anywhere. No `@MainActor.run` wrappers in view models — the isolation is on the type.
- **Task lifetimes:** Tied to view lifetime via `.task { … }` in SwiftUI. View models do not spawn detached tasks. The composition root (the app entry) owns no long-running tasks in Phase 0; Phase 3 introduces a single scene-phase-driven live store that owns the WebSocket task.
- **Cancellation:** Cooperative. All `async` paths must honor `Task.checkCancellation()` between I/O and CPU work where it matters.
- **Compiler treatment:** Swift-6-mode warnings are errors in Release (Section 9). In Debug they remain warnings to keep iteration tolerable.

---

## 4. Dependency policy

- **Zero third-party Swift Package dependencies in v1.** No Alamofire, no Combine wrappers, no logging libraries, no analytics, no crash reporters, no UI component libraries.
- **Apple frameworks only:** `Foundation`, `SwiftUI`, `SwiftData`, `Security` (Keychain if ever needed), `OSLog` for logs.
- **Escape valve:** Adding any third-party dependency requires a `docs/decisions.md` entry with: what problem, what we tried first using Apple APIs, why the dependency is the smallest acceptable solution, license, maintenance signal, and the binary/source-size impact. PR cannot merge a `Package.swift` dependency edit without that entry.
- **Lint vs. format for Phase 0:** Use Apple's built-in `swift format` (the SwiftPM-bundled formatter, invoked via `swift format`) — not SwiftLint. Rationale lives in the decisions log; in short: it is in-tree, requires no installation, and the roadmap explicitly says "one of the two, not both." Formatting runs in CI via `swift format lint --strict` against the app sources and packages; failing formatting fails the build.

---

## 5. State management

- **`@Observable` macro** for all view models. No `ObservableObject`/`@Published`. No `@StateObject` — use `@State` for view-owned view models and inject pre-built view models for child views.
- **Per-feature view models** live next to their screens:
  ```
  OpenHL/Screens/Positions/
    PositionsView.swift
    PositionsViewModel.swift
  ```
  Each view model is `@MainActor @Observable final class`, takes its dependencies (an `HyperliquidAPI` client protocol, formatters, a clock) in its initializer, and exposes view-facing state plus `async` action methods.
- **No singletons.** No `static let shared`. No service locators. No environment-injected ambient services in v1 (we may introduce `@Environment`-based wiring later for cross-cutting concerns; in Phase 0 it is not justified).
- **Composition root:** `OpenHLApp.swift` (the `@main` struct) is the only place that constructs concrete service instances (the API client, persistence, formatters) and wires them into the root screen. Children receive what they need by constructor injection. The composition root is the only place that "knows everything." Everything else knows only its collaborators.
- **Protocol boundaries:** `HyperliquidAPI` exposes a protocol (e.g. `HyperliquidClient`) plus a concrete `URLSession`-backed implementation. View models depend on the protocol so tests inject fakes without a network. The protocol lives in `HyperliquidAPI`, not in `OpenHLCore`, because it is shaped by transport concerns.

---

## 6. Networking posture

Detailed design lands in Phase 1; this is the posture committed now.

- `URLSession` with `async/await`. No Combine. No callbacks. No third-party HTTP client.
- One `URLSession` instance per `HyperliquidClient`, configured with sensible timeouts and `waitsForConnectivity = true` for foreground fetches.
- Structured concurrency throughout: `async` functions return values, throw typed errors, and respect cancellation.
- **Typed errors:** A `HyperliquidError` enum in `HyperliquidAPI` distinguishes transport (`offline`, `timeout`, `httpStatus(Int)`), decoding (`decoding(underlying:)`), and API-shape (`unexpectedResponse`) failures. View models map these to user-facing states; they do not surface raw `URLError`.
- **`Decimal` end-to-end.** No `Double` for money — ever. Decoders read string-formatted numbers from Hyperliquid into `Decimal` via a dedicated decoding helper. Formatting for display uses `NumberFormatter`/`Decimal.FormatStyle` configured in `OpenHLCore`.
- WebSocket (Phase 3) will be `URLSessionWebSocketTask` wrapped in an `AsyncSequence` with explicit reconnect/backoff state — out of scope to detail here.

---

## 7. Persistence

The user's wallet address is **public** (it appears on the chain). It is not a secret. Some users may nevertheless prefer not to have it readable by other apps or visible in iCloud backups; this is a UX consideration, not a security one.

| Option | Pros | Cons |
|---|---|---|
| `UserDefaults` | Simplest; right primitive for "one small string preference"; survives launches; trivially testable. | Backed up to iCloud by default; readable from a debugger on an unlocked development device. |
| Keychain | Stays out of iCloud backup if configured; access-controlled. | Overkill for non-secret data; harder to test; SwiftUI integration is manual. |
| SwiftData | Future-proof for "multi-address watchlist" (post-v1). | Way too heavy for a single string; introduces a migration story we do not need. |

**Decision for Phase 1:** `UserDefaults` for the saved address, keyed under a single constant, accessed via a thin `AddressStore` protocol injected from the composition root. Trade-off accepted and documented: we are storing a public identifier in a non-secret store. If a future user-research signal says "users want this private," we migrate to Keychain behind the same `AddressStore` protocol without touching view code.

**SwiftData** stays unused in v1. We will revisit when (and only when) a multi-address watchlist is on the roadmap.

---

## 8. Testing framework

- **Swift Testing (`@Test`)** is the default for new unit tests in `OpenHLCore`, `HyperliquidAPI`, and the app-target unit test bundle. Swift Testing ships with Xcode 16, runs on iOS 17 toolchains, and the macro-based API (`#expect`, parameterized tests, traits) maps cleanly onto our needs (address validation, decoder fixtures, formatter cases).
- **XCTest** remains the framework for `OpenHLUITests` because XCUITest is XCTest-based; Apple has not yet shipped a Swift Testing equivalent for UI tests. The UI test target stays `XCTestCase`-based.
- Mixed-framework target is acceptable but we prefer to keep unit tests in Swift-Testing-only targets and UI tests in an XCTest-only target so the two macro/runtime worlds do not collide.

---

## 9. Warnings-as-errors

- **Release configuration:** `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, all targets, including local SPM packages (via `.unsafeFlags(["-warnings-as-errors"], .when(configuration: .release))` or equivalent package-level setting).
- **Debug configuration:** warnings remain warnings. Iteration speed wins over zealotry during local development.
- CI builds both configurations; the Release build is what gates merge for warning hygiene. Tests run in Debug.
- Swift-6 strict-concurrency diagnostics are warnings in Debug, errors in Release — same policy.

---

## 10. MIT license header convention

Every `.swift` source file in this repository (app target sources, package sources, test sources, scripts) begins with a single-line SPDX header on the very first line:

```swift
// SPDX-License-Identifier: MIT
```

That is the entire header. No copyright line (the `LICENSE` file at the repo root carries the copyright statement; duplicating it in every file is noise). No multi-line block. No author tag.

Rationale: SPDX is the standardized, machine-readable form; tooling (GitHub, license scanners, SBOM generators) recognizes it. A single line is small enough that contributors will actually add it, which is the property that matters.

Enforcement: a lightweight CI check greps for the SPDX line at the top of every `.swift` file outside `.build/` and `DerivedData/`. Files missing the header fail the build. (Wired in Phase 0 alongside the formatter check.)

---

## Status

This document is v0 — the Phase 0 baseline. It will be revised in Phase 1 (networking detail, `Decimal` decoding rules), Phase 3 (concurrency model for live updates, reconnect state machine), and at v1.0 sign-off. Revisions append; do not silently rewrite history. Material changes get a `docs/decisions.md` entry.

---

# Phase 1 — networking, decoding, persistence, view-model pattern

This section lands the shapes `ios-developer` will implement. Anything not codified here is up to the implementer; anything codified here is binding without a follow-up `docs/decisions.md` entry to revise it.

Code-level signatures live in the package sources:
- `Packages/OpenHLCore/Sources/OpenHLCore/*.swift`
- `Packages/HyperliquidAPI/Sources/HyperliquidAPI/*.swift`

Stubs throw `fatalError("Phase 1 ios-developer")`. Doc-comments on each declaration carry the contract. Read those alongside this section.

---

## 11. Networking layer

### 11.1 `HyperliquidClient` protocol

The protocol view models depend on. Constructor-injected. One method in Phase 1: `clearinghouseState(for:)`.

```swift
public protocol HyperliquidClient: Sendable {
    func clearinghouseState(for user: Address) async throws -> ClearinghouseState
    // TODO Phase 2: openOrders(for:) -> [OpenOrder]
    // TODO Phase 2: userFills(for:) -> [Fill]
}
```

Rules:
- `async throws`. Errors are exclusively `HyperliquidError` (see 11.4).
- `Sendable`. Conformers cross actor boundaries (constructed on the main actor in the composition root, held by `@MainActor` view models).
- No method returns DTOs. The client maps wire DTOs to domain types inside the client; the rest of the app never sees a DTO.
- Methods honor `Task.checkCancellation()` after the network call returns and before decoding, so a cancelled refresh doesn't waste CPU.

### 11.2 Concrete implementation: `URLSessionHyperliquidClient`

A `struct` (not an `actor`) with `Sendable` dependencies. `URLSession` is itself thread-safe and `Sendable`, so a struct suffices for Phase 1's pure-REST shape. (Phase 3 introduces an `actor` for the WebSocket; it does not replace this struct.)

Configuration the struct owns:

| Setting | Value | Why |
|---|---|---|
| `baseURL` | `https://api.hyperliquid.xyz` | Production endpoint. Injectable for tests. |
| `timeoutIntervalForRequest` | 15 s | Foreground fetches; a snapshot endpoint should not take 60 s. |
| `timeoutIntervalForResource` | 30 s | Ceiling that includes `waitsForConnectivity` waiting time. |
| `waitsForConnectivity` | `true` | A foreground pull-to-refresh that races a 200 ms cell-to-WiFi handoff should succeed, not throw `.offline`. The resource ceiling still bounds it. |
| `httpAdditionalHeaders` | `Content-Type: application/json`, `Accept: application/json` | Hyperliquid expects JSON. No custom `User-Agent`. |
| `requestCachePolicy` | `.reloadIgnoringLocalCacheData` | Snapshot endpoints; cached responses are worse than no response. |
| `httpShouldUsePipelining` | default | Not worth tuning at v1 volumes. |
| `URLCache` | nil | We do not cache /info responses at the URLSession layer. SwiftData snapshots (post-v1) are the appropriate cache. |

Two initializers:
- Public production init: takes `baseURL` (defaulted) and `Clock` (defaulted to `SystemClock()`). Builds its own `URLSession` from a `URLSessionConfiguration` per the table above.
- Public test-seam init: takes `baseURL`, a pre-built `URLSession`, and a `Clock`. Tests construct a configuration with a custom `URLProtocol` subclass in `protocolClasses` to stub responses (see 11.7).

### 11.3 Request/response DTO conventions

DTOs live in `Sources/HyperliquidAPI/DTOs/`. They mirror the wire format 1:1.

Rules:
- Type names suffixed with `DTO`. `internal` access — DTOs do not leak.
- `Decodable, Sendable`. `Encodable` only when needed (request bodies, round-trip tests).
- Every money field uses `@DecimalString` or `@OptionalDecimalString` (11.5). No `Double`, no `Float`, no `Decimal` decoded via default conformance — Hyperliquid sends strings.
- `CodingKeys` only when the wire name is not a valid Swift identifier. Match wire field names exactly otherwise.
- DTOs are dumb: no computed properties, no validation. Validation, branching, and shape-cleanup happen in the DTO -> domain mapper inside the client.
- The mapper is a private static function or private extension method on the client. It throws `HyperliquidError.unexpectedResponse(reason:)` for documented-but-unexpected shapes (e.g. `leverage.type` that is neither `"cross"` nor `"isolated"`).

Request encoding for `POST /info` is modeled as an `enum InfoRequest: Encodable, Sendable` with one case per request type. A custom `encode(to:)` flattens the case into the wire shape `{"type": "...", "user": "..."}`. This guarantees discriminator and parameters cannot drift apart.

### 11.4 Typed error mapping

`HyperliquidError` cases (defined in `HyperliquidError.swift`):

| Case | Source | View-model state |
|---|---|---|
| `.offline` | `URLError.notConnectedToInternet`, `.networkConnectionLost`, `.dataNotAllowed` | `.error(.offline)` |
| `.timeout` | `URLError.timedOut` | `.error(.timeout)` |
| `.httpStatus(Int)` | HTTP response outside `200..<300` | `.error(.serverError)` for 5xx; `.error(.badRequest)` for 4xx |
| `.decoding(underlying:)` | `DecodingError` from `JSONDecoder` | `.error(.unexpectedResponse)`; underlying error logged via `OSLog`, never shown |
| `.unexpectedResponse(reason:)` | post-decode invariant violation | `.error(.unexpectedResponse)` |
| `.transport(underlying:)` | any other `URLError` | `.error(.unknown)` |

`Task.CancellationError` is not a `HyperliquidError`. Cancellation propagates as itself; view models catch and ignore (cancelled refreshes are not failures). The client must not wrap `CancellationError` into a `HyperliquidError`.

View-model error states are a separate `enum ViewErrorState: Sendable, Equatable` exposed to the SwiftUI layer. The view model owns translation from `HyperliquidError` to `ViewErrorState`; the client never knows about UI states. Concrete cases the view model exposes for Phase 1:

```swift
enum ViewErrorState: Sendable, Equatable {
    case offline
    case timeout
    case badRequest        // 4xx — the address may be malformed or rate-limited
    case serverError       // 5xx — try again later
    case unexpectedResponse // decode or invariant — file a bug
    case unknown
}
```

The address-entry validation error is a separate concern (`Address.ValidationError`) and renders inline; it never becomes a `ViewErrorState`.

### 11.5 `Decimal` decoding rules

The single rule: any JSON field that represents money is decoded via `@DecimalString` (or `@OptionalDecimalString` for nullable fields). A `Double` or `Float` on a money path is a code-review blocker.

`@DecimalString` (in `OpenHLCore`):
- Decodes from a JSON string token. Rejects numeric tokens.
- Trims surrounding whitespace.
- Accepts leading `-`. Rejects leading `+`. Rejects grouping separators. Accepts no decimal point or one.
- Throws `DecodingError.dataCorruptedError` with a path-aware message on malformed input, so `HyperliquidError.decoding(underlying:)` carries useful context.
- Locale-agnostic: parses with `.` as the decimal separator regardless of system locale.

`@OptionalDecimalString` behaves identically but treats `null` and missing keys as `nil`.

For one-off parsing outside `Codable` (tests, custom paths) call `DecimalParsing.parse(_:) -> Decimal?` with the same rules.

### 11.6 Retry / backoff policy

**Phase 1: no retry inside the client.** One attempt per call.

Rationale:
- Retries inside the client hide what is happening from the view model and from the user. A user staring at a spinner for 45 s on a flaky network is a worse experience than a fast error with a "Try again" affordance.
- Retry policies tangle with cancellation. `pull-to-refresh` should cancel the previous in-flight call cleanly; a retry loop introduces a "should this retry start when the previous one is cancelled mid-retry?" question we do not need to answer.
- Pull-to-refresh is the user's retry control. The view model exposes a `refresh()` async method; views drive it via the standard SwiftUI `.refreshable` modifier.

`waitsForConnectivity = true` is not a retry — it is a one-shot wait inside the resource ceiling. That stays on.

Phase 3 will introduce a reconnect/backoff state machine for the WebSocket. That is a different problem (long-lived connection, server-driven push) and gets its own design.

### 11.7 Test fixtures and `URLProtocol` stubs

Fixtures live in:

```
Packages/HyperliquidAPI/Tests/HyperliquidAPITests/Fixtures/
  clearinghouseState_typical.json
  clearinghouseState_empty.json          # no positions, zero balances
  clearinghouseState_largeNegativePnL.json
  clearinghouseState_isolatedLeverage.json
  clearinghouseState_missingLiquidationPx.json
  clearinghouseState_malformed_decimal.json   # for negative-path decoder tests
```

Loading: a `FixtureLoader` helper in `Tests/HyperliquidAPITests/Support/` reads files via `Bundle.module.url(forResource:withExtension:subdirectory:)`. The package manifest must declare `.process("Fixtures")` (or `.copy("Fixtures")`) on the test target's resources so they are bundled. The `ios-developer` updates `Package.swift` accordingly when wiring fixtures.

For decoder unit tests against the DTOs and the DTO -> domain mapper, the test instantiates the mapper directly with the loaded JSON `Data`. No `URLSession`.

For end-to-end client tests (request shape + response decode + error mapping), a `URLProtocol` subclass in `Support/` intercepts requests:
- `StubURLProtocol` is registered via `URLSessionConfiguration.protocolClasses = [StubURLProtocol.self]` and the configuration is handed to `URLSessionHyperliquidClient`'s test-seam init.
- Per-test setup installs a handler `(URLRequest) -> (HTTPURLResponse, Data?)` or `(URLRequest) -> Error`. The handler runs synchronously inside `URLProtocol.startLoading`.
- The handler asserts on the request shape (URL, method, body decoded back into `InfoRequest` for round-trip verification) and returns the fixture data.

Tests must be hermetic: no real network calls in any test target. CI enforces this implicitly — runners may have no network — but the rule is also a `qa-automation` review checkpoint.

---

## 12. `AddressStore` protocol

Lives in `HyperliquidAPI`, not `OpenHLCore`. Rationale: `OpenHLCore` is a pure-value-types leaf with no I/O; a protocol whose concrete impl does `UserDefaults` (and may later do Keychain) is not pure. The Phase 1 consumer (the address-entry view model) already imports `HyperliquidAPI` for the client, so co-locating adds no import edges. (Logged as a decision.)

```swift
public protocol AddressStore: Sendable {
    func load() -> Address?
    func save(_ address: Address)
    func clear()
}
```

Synchronous. `UserDefaults` reads/writes are fast and lock-free at single-key scale; an `async` protocol would buy nothing.

`load()` is forgiving: a stored value that no longer passes `Address` validation (older build wrote a different shape, manual edit on a development device, etc.) returns `nil` rather than crashing. The next `save` overwrites it.

Concrete implementations:
- `UserDefaultsAddressStore` — production. Takes a `UserDefaults` (defaults to `.standard`) so tests can inject a suite-backed instance. Storage key is `openhl.address`, exposed as a `public static let` so tests can pre-seed without depending on the struct.
- `InMemoryAddressStore` — for tests. `final class` with an internal lock so cross-actor access from tests is safe. Initializer accepts an optional seed value.

A future Keychain-backed implementation conforms to the same protocol; view code does not change.

---

## 13. View-model pattern for Phase 1

### 13.1 Shape

Every screen has a view model:

```swift
@MainActor
@Observable
final class PositionsViewModel {

    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded(ClearinghouseState)
        case error(ViewErrorState, lastLoaded: ClearinghouseState?)
    }

    private(set) var state: State = .idle

    private let client: any HyperliquidClient
    private let address: Address
    private let clock: any Clock

    init(client: any HyperliquidClient, address: Address, clock: any Clock) {
        self.client = client
        self.address = address
        self.clock = clock
    }

    func load() async { /* sets .loading, calls client, updates state */ }
    func refresh() async { /* same as load(), preserves lastLoaded on error */ }
}
```

Rules:
- `@MainActor @Observable final class`. No `ObservableObject`, no `@Published`.
- `state` is a single enum. Views switch on it. No separate `isLoading`/`error`/`data` booleans.
- `.error` carries the last successfully-loaded snapshot, so the UI can keep showing old data dimmed while presenting the error banner. Pull-to-refresh produces an `.error(_, lastLoaded: X)` state on failure, not an `.error(_, lastLoaded: nil)` — `nil` is only for the cold-load error path.
- View model `init` takes dependencies (`HyperliquidClient`, `Address`, `Clock`, possibly `AddressStore`). No default values, no factory methods, no static singletons.
- `load()` and `refresh()` are `async` and `@MainActor`. They do not spawn `Task`s themselves. The view invokes them inside `.task` or `.refreshable`, which manage the `Task` lifetime.

### 13.2 Cancellation

- Views drive task lifetime via `.task { await viewModel.load() }`. SwiftUI cancels that task on view disappear.
- A new `refresh()` started while a previous one is in flight cancels the previous via SwiftUI's `.refreshable` semantics — actually, `.refreshable` awaits the closure to completion, so by construction there is no overlap. The view model does not need an explicit cancellation token in Phase 1.
- Inside `load()`/`refresh()`, the view model checks `Task.isCancelled` after the `await client.clearinghouseState(...)` returns and before mutating `state`, so a cancelled call cannot stomp a newer state. The client itself also honors cancellation (11.1).

### 13.3 Pull-to-refresh

The `PositionsView` uses `.refreshable { await viewModel.refresh() }`. That is the only mapping. The view model has no separate "is-refreshing" flag; the active state during refresh is the existing one (`.loaded` keeps rendering data; the system refresh control owns the spinner).

### 13.4 Composition root

`OpenHLApp.swift`:

```swift
@main
struct OpenHLApp: App {
    private let clock = SystemClock()
    private let client: any HyperliquidClient
    private let addressStore: any AddressStore

    init() {
        self.client = URLSessionHyperliquidClient(clock: clock)
        self.addressStore = UserDefaultsAddressStore()
    }

    var body: some Scene {
        WindowGroup {
            RootView(client: client, addressStore: addressStore, clock: clock)
        }
    }
}
```

`RootView` reads `addressStore.load()` to decide whether to show address entry or positions. It constructs the appropriate view model with the dependencies it received from the app. No environment-injected ambient services in Phase 1. No `@EnvironmentObject`.

---

## 14. Public API of `OpenHLCore` (Phase 1)

Code lives in the package sources; doc-comments are the contract. Summary:

| Type | Kind | Purpose |
|---|---|---|
| `Address` | struct (value type) | Validated 0x+40hex wallet address. `Sendable`, `Hashable`, `Codable`. Throwing init + non-throwing failable init. |
| `Address.ValidationError` | enum | `empty`, `missingPrefix`, `wrongLength(actual:)`, `nonHexCharacter`. |
| `Money` | typealias for `Decimal` | Single typealias; no newtype in Phase 1. (Logged decision.) |
| `@DecimalString` | property wrapper | Money decode/encode helper. Locale-agnostic. |
| `@OptionalDecimalString` | property wrapper | Same, for nullable fields. |
| `DecimalParsing.parse(_:)` | enum namespace | One-off parsing outside Codable. |
| `MoneyFormatter` | enum namespace | `usd`, `signedUSD`, `signedPercent`, `decimal`. All take an explicit `Locale` defaulted to `.autoupdatingCurrent`. |
| `Clock` protocol | protocol | `now() -> Date`. `Sendable`. |
| `SystemClock` | struct | Production: returns `Date()`. |
| `FixedClock` | final class | Test: settable, advance-by, internally synchronized. |

Why a typealias and not a newtype for `Money`: Hyperliquid mixes account-USD, asset sizes, prices, PnL, fees in one response. A single `Money` newtype would be type-soup; a family of newtypes (`USDValue`, `AssetSize`, `Price`) is a real design exercise we do not need in Phase 1 (no arithmetic across kinds yet). The typealias documents intent at every use site without imposing a wrap/unwrap tax. Revisit if Phase 2/3 arithmetic justifies it.

Why a custom `Clock` and not stdlib `Clock`: we need `Date` for display and `Date`-relative SwiftUI APIs. The stdlib protocol is built around `Duration` and adds ceremony with no payoff here.

---

## 15. Public API of `HyperliquidAPI` (Phase 1)

| Type | Kind | Purpose |
|---|---|---|
| `HyperliquidClient` | protocol | View-model-facing API. Phase 1: `clearinghouseState(for:)`. |
| `URLSessionHyperliquidClient` | struct | Production impl. Two inits (production / test seam). |
| `HyperliquidError` | enum | `offline`, `timeout`, `httpStatus`, `decoding`, `unexpectedResponse`, `transport`. |
| `ClearinghouseState` | struct (domain) | Account summary + positions + serverTime + fetchedAt. |
| `ClearinghouseState.AccountSummary` | nested struct | USD aggregates. |
| `ClearinghouseState.Position` | nested struct | One position; `Side`, `LeverageMode`. |
| `InfoRequest` | enum (Encodable) | Discriminated POST /info body. Phase 1: `clearinghouseState(user:)`. |
| `AddressStore` | protocol | Persistence. |
| `UserDefaultsAddressStore` | struct | Production impl. |
| `InMemoryAddressStore` | final class | Test impl. |

DTOs (`ClearinghouseStateDTO`, etc.) are `internal` — they do not appear in the public API.

TODO Phase 2: `openOrders(for:)`, `userFills(for:)`, the matching `InfoRequest` cases, their DTOs and domain models. Left as TODO comments in the source.

---

## Status (Phase 1)

The sections above are the Phase 1 baseline. Phase 2 additions follow as §16–§22.

---

# Phase 2 — open orders and recent fills

This section extends the networking layer with the two remaining REST endpoints needed for v1 read-only screens: `openOrders` and `userFills`. It also pins the conventions every later phase inherits: how we encode `side` across DTO and domain, what the cap/pagination story is, and which view-model pattern the two new tabs follow (same as Phase 1's `PositionsViewModel`).

Code-level signatures live in the package sources:
- `Packages/HyperliquidAPI/Sources/HyperliquidAPI/OpenOrder.swift`
- `Packages/HyperliquidAPI/Sources/HyperliquidAPI/Fill.swift`
- `Packages/HyperliquidAPI/Sources/HyperliquidAPI/DTOs/OpenOrdersDTO.swift`
- `Packages/HyperliquidAPI/Sources/HyperliquidAPI/DTOs/UserFillsDTO.swift`

Stubs throw `fatalError("Phase 2 ios-developer")` for method bodies; type, DTO, and protocol declarations are real. Read the source doc-comments alongside this section.

---

## 16. `HyperliquidClient` — Phase 2 additions

Two new methods on the same protocol. Adding methods to a Swift protocol is **non-breaking for existing concrete conformers only when those conformers add the new methods too**; we ship updated test fakes and the production client in the same change. There is no `extension HyperliquidClient` default implementation — every conformer is required to implement every endpoint, intentionally. A "client that only does Phase 1" is not a thing we want to express in the type system.

```swift
public protocol HyperliquidClient: Sendable {
    func clearinghouseState(for user: Address) async throws -> ClearinghouseState
    func openOrders(for user: Address) async throws -> [OpenOrder]
    func userFills(for user: Address) async throws -> [Fill]
}
```

Rules (unchanged from §11.1):
- `async throws`. Errors are exclusively `HyperliquidError`. No new error cases are needed — see §19.
- `Sendable`. The struct concrete impl remains a `struct` with `Sendable` dependencies. No actor introduced for the new endpoints.
- Methods do not return DTOs. The client maps wire DTOs to `OpenOrder` / `Fill` domain values inside the client; the rest of the app never sees a DTO.
- `Task.checkCancellation()` between transport and decode (same pattern as `clearinghouseState`).
- No retry inside the client (§11.6 still binding).

`InfoRequest` gains two cases:

```swift
case openOrders(user: Address)
case userFills(user: Address)
```

Each encodes to `{"type": "<discriminator>", "user": "0x..."}` exactly like the existing case. The flat-encode pattern (§11.3) holds.

---

## 17. Pagination, cap, and sort

### 17.1 `openOrders`

No cap. Hyperliquid returns only currently-resting orders, which is bounded by Hyperliquid's per-account order-count limit (small two-digit numbers in practice). Capping here would buy nothing and could hide real account state. If a future product signal says "users have hundreds of open algos," we revisit.

### 17.2 `userFills` — cap at 200, no fetch-more

Hyperliquid's `userFills` endpoint **does not paginate**. The response is the user's recent fills (server-side window). Three options were on the table:

| Option | Verdict | Why |
|---|---|---|
| (a) Cap at the transport layer to first N (e.g. 200) | **Chosen** | Bounded memory and render cost; view models stay trivial; users see "most recent N" which is the only thing the API meaningfully exposes. |
| (b) Pass everything through and let the view show a "Showing recent N" footer above a threshold | Rejected | Asymmetric responsibility — the client returns unbounded data but the view promises a bound. Either layer can break the contract on its own. |
| (c) Infinite-scroll fetch-more | Rejected | API does not paginate. There is no `before:tid` cursor. We'd be lying with a UI affordance backed by nothing. |

The cap is **200** in Phase 2. Rationale: covers the realistic-active-trader case (~hundreds of fills per week) without paging in MB of JSON onto an iPhone screen; below the threshold where SwiftUI `List` lazy loading starts to matter materially. Exposed as `public static let userFillsCap: Int = 200` on `URLSessionHyperliquidClient` so tests can assert on it and a later phase can bump it via a decision entry. The cap is a transport-level slice on `Array.prefix(_:)` after decode and after domain mapping; views render a footer ("Showing 200 most recent fills") only when `fills.count == 200`. That heuristic is good enough — when the server happens to return exactly 199, no footer is shown, and that is acceptable.

### 17.3 Sort

Both endpoints return arrays in their own server order, which is reverse-chronological in practice. The transport layer **does not re-sort** — DTOs reflect API order, the domain mapper preserves order. View models impose their preferred presentation sort:

- `OrdersViewModel`: `orders.sorted { $0.placedAt > $1.placedAt }` (newest first).
- `FillsViewModel`: `fills.sorted { $0.executedAt > $1.executedAt }` (newest first).

Both sorts are stable in the value-equality sense (Swift's `sorted(by:)` is not technically stable, but the keys here are unique per element). View models that later want grouping (e.g. group-by-day on fills) compute groupings on the sorted array.

The transport stays sort-agnostic on purpose: tests for the client assert on identity of returned arrays without imposing a sort, and a future "raw" caller (e.g. a debug screen) gets API truth.

---

## 18. DTO conventions for the new endpoints

§11.3 binds. Re-stating the parts that interact with new wire shapes:

- Each endpoint returns a top-level JSON array. DTOs are modeled as `internal struct OpenOrderDTO: Decodable, Sendable` and `internal struct UserFillDTO: Decodable, Sendable`; the client decodes `[OpenOrderDTO].self` / `[UserFillDTO].self` directly with `JSONDecoder`.
- **Money fields use `@DecimalString` everywhere.** `limitPx`, `sz`, `triggerPx`, `origSz` on orders; `px`, `sz`, `fee`, `closedPnl` on fills. `@OptionalDecimalString` for the two genuinely-optional money fields (`origSz`, `triggerPx`). `closedPnl` is **non-optional** — the wire always sends it, even as `"0.0"` on opening fills.
- **`side` on the wire is `"B"` (buy) or `"A"` (ask / sell).** The DTO holds it as a `String`. The mapper translates to `OpenOrder.Side` / `Fill.Side` (a closed `.buy`/`.sell` enum); unknown wire strings throw `HyperliquidError.unexpectedResponse(reason:)`. The domain types never expose `"B"`/`"A"`. (Decision logged.)
- **`orderType` on the wire is a human-readable string** (`"Limit"`, `"Trigger"`, `"Stop Limit"`, `"Stop Market"`, `"Take Profit Limit"`, `"Take Profit Market"`). The DTO holds it as `String`. The mapper translates to `OpenOrder.OrderType` (closed enum); unknown wire strings throw `HyperliquidError.unexpectedResponse(reason:)`. As with `LeverageMode`, the closed enum is a feature: a new HL order type lands as a compile-time failure in the mapper, not a silent default in the UI.
- **`dir` (fill direction) on the wire is preserved verbatim** as `Fill.direction: String`. It is the primary descriptor in the fills UI — `"Open Long"` is more informative than `.buy`. The closed-enum exercise can wait (decision logged).
- **`reduceOnly` and `origSz` may be missing from the wire.** Modeled as `Bool?` / `Decimal?` in the DTO. The mapper defaults `reduceOnly` to `false` (Hyperliquid's documented convention) and passes `origSz` through as-is — views render `size` when `origSize == nil`.
- **Empty-string-as-nil rule:** we do not encounter this on these endpoints. If a future Hyperliquid response sends `""` for an optional money field, `@OptionalDecimalString` rejects it (the parser refuses empty strings) and the decode fails with a path-aware error. That is the desired behavior — we re-decide explicitly via a decision entry rather than silently coercing to `nil`.

---

## 19. Error mapping — unchanged

Phase 2 adds **no new `HyperliquidError` cases**. The six cases from §11.4 cover everything the new endpoints can fail with:

- Transport / offline / timeout — handled by the existing `URLError` mapping.
- Non-2xx HTTP — `.httpStatus(Int)`. Hyperliquid returns 422 with an empty body when the address is malformed, which is the most common 4xx; the view model's existing `.badRequest` rendering applies unchanged.
- Decode failures — `.decoding(underlying:)`.
- Unknown enum values from the wire (`side` not in `B`/`A`, `orderType` not in the known list) — `.unexpectedResponse(reason:)`.

The view-model `ViewErrorState` enum is unchanged (§11.4). Adding cases there would force every existing view to recompile its `switch`; nothing about Phase 2 motivates that.

---

## 20. View-model pattern for the new tabs

Each new tab gets its own `@MainActor @Observable final class`. The shape is the same as Phase 1's `PositionsViewModel` (§13). Sketches only — `ios-developer` implements:

```swift
@MainActor @Observable final class OrdersViewModel {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded([OpenOrder])
        case error(ViewErrorState, lastLoaded: [OpenOrder]?)
    }
    private(set) var state: State = .idle

    private let client: any HyperliquidClient
    private let address: Address
    private let clock: any Clock

    init(client: any HyperliquidClient, address: Address, clock: any Clock) { … }
    func load() async { … }
    func refresh() async { … }
}

@MainActor @Observable final class FillsViewModel {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded([Fill])
        case error(ViewErrorState, lastLoaded: [Fill]?)
    }
    // same shape as above
}
```

Rules (§13 binds; the parts worth re-stating):

- **`lastLoaded` is the same affordance as Phase 1.** On refresh failure, the view model produces `.error(_, lastLoaded: previousArray)` so the UI keeps showing prior data dimmed with an inline error banner over the top. The view models extract `lastLoaded` by reading their current `state` before kicking off the refresh; if the current state is `.loaded(x)`, the refresh keeps `x` available for the failure path. Cold-load failures produce `.error(_, lastLoaded: nil)`.
- **No shared store across tabs in Phase 2.** Each tab owns its own view model. The composition root constructs three view models (`PositionsViewModel`, `OrdersViewModel`, `FillsViewModel`) and hands each to its tab. On tab appear, the view model runs `.task { await viewModel.load() }`; on pull-to-refresh, `.refreshable { await viewModel.refresh() }`. This duplicates the address-and-clock plumbing across three constructors — acceptable cost. The shared-store question (a single account store that fans out to all three tabs) lands in Phase 3 when the WebSocket gives us a reason for one source of truth across screens. (Decision logged.)
- **Refetch on appear is the v1 contract.** Tabs do not cache across navigation in Phase 2 — switching to Orders refetches Orders. SwiftUI's `.task` re-runs when the view appears; that is the mechanism. If the user feels this is too aggressive, we revisit in Phase 3 once we have a live store.
- **Cancellation** is identical to Phase 1: `.task` cancels on disappear, `.refreshable` awaits to completion, the view model checks `Task.isCancelled` between the await and the `state` assignment.

---

## 21. Composition root — Phase 2 wiring

`OpenHLApp.swift` constructs the client and address store once. `RootView` reads `addressStore.load()` and either shows address entry or the **section/tab shell**. The shell is `ios-developer`'s territory (per the navigation spec from `uxui-designer`); from a wiring perspective it constructs three view models with the same `(client, address, clock)` triple and hands each to its tab.

No new types in `OpenHLCore` or `HyperliquidAPI` are required at the composition layer. The `HyperliquidClient` protocol gained two methods; the same single instance serves all three view models.

---

## 22. Test fixtures and `URLProtocol` stubs

Same layout as §11.7. New fixtures land under:

```
Packages/HyperliquidAPI/Tests/HyperliquidAPITests/Fixtures/
  openOrders_typical.json
  openOrders_empty.json
  openOrders_withTrigger.json
  openOrders_missingOptionalFields.json   # origSz / reduceOnly absent
  openOrders_unknownOrderType.json        # negative-path mapper test
  openOrders_unknownSide.json             # negative-path mapper test
  userFills_typical.json
  userFills_empty.json
  userFills_singleLiquidation.json
  userFills_overCap.json                  # > 200 entries; asserts cap behavior
  userFills_malformed_decimal.json        # negative-path decoder test
```

`Package.swift` already declares `.copy("Fixtures")` on the test target; new files in the directory are picked up automatically.

`FakeHyperliquidClient` (in `Tests/HyperliquidAPITests/Support/`) is extended with `openOrdersResult: Result<[OpenOrder], HyperliquidError>` and `userFillsResult: Result<[Fill], HyperliquidError>` so view-model tests can drive both endpoints without `URLSession`. The fake remains `@unchecked Sendable` with the same disclaimer as Phase 1.

End-to-end tests use the existing `StubURLProtocol` — the URL is the same `/info`, the body discriminator is different. Tests assert on:
- Request shape: URL, method, headers, body (decoded back into `InfoRequest` for round-trip verification).
- Response decode: each fixture decodes without error; field values match expected `Decimal` values exactly.
- Negative paths: malformed decimals throw `.decoding`; unknown enum values throw `.unexpectedResponse`.
- Cap: the `userFills_overCap.json` fixture produces exactly `userFillsCap` results in the returned domain array.

Tests must remain hermetic (no real network). The same rule from §11.7 binds.

---

## Status (Phase 2)

This document is now at the Phase 2 baseline. Next revision is Phase 3 (WebSocket concurrency model, reconnect state machine, shared live store).

