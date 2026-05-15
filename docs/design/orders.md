# Design spec: open orders screen (Phase 2)

**Feature:** `orders`
**Phase:** 2
**Owner:** uxui-designer
**Last updated:** 2026-05-15

---

## 1. Goal

Show the user's currently resting open orders in a scannable list, with enough context per row to understand what each order will do without opening a detail screen.

---

## 2. User scenario

The user is on the Orders tab. They placed several limit orders earlier and want to know which ones are still active, at what prices, and how much of each is still unfilled. They glance at the list, confirm the key orders are there, and switch back to Positions. The interaction is typically under 30 seconds. Precision and density matter more than decoration.

---

## 3. API fields surfaced vs. deferred

The `openOrders` response includes per-order: `coin`, `side` (B/A or buy/sell), `limitPx`, `sz` (remaining size), `oid`, `timestamp` (ms), `origSz`, `reduceOnly`, `orderType` (Limit/Trigger/etc.), optional `triggerPx`.

**Surfaced in the row:**
- `coin` — asset identifier, most important
- `side` — buy or sell, rendered as chip consistent with Positions long/short style
- `orderType` — "Limit", "Stop Limit", etc.; secondary descriptor
- `sz` — remaining size (what's still resting)
- `limitPx` — the resting price
- Age derived from `timestamp` — relative ("3m ago") on the row
- `reduceOnly` — badge if true; many orders are not reduce-only so the absence is not noise
- `triggerPx` — shown only when present (Trigger/Stop orders)

**Deferred (not shown in v1 row):**
- `oid` — internal ID, not meaningful to the user in v1
- `origSz` — original size; the remaining `sz` is what matters; filled amount can be inferred but adds row complexity
- Full ISO timestamp — available via VoiceOver accessibility label and long-press/tap detail (open question #1)

**Design decision on `origSz`:** Not surfaced in the row. Showing both original size and remaining size adds a "partially filled" status that is useful but adds row complexity. Deferred to post-v1 or a future detail screen. If the order is partially filled (`sz < origSz`), the row shows only `sz` with no annotation. Log as decision.

---

## 4. Grouping and sorting

**Decision: flat list, sorted by timestamp descending (most recent first).**

No grouping by coin in v1. Rationale:

- Most users have a small number of open orders (single-digit to low double-digit). Grouping adds visual chrome (section headers, indentation) that gives little return when the list fits on one screen.
- Time-descending puts the most recently placed order at the top, which is where the user's attention goes after placing a new order. They want to confirm their last action.
- If a user has orders for many coins, alphabetical grouping by coin would help, but this requires a secondary sort decision within each group. Keeping it flat and time-descending is the simplest consistent default.
- The roadmap explicitly says "grouped or sorted sensibly (decision logged)." This is logged: flat list, timestamp descending.

Future enhancement: a sort/group toggle could be added above the list. Out of scope for Phase 2.

---

## 5. States and wireframes

### 5a. Loading — cold start

```
┌──────────────────────────────────────┐
│  0x3f5C…833D         open-hl    ⚙   │  ← nav bar (no gear on Orders — see note)
├──────────────────────────────────────┤
│                                      │
│                                      │
│                                      │
│            ◌                         │  ← ProgressView, centered
│            Fetching orders…          │  ← subheadline, secondary label
│                                      │
│                                      │
│                                      │
├──────────────────────────────────────┤
│  chart.bar.doc   list.bullet  clock  │  ← tab bar
│    Positions       Orders      Fills │
└──────────────────────────────────────┘
```

Notes:
- No skeleton rows. Centered spinner identical in structure to Positions cold-start loading.
- Nav bar shows truncated address (leading) and "open-hl" (center principal). No settings gear on Orders tab — settings lives on Positions only (see navigation.md).
- The `ProgressView` uses `.progressViewStyle(.circular)` with `.scaleEffect(1.2)` matching Positions.
- VoiceOver: the spinner area has `.accessibilityElement(children: .combine)` with label "Fetching open orders."

---

### 5b. Success — orders present

```
┌──────────────────────────────────────┐
│  0x3f5C…833D         open-hl         │
├──────────────────────────────────────┤
│  OPEN ORDERS  (4)                    │  ← section header, all caps, footnote
├─────────────────────────────────────┤
│  BTC-USD                  Buy  ▲     │  ← coin (headline) + side chip (trailing)
│  Limit                               │  ← order type (subheadline, secondary)
│  Size   0.1000 BTC                   │  ← body, secondary label
│  Price  $60,000.00                   │  ← body
│  3m ago                              │  ← caption, tertiary
├─────────────────────────────────────┤
│  ETH-USD                 Sell  ▼     │
│  Stop Limit                          │
│  Size   1.0000 ETH                   │
│  Price  $3,100.00                    │  ← limit price (resting price)
│  Trigger  $3,050.00                  │  ← only shown when triggerPx present
│  Reduce only                         │  ← badge only when reduceOnly=true
│  12m ago                             │
├─────────────────────────────────────┤
│  SOL-USD                  Buy  ▲     │
│  Limit                               │
│  Size   5.0000 SOL                   │
│  Price  $130.00                      │
│  1h ago                              │
├─────────────────────────────────────┤
│  ARB-USD                 Sell  ▼     │
│  Limit                               │  ← Reduce only not present → not shown
│  Size   100.000 ARB                  │
│  Price  $0.9800                      │
│  2h ago                              │
├──────────────────────────────────────┤
│  chart.bar.doc   list.bullet  clock  │
│    Positions       Orders      Fills │
└──────────────────────────────────────┘
```

#### Row field details

| Field | Display label | Layout | Notes |
|---|---|---|---|
| `coin` | none | Leading, `.headline` weight, same line as side chip | E.g. "BTC-USD" |
| `side` | none | Trailing chip on coin line | Buy = blue chip + `arrow.up`; Sell = orange chip + `arrow.down` |
| `orderType` | none | `.subheadline`, `.secondary` color, below coin line | "Limit", "Stop Limit", "Take Profit Limit", etc. Raw string from API, title-cased if needed |
| `sz` | "Size" | Label + value, `.body` | Remaining size with 4 decimal places |
| `limitPx` | "Price" | Label + value, `.body` | Always present; formatted as currency |
| `triggerPx` | "Trigger" | Label + value, `.body` | Only rendered when `triggerPx` is present in the response |
| `reduceOnly` | "Reduce only" | `.caption`, `.secondary`, no icon | Only rendered when `reduceOnly == true`; absent otherwise — do not show "Reduce only: No" |
| Age from `timestamp` | none | `.caption`, `.tertiary` | Relative time at bottom of row — see timestamp section |

**Side chip styling (identical to Positions long/short chips):**
- Buy: `Color.blue.opacity(0.12)` background, `.blue` foreground text and icon, `arrow.up` SF Symbol, label "Buy", `RoundedRectangle(cornerRadius: 6)`
- Sell: `Color.orange.opacity(0.12)` background, `.orange` foreground, `arrow.down`, label "Sell"
- VoiceOver: "Buy order" / "Sell order"

The chip colors deliberately reuse the Positions long/short chip palette (blue/orange). A buy order and a long position share the same directional meaning; visual consistency across screens helps users build a mental model faster.

---

### 5c. Success — no open orders (empty state)

```
┌──────────────────────────────────────┐
│  0x3f5C…833D         open-hl         │
├──────────────────────────────────────┤
│                                      │
│                                      │
│                                      │
│       No open orders                 │  ← title3, secondary label, centered
│                                      │
│       Pull down to refresh.          │  ← subheadline, tertiary, centered
│                                      │
│                                      │
│                                      │
├──────────────────────────────────────┤
│  chart.bar.doc   list.bullet  clock  │
│    Positions       Orders      Fills │
└──────────────────────────────────────┘
```

Notes:
- "No open orders" is factual and calm. No "You have no orders" (unnecessary "you"), no "Place an order on Hyperliquid!" (marketing, out of scope for read-only app).
- "Pull down to refresh." is functional — the user may have just cancelled an order and wants to confirm.
- No icon or illustration. Consistent with the Positions empty state which also uses text-only.
- Pull-to-refresh works in the empty state. The `List` (or `ScrollView`) must allow pull-to-refresh even with no rows.

---

### 5d. Error states

Error states reuse the exact same vocabulary, SF Symbols, titles, messages, and "Try again" button as the Positions screen. No new error chrome is invented.

The mapping from `ViewErrorState` to (symbol, title, message) is identical to `PositionsView.errorContent(_:)`. The `ios-developer` should extract this into a shared view component (e.g. `ErrorStateView`) rather than duplicating the switch statement. That component takes a `ViewErrorState` and renders the appropriate full-page error.

Inline error banner on failed pull-to-refresh also reuses the orange banner with `exclamationmark.triangle` from Positions. Same `errorBanner(errorState:)` pattern — extract to a shared component.

**Summary of error symbols (for reference — do not invent new ones):**

| Error | SF Symbol | Title |
|---|---|---|
| `.offline` | `wifi.slash` | "No internet connection" |
| `.timeout` | `clock.badge.exclamationmark` | "Request timed out" |
| `.serverError(code)` | `exclamationmark.circle` | "Hyperliquid is unavailable" |
| `.badRequest` | `exclamationmark.circle` | "Request rejected" |
| `.unexpectedResponse` | `xmark.circle` | "Could not read orders" |
| `.unknown` | `exclamationmark.triangle` | "Could not load orders" |

For `.unexpectedResponse`, include the GitHub issues link as on Positions.

---

### 5e. Pull-to-refresh (data already loaded)

Same behavior as Positions: existing data stays visible at `.opacity(0.6)` during refresh. System refresh control appears at the top. On success, the list updates and rows re-sort. On failure, an inline orange banner appears above the list. Haptics: `.success` on completion, `.error` on failure.

---

## 6. Timestamps

**Decision: relative time ("3m ago") on the row. Absolute time in VoiceOver accessibility label.**

Relative time rules:
- Under 60 seconds: "just now"
- 1–59 minutes: "Xm ago" (e.g. "3m ago")
- 1–23 hours: "Xh ago" (e.g. "2h ago")
- 1+ days: "Xd ago" (e.g. "1d ago")
- Over 30 days: display as short date ("Apr 12") — open orders this old are unusual but possible

The relative time is computed from the order `timestamp` (milliseconds since epoch) against the device's current time at the moment of render. It does not auto-update while the list is on screen in Phase 2 (no timer-driven refresh; it is stale until the next pull-to-refresh anyway).

**VoiceOver label for timestamp:** The combined row accessibility label (see Section 8) includes the absolute time as a formatted string: "placed [day] at [time]" — e.g. "placed today at 2:15 PM" or "placed Tuesday at 9:42 AM". This gives VoiceOver users the precise timestamp that sighted users can tap to reveal (see open question #1 about a tap-to-expand detail).

Timezone: device local timezone. The `timestamp` from the API is UTC epoch ms; convert with `Date(timeIntervalSince1970: Double(timestamp) / 1000)` and format with `Date.FormatStyle` respecting `.current` timezone.

---

## 7. Dynamic Type reflow (AX3+)

At default and Large text sizes, the compact layout applies (coin + chip on one line, fields below).

At `dynamicTypeSize >= .accessibility3`, switch to full-vertical layout — same pattern as `PositionRowView`:

```
BTC-USD
Buy  ▲
────────────
Order type
Limit
────────────
Size
0.1000 BTC
────────────
Price
$60,000.00
────────────
Placed
3m ago
```

- Labels expand to full words ("Order type" not abbreviated, "Placed" for the age)
- `Reduce only` badge becomes a line: "Reduce only: yes"
- `Trigger` shows as labeled field: "Trigger price / $3,050.00"

Use `@Environment(\.dynamicTypeSize)` to branch. Share the branching logic with Positions via the same `isAccessibilitySize` pattern already in `PositionRowView`.

---

## 8. iPhone SE and Pro Max

| Element | SE (375pt) | Pro Max (430pt) |
|---|---|---|
| Coin + chip on one line | "BTC-USD" (7) + chip (~60pt) — fits comfortably | Fine |
| Order type below coin | Full width, no constraint | Fine |
| Size line | "Size" label (40pt) + value — fits | Fine |
| Long order type strings | "Take Profit Limit" — 19 chars at body = ~200pt; fits | Fine |
| AX5 layout | Fully vertical, all wrap correctly, row height grows | Slightly more breathing room |

No special SE-only adjustments needed beyond what Positions already does. The row is simpler than a position row (no PnL, no liquidation price), so it is less likely to overflow.

---

## 9. Accessibility

### VoiceOver per row

Each row is `.accessibilityElement(children: .ignore)` with a single computed `.accessibilityLabel` that reads all fields naturally:

Format:
`"[coin] [side] order, [orderType], size [sz] [coin], price [limitPx][, trigger [triggerPx]][, reduce only][, placed [absolute time]]"`

Example:
`"BTC-USD buy order, Limit, size 0.1 BTC, price 60,000 dollars, placed today at 2:15 PM"`

`"ETH-USD sell order, Stop Limit, size 1 ETH, price 3,100 dollars, trigger 3,050 dollars, reduce only, placed today at 2:06 PM"`

Notes:
- Do not read "3m ago" — read the absolute time in the VoiceOver label. The relative time is a visual shorthand; VoiceOver users hear the precise time.
- "reduce only" is spoken at the end only when true; omit entirely when false.
- Currency amounts: use `NumberFormatter` with `.currency` style for VoiceOver labels (same pattern as Positions `accessibilityAmount`).

### Section header

The "OPEN ORDERS (X)" section header uses `.accessibilityAddTraits(.isHeader)` so VoiceOver users can jump to it with the Headings rotor.

### Reduce Motion

No animations unique to this screen. The list update on refresh can use `.animation(reduceMotion ? nil : .default, value: ...)` consistent with Positions.

### Contrast

Side chips (blue/orange) use `.opacity(0.12)` backgrounds — same as Positions. These pass contrast at default Increase Contrast settings because the foreground text color is `.blue` / `.orange` (system semantic colors) on a near-white/near-black tinted background. Verify in Accessibility Inspector under Increase Contrast mode.

---

## 10. SwiftUI implementation hints

- `OrdersView` backed by `OrdersViewModel` (`@MainActor @Observable final class`), same pattern as `PositionsViewModel`.
- `OrdersViewModel.State` enum mirrors `PositionsViewModel.State`:
  ```swift
  enum State: Sendable, Equatable {
      case idle
      case loading
      case loaded([OpenOrder])
      case error(ViewErrorState, lastLoaded: [OpenOrder]?)
  }
  ```
- `OpenOrder` is a domain model in `HyperliquidAPI` — a struct with `Sendable` conformance. Fields: `coin: String`, `side: Side`, `orderType: String`, `size: Decimal`, `limitPrice: Decimal`, `triggerPrice: Decimal?`, `isReduceOnly: Bool`, `placedAt: Date`, `orderId: String`.
- List rendering: `List` with `.listStyle(.insetGrouped)`. Single `Section` with the "OPEN ORDERS (X)" header. `ForEach(orders, id: \.orderId)` for rows.
- Pull-to-refresh: `.refreshable { await viewModel.refresh() }` with the same haptic pattern as Positions.
- Data fetch on first appear: `.task { await viewModel.load() }`.
- Relative time formatting: a shared helper in `OpenHLCore` — `RelativeTimeFormatter.string(from: Date) -> String` — so Fills can reuse the same logic. Do not implement this inline in the view.
- Sort: the view model sorts orders by `placedAt` descending before exposing them in `state`. The view does not sort.
- `ErrorStateView` and `ErrorBannerView`: extract these from `PositionsView` into shared components in the app target (e.g. `OpenHL/Components/`). Both `OrdersView` and `FillsView` use them.

---

## 11. Open questions

1. **Tap to expand / order detail.** The spec does not include a detail screen for individual orders. The full ISO timestamp (and fields like `oid`, `origSz`, and filled amount) would naturally live there. Is a detail screen in scope for Phase 2 or deferred? If deferred, the row should have no disclosure indicator and no tappable affordance (consistent with Phase 1 Positions rows). If in scope, the `NavigationLink` goes into the OrdersView `NavigationStack`.

2. **Side encoding.** The API documents `side` as "B" or "A" (bid/ask) in some response formats and "buy"/"sell" in others. Confirm with swift-expert which encoding `openOrders` uses, so the DTO mapper translates to the domain `Side` enum correctly.

3. **Order type string normalization.** `orderType` arrives as a raw string ("Limit", "Stop Market", "Take Profit Limit", etc.). Should the app pass it through as-is, or normalize to title case? And should unknown order types fall back to the raw string or show "Order"? Decision needed before implementing the mapper.

4. **Partially filled orders.** If `sz < origSz`, the order is partially filled. The spec surfaces only `sz` (remaining). Confirm with PM whether this is acceptable for v1 or whether a "X of Y filled" annotation is required.

5. **Shared error view component.** The spec recommends extracting `ErrorStateView` and `ErrorBannerView` from `PositionsView`. Confirm with `ios-developer` whether this refactor happens as part of Phase 2 or whether code duplication is acceptable in Phase 2 and extraction deferred to Phase 4 polish.

6. **Cancelling orders.** The roadmap explicitly excludes order cancellation from Phase 2. Confirm no swipe-to-cancel affordance should appear on rows (no trailing swipe action, no edit mode). Rows must not hint at mutability.
