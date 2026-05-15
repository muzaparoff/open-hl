# Design spec: navigation shell (Phase 2)

**Feature:** `navigation`
**Phase:** 2
**Owner:** uxui-designer
**Last updated:** 2026-05-15

---

## 1. Goal

Wire Positions, Orders, and Fills into a single coherent navigation shell without breaking the Phase 1 address-entry root logic.

---

## 2. User scenario

The user has a saved address. They launch the app and land on Positions. They want to check whether an order they placed earlier is still resting, then look at their last few fills to see what executed. They expect to switch between these views in one or two taps and return to where they were.

---

## 3. IA decision: tab bar

**Decision: tab bar with three tabs (Positions, Orders, Fills).**

Tab bar wins over a segmented control for four concrete reasons:

1. **Each tab has independent state.** Orders may be loading while Positions is already populated. A segmented control hosted inside one screen means one view model owns all three fetch states, which inflates complexity and makes it harder for pull-to-refresh to be scoped correctly. Tab bar lets each screen own its view model and network task independently.
2. **Fills will scroll.** A scroll-capped list of fills underneath a segmented control fights with the outer scroll view (the summary header). Tab bar gives fills an unobstructed full-height scroll area.
3. **VoiceOver and keyboard navigation.** `TabView` gives the tab bar its own accessibility role out of the box. Each tab item gets a label, badge (future use), and keyboard focus order for free. A segmented control inside a `List` has to be manually managed.
4. **iOS convention.** Three peer destinations with no hierarchy between them is the canonical tab bar use case per Apple HIG. A segmented control is for filtering or mode-switching within a single dataset.

Segmented control was rejected because it implies the three views share data or context. They do not: they are independent API calls with independent empty/error states.

A hybrid ("side-by-side" or "page view") was rejected: the data types are categorically different, not views into the same dataset, so a paged layout would feel arbitrary.

---

## 4. Navigation hierarchy

```
Address not saved?
        │
        ▼
AddressEntryView (root, full-screen, no tab bar)
        │
        │  address saved (or just entered)
        ▼
TabView (root when address is saved)
  ├── Tab 1: Positions
  │     NavigationStack
  │       PositionsView
  │         └─ sheet: SettingsView
  │               └─ sheet: AddressEntryView (change address, modal)
  │
  ├── Tab 2: Orders
  │     NavigationStack
  │       OrdersView
  │
  └── Tab 3: Fills
        NavigationStack
          FillsView
```

Key rules:
- `TabView` is the root only when an address is stored. Before an address is saved, `TabView` does not exist in the view hierarchy. `RootView` in `OpenHLApp.swift` conditionally switches between `AddressEntryView` and `TabView`.
- Each tab wraps its screen in its own `NavigationStack`. This is the correct SwiftUI pattern for tab-based apps on iOS 16+: each tab owns an independent navigation stack so state is preserved when the user switches tabs.
- The settings affordance (`⚙`) stays on the Positions tab only — it does not appear on Orders or Fills. Rationale: settings contains only "change address," which is a global action most naturally reached from the primary account view. Adding the gear to all three tabs creates redundancy; hiding it entirely from Orders/Fills is fine because the user learns it lives on Positions.
- No nav bar "back" from Positions to AddressEntry. Address entry is conditionally shown as root — it is not in any navigation stack.

---

## 5. Tab bar items

```
┌──────────────────────────────────────┐
│                                      │
│   [tab content]                      │
│                                      │
├──────────────────────────────────────┤
│  chart.bar.doc.horizontal  list.bullet  clock.arrow.circlepath  │
│      Positions                Orders              Fills          │
└──────────────────────────────────────┘
```

| Tab | SF Symbol | Label | VoiceOver label |
|---|---|---|---|
| Positions | `chart.bar.doc.horizontal` | "Positions" | "Positions tab" |
| Orders | `list.bullet` | "Orders" | "Orders tab" |
| Fills | `clock.arrow.circlepath` | "Fills" | "Fills tab" |

Symbol notes:
- `chart.bar.doc.horizontal` is used for "Positions" rather than a generic person or wallet icon because it suggests account overview with data, consistent with Hyperliquid's own visual language.
- `list.bullet` for Orders is direct and unambiguous.
- `clock.arrow.circlepath` for Fills suggests recent history / executed events. Alternative: `arrow.left.arrow.right.circle` but it reads as "transfer" more than "history."
- All three are in the SF Symbols 5 set (iOS 17+).
- No filled vs. outline state management needed — SwiftUI's `TabView` handles selected/unselected state automatically with system coloring.

---

## 6. No-saved-address behavior

**Decision: the address-entry screen pre-empts the tab bar entirely.**

When no address is saved, `RootView` shows `AddressEntryView` full-screen. The tab bar does not render. The user cannot see stub/empty tabs before entering an address.

Rationale: showing three empty or "enter an address first" tabs would require placeholder states for all three screens simultaneously and confuses the onboarding flow. The address entry is already designed as a gate — honoring that gate at the navigation root is the simplest and most honest approach.

On iOS, `RootView` switching from `AddressEntryView` to `TabView` after a successful address save uses a simple `.animation(.default)` cross-dissolve via a state change in the composition root. No navigation push — it is a conditional root swap.

```swift
// Pseudocode in RootView
if addressStore.savedAddress == nil {
    AddressEntryView(...)
} else {
    TabView { ... }
}
```

---

## 7. State preservation across tab switches

**Decision: keep in-memory state; do not re-fetch on every tab switch.**

Each tab's view model is owned by the tab's root view via `@State`. The view model is created once when the tab's view first appears and lives as long as the tab bar is on screen.

Behavior:
- Switching from Positions to Orders does not trigger a Positions re-fetch.
- Returning to a tab that has already loaded shows the existing data. The "Updated HH:mm:ss" timestamp tells the user when the data was last fetched.
- The user can pull-to-refresh on any tab to explicitly re-fetch that tab's data.
- On cold app launch, each tab fetches its own data via `.task` when it first appears. Positions loads first (it is the default selected tab). Orders and Fills load when the user first switches to them.

This is the correct behavior for v1:
- No background refresh polling means stale data is expected. The timestamp makes staleness transparent.
- Fetching on every tab switch would burn network and drain battery, especially when the user switches tabs frequently to cross-reference positions with orders.
- In Phase 3 (live updates via WebSocket), the architecture can push updates to all three view models without requiring tab-switch re-fetches.

---

## 8. SwiftUI implementation hints

- `RootView` holds `@State private var savedAddress: Address?` initialized from `addressStore.load()`. On `AddressEntryView` success callback, set `savedAddress`. The switch from entry to tab view animates automatically via `.animation(.default, value: savedAddress != nil)`.
- `TabView(selection:)` with an `@State private var selectedTab: Tab = .positions` enum. Prefer a typed selection over an integer tag for clarity.
- Each `NavigationStack` inside a tab is independently managed. Tabs do not share navigation state.
- View model lifetime: each tab's view model is `@State var viewModel: OrdersViewModel` etc., initialized in the view's `init` with injected dependencies. The tab view does not use `@StateObject` (that is `ObservableObject`-era). `@State` with `@Observable` is the correct pattern per `architecture.md`.
- `TabView` in SwiftUI instantiates all tab views on first appearance of the tab bar, but `.task` modifiers only fire when the view appears on screen. Each tab's `.task` fires the first time that tab is selected.

---

## 9. VoiceOver and keyboard navigation

VoiceOver navigation order within the tab bar:
1. Tab bar items are announced as "Positions tab, 1 of 3", "Orders tab, 2 of 3", "Fills tab, 3 of 3" — `TabView` provides this automatically.
2. Within each tab, focus starts at the first element of that tab's content (nav bar title, then leading toolbar item, then list content).
3. The settings gear on the Positions tab is accessible via VoiceOver as "Settings, button."

External keyboard (iPad or Stage Manager — out of scope for v1, but the pattern should not break):
- Tab switching via external keyboard is handled by iOS system behavior for `TabView`. No custom key handlers needed.

Focus order within each tab follows the logical top-to-bottom, leading-to-trailing reading order enforced by the `List`/`NavigationStack` hierarchy.

---

## 10. Open questions

1. **Composition root refactor.** `OpenHLApp.swift` currently constructs one `PositionsViewModel` and hands it to `RootView`. In Phase 2, `RootView` becomes `TabView` and needs to create view models for all three tabs. Confirm with swift-expert whether all three view models are constructed eagerly in `OpenHLApp.swift` (simple, but wastes memory if Orders/Fills are never visited) or lazily inside each tab view via `@State`. The lazy `@State` approach is preferred; flag if there is a dependency-injection concern.

2. **Tab bar badge for order count.** A badge showing the number of open orders on the Orders tab would be useful. This requires either: (a) a shared observable store that all tabs read from, or (b) the Orders view model exposing its count to the tab bar. Both require a design change beyond Phase 2's scope. Log as post-Phase-2 enhancement.

3. **Settings affordance placement.** This spec keeps `⚙` on Positions only. If user research shows users cannot find it, consider moving it to a global toolbar item or a dedicated tab. PM decision.

4. **RootView animation on address save.** The cross-dissolve from AddressEntryView to TabView should feel instant relative to the network call (the tab bar appears after the fetch succeeds). Confirm that the animation does not visually compete with the Positions loading spinner that appears immediately on the first tab.
