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
