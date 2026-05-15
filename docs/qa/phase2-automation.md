# QA automation test plan — Phase 2 (open orders + recent fills)

**Status:** tests authored, awaiting `ios-developer` view-model implementation.
**Coverage area:** `openOrders` and `userFills` REST endpoints, decoder/mapper layer, view-model state machines, tab navigation.

---

## What is covered

### HyperliquidAPITests — decoder + transport (all enabled, run via `swift test`)

| Test file | Suite | Count | Status |
|---|---|---|---|
| `Phase2DecodingTests.swift` | `openOrders — fixture decoding` | 7 | Enabled (disabled by `fatalError` in impl — see §Blocked) |
| `Phase2DecodingTests.swift` | `userFills — fixture decoding` | 6 | Enabled |
| `Phase2DecodingTests.swift` | `openOrders — request shape` | 3 | Enabled |
| `Phase2DecodingTests.swift` | `userFills — request shape` | 3 | Enabled |
| `Phase2DecodingTests.swift` | `Phase 2 endpoints — error mapping` | 8 | Enabled |

Key assertions:
- `openOrders_empty` / `userFills_empty` → empty arrays, no crash.
- `openOrders_single_limit` → side `"B"` maps to `.buy`, `origSize` present (partial fill), `timestamp` converted from ms to `Date`.
- `openOrders_mixed_buy_sell` → `"A"` maps to `.sell`, mixed `orderType`s, missing `origSz` → `nil`.
- `openOrders_with_trigger_price` → `triggerPrice` non-nil for Stop Limit and Take Profit Limit.
- `openOrders_missing_optional_fields` → `origSize == nil`, `reduceOnly == false` (default).
- `openOrders_unknown_side` → throws `HyperliquidError.unexpectedResponse`.
- `openOrders_unknown_orderType` → produces `OrderType.unknown("FutureAlgoOrder")` without throwing.
- `userFills_single_open_long` → `direction == "Open Long"`, `closedPnL == 0.0`, `side == .buy`.
- `userFills_close_short_with_pnl` → `direction == "Close Short"`, positive `closedPnL`.
- `userFills_liquidation` → `direction == "Liquidated Long"` verbatim, domain decode succeeds, `closedPnL < 0`.
- `userFills_large_decimals` → 15-digit precision preserved in `Decimal` (no floating-point loss).
- `userFills_over_cap` (250 entries) → returned array has exactly 200 items (`userFillsCap`), first 200 in API order (tids 9100000000–9100000199).
- Request shape: POST, `https://api.hyperliquid.xyz/info`, `Content-Type: application/json`, body `{"type":"openOrders"/"userFills","user":"<lowercase>"}`.
- Error mapping: HTTP 500 → `.httpStatus(500)`, offline → `.offline`, timeout → `.timeout`, malformed JSON → `.decoding`, HTTP 422 → `.httpStatus(422)`.

### OpenHLTests — view-model state machines (disabled, awaiting impl)

| Test file | Suite | Count | Status |
|---|---|---|---|
| `Phase2ViewModelTests.swift` | `OrdersViewModel — state machine` | 8 | `.disabled("Waiting for ios-developer to land OrdersViewModel")` |
| `Phase2ViewModelTests.swift` | `FillsViewModel — state machine` | 8 | `.disabled("Waiting for ios-developer to land FillsViewModel")` |

Key assertions (will activate when `.disabled` is removed):
- `.idle` → `.loading` → `.loaded(items)` happy path.
- `.error(.offline, lastLoaded: nil)` on cold-load failure.
- `.error(.offline, lastLoaded: previousItems)` on refresh failure — `lastLoaded` carries prior data.
- Sort: orders by `placedAt` descending; fills by `executedAt` descending. Verified by feeding deliberately unsorted input.
- Empty array: `.loaded([])` — not an error state.

### OpenHLUITests — tab navigation (disabled, awaiting impl)

| Test file | Class | Count | Status |
|---|---|---|---|
| `OpenHLUITests.swift` | `TabNavigationUITests` | 2 | `XCTSkip` (requires tab shell + UITestStubClient key) |

Stub key contract for `ios-developer`:
```
OPENHL_UI_TEST_STUB = "tab_shell_stub"
  clearinghouseState → single BTC long (existing makeSingleLong() data)
  openOrders        → one BTC Limit buy order (static values)
  userFills         → one ETH Close Short fill with positive PnL
```
Tests assert: all three tab bar buttons exist, "Account value" on Positions, "BTC" static text on Orders, "ETH" static text on Fills.

---

## What is NOT covered (and why)

| Gap | Reason | Routed to |
|---|---|---|
| Cancellation of in-flight `load()` by a second `load()` call | Architecture §20 says `.task` in SwiftUI cancels on view disappear; `.refreshable` awaits to completion so there is no overlap by construction. The pure-Swift stub VM cannot replicate SwiftUI task-cancellation semantics. | `qa-manual` for exploratory verification once the real screen exists. |
| Pull-to-refresh haptics (`UIFeedbackGenerator`) | Not testable in XCUITest without device. | `qa-manual` device checklist. |
| Dynamic Type reflow (AX3+, AX5) layout | Requires visual inspection; no snapshot library approved by `swift-expert`. | `qa-manual` accessibility audit (Phase 4). |
| VoiceOver label correctness | XCUITest can assert element existence but cannot verify spoken strings reliably on CI. | `qa-manual`. |
| "Showing 200 most recent fills" footer appearance | Requires the real `FillsView` and a response of exactly 200 fills. Covered by the cap-count assertion in `userFills — fixture decoding`; footer text requires a UI test with real view. | `qa-manual` / Phase 4 UI test expansion. |
| `triggerPx` null vs. absent JSON | `null` and absent behave identically for `@OptionalDecimalString` by design. No separate fixture needed; the behavior is covered by `openOrders_single_limit` (null) and `openOrders_missing_optional_fields` (absent). | — |
| Fee token variety (non-USDC) | No observed fixture from real API yet. When a non-USDC fee token is confirmed, add a fixture. | `qa-manual` to collect from a real account. |

---

## Fixtures authored

All files in `Packages/HyperliquidAPI/Tests/HyperliquidAPITests/Fixtures/`:

| File | Purpose |
|---|---|
| `openOrders_empty.json` | `[]` — empty list baseline |
| `openOrders_single_limit.json` | One buy-side partial fill limit order (origSz > sz) |
| `openOrders_mixed_buy_sell.json` | Buy + sell, Limit + Trigger orderTypes |
| `openOrders_with_trigger_price.json` | Stop Limit and Take Profit Limit with `triggerPx` |
| `openOrders_unknown_side.json` | `side: "X"` — negative path for mapper |
| `openOrders_unknown_orderType.json` | `orderType: "FutureAlgoOrder"` — `.unknown(String)` fallback |
| `openOrders_missing_optional_fields.json` | `origSz` and `reduceOnly` absent |
| `userFills_empty.json` | `[]` — empty list baseline |
| `userFills_single_open_long.json` | `dir: "Open Long"`, `closedPnl: "0.0"` |
| `userFills_close_short_with_pnl.json` | `dir: "Close Short"`, signed positive `closedPnl` |
| `userFills_liquidation.json` | `dir: "Liquidated Long"` — direction verbatim |
| `userFills_large_decimals.json` | Full-precision decimal values |
| `userFills_over_cap.json` | 250 fills (generated by Python; tids 9100000000–9100000249) |

---

## Decisions respected

- Cap = 200 (`URLSessionHyperliquidClient.userFillsCap`) — decisions.md 2026-05-15.
- `OpenOrder.side` is `.buy`/`.sell`; wire `"B"`/`"A"` mapped in the DTO mapper — decisions.md 2026-05-15.
- `orderType` unknown → `OrderType.unknown(String)` (no throw) — task brief override of architecture §18.
- `Fill.direction` is verbatim `String` — decisions.md 2026-05-15.
- Transport layer does NOT sort; view models sort by `placedAt`/`executedAt` descending — architecture §17.3.
- No shared store across tabs — decisions.md 2026-05-15.

---

## Enabling disabled tests (checklist for ios-developer)

When `OrdersViewModel` and `FillsViewModel` are implemented:

1. Open `OpenHLTests/Phase2ViewModelTests.swift`.
2. Delete all local stub types (the `private enum/struct/final class` blocks under "Local stub types").
3. Add `import HyperliquidAPI` and import whichever module owns the view models.
4. Replace `StubOrdersViewModel` / `StubFillsViewModel` references with the real types.
5. Remove `.disabled(...)` from both `@Suite` annotations.
6. Run `xcodebuild test -project OpenHL.xcodeproj -scheme OpenHL`.

When the tab shell and `UITestStubClient` key land:

1. Open `OpenHLUITests/OpenHLUITests.swift`.
2. Remove the two `XCTSkip` calls in `TabNavigationUITests`.
3. Verify the static-text labels ("BTC", "ETH", "Account value") match what the real views emit.
