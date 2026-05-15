# Design spec: recent fills screen (Phase 2)

**Feature:** `fills`
**Phase:** 2
**Owner:** uxui-designer
**Last updated:** 2026-05-15

---

## 1. Goal

Show the user's most recent trade executions — what filled, at what price, and what it cost in fees — in a scroll-capped list that loads quickly and tells the story of recent activity.

---

## 2. User scenario

The user switches to the Fills tab. They placed a limit order earlier; it executed. They want to confirm the fill price, see the fee, and check whether the position it opened or closed is reflected correctly. They may also scan back several fills to understand recent activity. The list should be readable without tapping into any detail screen.

---

## 3. API fields surfaced vs. deferred

The `userFills` response includes per fill: `coin`, `side`, `px` (fill price), `sz` (fill size), `fee`, `feeToken`, `time` (ms), `tid` (trade id), `oid` (order id), `closedPnl`, `dir` (direction string — "Open Long", "Close Short", etc.), `crossed`, `hash`.

**Surfaced in the row:**
- `dir` — the primary descriptor. More meaningful than raw `side` for fills because it communicates what the fill did to the position ("Open Long" vs. just "Buy"). Rendered prominently.
- `coin` — asset identifier
- `sz` — fill size
- `px` — fill price
- `fee` + `feeToken` — combined: "0.42 USDC"
- `closedPnl` — signed decimal; shown with PnL color convention. Only meaningful when `dir` starts with "Close"; shown for all fills (zero for opens) for consistency.
- Age derived from `time` — relative on row, absolute in VoiceOver label

**Deferred (not shown in v1 row):**
- `tid` / `oid` / `hash` — internal identifiers, no user-facing value in v1
- `crossed` — boolean for whether the order crossed the spread (taker vs. maker). Useful context for fee analysis but adds row complexity. Deferred.
- `side` (raw) — superseded by `dir` which is more descriptive

**Design decision on `closedPnl` for open fills:** The API will return `closedPnl = "0"` or `"0.0"` for fills that open a new position. Show `$0.00` with no color/arrow (zero convention, consistent with Positions). This is honest — there is no closed PnL on an opening fill. Do not hide the field for opens; showing it consistently avoids the user wondering "where is the PnL?"

---

## 4. Pagination / scroll cap strategy

**Decision: scroll cap at 100 fills with a "Showing 100 most recent fills" footer note.**

The `userFills` API returns recent fills in one call. The response can be large (active traders may have hundreds of fills). Options considered:

- **Hard cap at N with note:** Simple. No pagination state, no "load more" button, no infinite scroll. Fast cold load. The vast majority of users checking "what just happened" need the last 10–20 fills, not 500.
- **Infinite scroll fetch-more:** Requires pagination state, a continuation cursor or offset, and a second API call on scroll. `userFills` does not currently document pagination parameters; adding this would require engineering investigation and additional networking complexity.
- **Unbounded list:** Loads all fills returned by the API. If the response is large, this is slow to decode and slow to render in `List`. No cap means no predictability.

**Chosen: cap at 100.** The view model takes at most the first 100 fills from the API response (sorted by time descending — most recent first). A section footer reads: "Showing up to 100 most recent fills." This is honest and sets expectations.

100 was chosen over 50 (too few for active traders) and 200 (unnecessarily heavy for a mobile view). Flag as open question if engineering finds the 100-fill payload is meaningfully slow to decode.

The roadmap says "paginated or scroll-capped (decision logged)." This is logged: scroll-capped at 100, no pagination, no search.

---

## 5. States and wireframes

### 5a. Loading — cold start

```
┌──────────────────────────────────────┐
│  0x3f5C…833D         open-hl         │
├──────────────────────────────────────┤
│                                      │
│                                      │
│                                      │
│            ◌                         │  ← ProgressView, centered
│            Fetching fills…           │  ← subheadline, secondary label
│                                      │
│                                      │
│                                      │
├──────────────────────────────────────┤
│  chart.bar.doc   list.bullet  clock  │
│    Positions       Orders      Fills │
└──────────────────────────────────────┘
```

Identical structure to Positions and Orders cold-start loading. VoiceOver: `.accessibilityLabel("Fetching recent fills")`.

---

### 5b. Success — fills present

```
┌──────────────────────────────────────┐
│  0x3f5C…833D         open-hl         │
├──────────────────────────────────────┤
│  RECENT FILLS  (12)                  │  ← section header, all caps, footnote
├─────────────────────────────────────┤
│  BTC-USD                  Open Long  │  ← coin (headline) + dir chip (trailing)
│  Size   0.1000 BTC                   │  ← body, secondary label
│  Price  $61,800.00                   │  ← fill price
│  Fee    0.42 USDC                    │  ← fee amount + token
│  Closed PnL  $0.00                   │  ← zero, no color, no arrow (open fill)
│  just now                            │  ← caption, tertiary
├─────────────────────────────────────┤
│  ETH-USD               Close Short   │  ← dir chip: orange bg, "Close Short"
│  Size   2.0000 ETH                   │
│  Price  $3,194.50                    │
│  Fee    1.28 USDC                    │
│  Closed PnL  +$31.00  ▲             │  ← positive: green + arrow.up
│  4m ago                              │
├─────────────────────────────────────┤
│  SOL-USD                 Open Short  │  ← dir chip: orange bg, "Open Short"
│  Size   10.000 SOL                   │
│  Price  $142.80                      │
│  Fee    0.07 USDC                    │
│  Closed PnL  $0.00                   │
│  1h ago                              │
├─────────────────────────────────────┤
│  BTC-USD               Close Long    │  ← dir chip: blue bg, "Close Long"
│  Size   0.0500 BTC                   │
│  Price  $62,100.00                   │
│  Fee    0.16 USDC                    │
│  Closed PnL  –$150.00  ▼            │  ← negative: red + arrow.down
│  3h ago                              │
├─────────────────────────────────────┤
│  ─────────────────────────────────  │
│  Showing up to 100 most recent      │  ← caption, tertiary, centered
│  fills. Pull down to refresh.       │
└──────────────────────────────────────┘
```

#### Row field details

| Field | Display label | Layout | Notes |
|---|---|---|---|
| `coin` | none | Leading, `.headline`, same line as dir chip | E.g. "BTC-USD" |
| `dir` | none | Trailing chip on coin line | Direction chip — see chip spec below |
| `sz` | "Size" | Label + value, `.body`, secondary label | 4 decimal places |
| `px` | "Price" | Label + value, `.body` | Fill execution price, formatted as currency |
| `fee` + `feeToken` | "Fee" | Label + value, `.body` | Concatenated: "0.42 USDC". No separate currency symbol for non-USD fees. |
| `closedPnl` | "Closed PnL" | Label + signed value, `.body` | PnL color/arrow convention — see below. Always shown. |
| Age from `time` | none | `.caption`, `.tertiary` | Relative time at bottom of row |

**Direction chip styling:**

The `dir` field is the chip label. Chip background and foreground colors follow the directionality of the fill, not a simple buy/sell binary:

| `dir` value | Meaning | Chip color |
|---|---|---|
| "Open Long" | Bought to open | Blue (same as Long/Buy chip in Positions/Orders) |
| "Close Short" | Bought to close | Blue (closing a short = buying, net bullish action) |
| "Open Short" | Sold to open | Orange (same as Short/Sell chip) |
| "Close Long" | Sold to close | Orange (closing a long = selling) |
| Other / unknown | Fall back | Secondary (gray tint) |

Rationale: grouping "buy-side" fills as blue and "sell-side" fills as orange is consistent with Positions (long=blue, short=orange) and Orders (buy=blue, sell=orange). The `dir` string is used as the chip label verbatim — it is already human-readable and more specific than "Buy"/"Sell".

Chip shape: identical to Positions and Orders chips — `RoundedRectangle(cornerRadius: 6)`, `.opacity(0.12)` background, matching foreground text and no SF Symbol (direction is already encoded in the text; adding an arrow to a "Close Short" label would be ambiguous).

**Closed PnL color and shape (identical to Positions PnL convention):**
- Positive: `.green` text + `arrow.up` (small, `.imageScale(.small)`) trailing
- Negative: `.red` text + `arrow.down` trailing
- Zero: `.primary` text, no arrow
- When Increase Contrast is enabled: the arrow is the sole indicator; text uses `.foregroundStyle(.green)` / `.foregroundStyle(.red)` which adapt automatically to system semantic colors.

---

### 5c. Success — no fills (empty state)

```
┌──────────────────────────────────────┐
│  0x3f5C…833D         open-hl         │
├──────────────────────────────────────┤
│                                      │
│                                      │
│                                      │
│       No recent fills                │  ← title3, secondary, centered
│                                      │
│       Pull down to refresh.          │  ← subheadline, tertiary, centered
│                                      │
│                                      │
│                                      │
├──────────────────────────────────────┤
│  chart.bar.doc   list.bullet  clock  │
└──────────────────────────────────────┘
```

"No recent fills" is factual. "No recent activity" was considered but "fills" is the correct domain term and what the user expects from the tab label. No icon, consistent with Positions and Orders empty states.

---

### 5d. Error states

Identical vocabulary to Positions and Orders. Same `ErrorStateView` shared component, same `ErrorBannerView` for inline pull-to-refresh failures. Same symbol/title/message mapping. No new error chrome.

Title override for the `.unexpectedResponse` case: "Could not read fills" (not "Could not read account data"). The symbol and GitHub link stay the same.

---

### 5e. Pull-to-refresh

Same as Positions and Orders: existing data stays visible at `.opacity(0.6)`, system refresh control appears, haptics on completion. On success: list updates, rows re-sort, footer still shows "up to 100 most recent." On failure: inline orange banner.

---

## 6. Timestamps

Same rules as Orders:

- "just now" for under 60 seconds
- "Xm ago" for 1–59 minutes
- "Xh ago" for 1–23 hours
- "Xd ago" for 1+ days
- Short date for over 30 days

VoiceOver accessibility label uses absolute time ("filled today at 2:15 PM") not the relative string.

Computed from `time` (epoch ms) against device local time at render. Uses the same `RelativeTimeFormatter` shared helper in `OpenHLCore` as Orders.

---

## 7. Dynamic Type reflow (AX3+)

At `dynamicTypeSize >= .accessibility3`, switch to full-vertical layout:

```
BTC-USD
Open Long
────────────
Size
0.1000 BTC
────────────
Fill price
$61,800.00
────────────
Fee
0.42 USDC
────────────
Closed PnL
$0.00
────────────
Filled
just now
```

- Labels expand to full words: "Fill price" (not "Price"), "Filled" (not the bare relative time)
- The `dir` chip becomes a labeled line below the coin name (not on the same line)
- PnL arrow sits next to the value on its own line

---

## 8. iPhone SE and Pro Max

| Element | SE (375pt) | Pro Max (430pt) |
|---|---|---|
| Coin + dir chip | "BTC-USD" + "Close Short" chip (~90pt) — fits; "Close Short" is the longest common `dir` string | Fine |
| Fee line | "Fee  0.42 USDC" — short, no overflow | Fine |
| Closed PnL line | "Closed PnL  +$31.00  ▲" — fits at body size | Fine |
| AX5 | All fields wrap to two-column vertical layout; row height grows; List auto-sizes | Slightly more breathing room |

No SE-specific layout overrides needed. Rows are comparable in density to Orders rows.

---

## 9. Accessibility

### VoiceOver per row

Each row is `.accessibilityElement(children: .ignore)` with a single computed `.accessibilityLabel`.

Format:
`"[coin], [dir], size [sz], fill price [px], fee [fee] [feeToken], closed PnL [signed closedPnl][, arrow up/down], [absolute time]"`

Example (open fill, zero PnL):
`"BTC-USD, open long, size 0.1 BTC, fill price 61,800 dollars, fee 0.42 USDC, closed PnL zero dollars, filled just now"`

Example (close fill with PnL):
`"ETH-USD, close short, size 2 ETH, fill price 3,194 dollars and 50 cents, fee 1.28 USDC, closed PnL plus 31 dollars, filled 4 minutes ago"`

Notes:
- "arrow up/down" is not spoken separately — the signed value and direction (plus/minus) carry the meaning.
- `closedPnl` is formatted with `MoneyFormatter.signedUSD` for VoiceOver, same as Positions.
- Absolute time is used, not relative: "filled 4 minutes ago" reads better than "4m ago" for spoken text, and more precisely than "just now."

### Section header

"RECENT FILLS (X)" section header: `.accessibilityAddTraits(.isHeader)` so Headings rotor lets VoiceOver users jump to it.

### Footer note

"Showing up to 100 most recent fills. Pull down to refresh." Footer is a static `Text` at the bottom of the list section. VoiceOver reads it as a standard label; no special traits needed.

### Reduce Motion

No animations unique to Fills. Same `.animation(reduceMotion ? nil : .default, ...)` pattern as Positions.

### Contrast

Direction chips follow the same color/opacity rules as Positions and Orders chips. `closedPnl` uses `.green`/`.red` semantic colors that adapt to Increase Contrast. The arrow (`arrow.up`/`arrow.down`) is the shape indicator for colorblind users.

---

## 10. SwiftUI implementation hints

- `FillsView` backed by `FillsViewModel` (`@MainActor @Observable final class`).
- `FillsViewModel.State`:
  ```swift
  enum State: Sendable, Equatable {
      case idle
      case loading
      case loaded([Fill])
      case error(ViewErrorState, lastLoaded: [Fill]?)
  }
  ```
- `Fill` domain model in `HyperliquidAPI`: `coin: String`, `direction: String`, `size: Decimal`, `fillPrice: Decimal`, `fee: Decimal`, `feeToken: String`, `closedPnl: Decimal`, `filledAt: Date`, `tradeId: String`.
- The view model caps at 100 and sorts by `filledAt` descending before exposing via `state`:
  ```swift
  let capped = fills.sorted { $0.filledAt > $1.filledAt }.prefix(100)
  state = .loaded(Array(capped))
  ```
- `ForEach(fills, id: \.tradeId)` for rows. `tradeId` (`tid`) is stable per fill and unique.
- Footer: a `Section` footer `Text` on the fills section, shown only when the fills list is non-empty. When `fills.count == 100` the footer reads "Showing 100 most recent fills. Pull down to refresh." When `fills.count < 100`, the footer reads "Showing \(fills.count) fills. Pull down to refresh." — honest about what is displayed.
- `closedPnl` direction chip: a `directionChipColor(_ dir: String) -> Color` helper that pattern-matches on the `dir` string prefix ("Open" vs. "Close") and the side implied by the full string. This logic belongs in the view model or a formatting helper, not inline in the view.
- Shared components: reuse `ErrorStateView`, `ErrorBannerView`, and `RelativeTimeFormatter` from Orders (see orders.md). Do not duplicate.
- `List` with `.listStyle(.insetGrouped)`. Section with "RECENT FILLS (X)" header and a footer view for the cap note.

---

## 11. Open questions

1. **`closedPnl` for liquidation fills.** When a position is liquidated, a fill appears. Is `closedPnl` populated correctly for liquidation fills? Does `dir` contain a special string like "Liquidated Long"? Confirm with engineering so the direction chip and PnL display handle these correctly (or gracefully fall back to the gray chip).

2. **Fee token variety.** The `feeToken` field indicates which token was used for fees. On Hyperliquid it is typically "USDC" but may vary. The row renders `"\(fee) \(feeToken)"` verbatim. Confirm this is always a short human-readable string and cannot be a contract address or empty.

3. **`closedPnl` sign convention.** Confirm the API returns `closedPnl` as a signed string (positive = favorable, negative = unfavorable from the user's perspective) and not always positive with a separate direction. The display spec assumes signed decimal matching Positions' `unrealizedPnl` convention.

4. **Scroll cap tuning.** 100 is the proposed cap. If the `userFills` response for active traders is routinely 500+ entries, the decode + sort + prefix operation may be slow on older devices. Engineering to measure; if needed, the cap can drop to 50 with a corresponding footer note change.

5. **Direction chip fallback.** Unknown `dir` strings (API adds a new direction type) fall back to a gray tint chip showing the raw string. Confirm with engineering that the domain model passes the `dir` string through raw rather than failing decode on unknown values. The DTO mapper should not throw on an unrecognized direction.

6. **`userFills` response ordering.** Does the API return fills already sorted by time descending, or is the sort the app's responsibility? Confirm so the view model knows whether to sort or trust the response order. Even if the API sorts, the app should sort anyway to guarantee order after cap truncation.
