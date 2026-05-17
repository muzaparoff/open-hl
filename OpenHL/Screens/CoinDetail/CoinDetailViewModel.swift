// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OpenHLCore

/// `CoinDetail` doesn't slot cleanly into `SnapshotViewModel<[Candle]>`
/// because the *fetch parameters* (interval, time window) change at runtime —
/// the shared generic captures its closure once at init.
///
/// Instead we use the same state-machine shape (`.idle / .loading /
/// .loaded / .error`) but wrap a small VM that owns the current
/// `Mode` and reissues fetches when it changes. The shared
/// `SnapshotViewModel` would need either a "re-bind fetch" hook or
/// duplicate the state machine — adding either to satisfy this one
/// screen would be premature.
///
/// Phase 3c: introduces `Mode` so the screen can show both standard
/// intervals (1h / 1d / 1w / 1M / 1y) and a user-defined Custom date range.
/// See `docs/architecture.md` §23 for the rationale on the Mode shape and
/// the auto-clamp ladder for Custom mode.
@MainActor
@Observable
final class CoinDetailViewModel {

    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded([Candle])
        case error(ViewErrorState, lastLoaded: [Candle]?)
    }

    /// How the chart is parameterized at any moment.
    ///
    /// `.standardInterval` covers the segmented-picker entries — one of the
    /// `CandleInterval.userFacing` cases plus the labelled "1M" (30 days) and
    /// "1y" (365 days) entries which both reuse `.oneDay`. To distinguish
    /// the two `.oneDay`-backed entries (30d vs 365d), the picker label and
    /// lookback come from `Preset`, not from `CandleInterval` directly.
    ///
    /// `.customRange` carries an arbitrary `DateInterval` chosen by the user
    /// in the date-picker sheet. The interval is derived via
    /// `CandleInterval.bestFit(for:)`; the lookback is the interval's
    /// `start...end` exactly (no `defaultLookback` substitution).
    ///
    /// Why this shape vs. (a) `var interval: CandleInterval` + `var range: DateInterval?`
    /// or (b) two separate VMs:
    ///
    /// (a) Two stored properties allow ill-formed combinations — e.g. setting
    /// `range = X` but forgetting to flip `interval`. The view code has to
    /// treat one as authoritative or carry guard logic in every read site.
    /// An enum makes the two modes mutually exclusive at the type level and
    /// pattern-matchable in one switch — the compiler enforces both branches
    /// are handled (chart label, fetch params, picker selection).
    ///
    /// (b) Two view models would duplicate the entire State machine, the
    /// fetch path, the error mapping, and the `lastLoaded` plumbing for a
    /// screen that already exists. The screen also has to flip between modes
    /// without losing context (prior bars are stale on mode change anyway,
    /// so we'd lose them either way — but two VMs would also lose the
    /// `market`, `client`, `clock` plumbing and the picker selection state).
    /// The duplication-vs-conditional trade is decisively in favour of one VM.
    enum Mode: Sendable, Equatable, Hashable {
        case standardInterval(Preset)
        case customRange(DateInterval)

        /// Picker entries for the standard segmented control. Order matches
        /// the on-screen left-to-right order: 1h, 1d, 1w, 1M, 1y.
        enum Preset: String, Sendable, CaseIterable, Identifiable, Hashable {
            case oneHour
            case oneDay
            case oneWeek
            case oneMonth  // 30 days of .oneDay bars
            case oneYear  // 365 days of .oneDay bars

            var id: String { rawValue }

            /// The `CandleInterval` granularity Hyperliquid is queried at
            /// for this preset.
            var interval: CandleInterval {
                switch self {
                case .oneHour: return .oneHour
                case .oneDay: return .oneDay
                case .oneWeek: return .oneWeek
                case .oneMonth: return .oneDay
                case .oneYear: return .oneDay
                }
            }

            /// Lookback in seconds from "now" for this preset.
            /// 1M = 30 days of 1d-bars; 1y = 365 days of 1d-bars.
            /// Both stay under Hyperliquid's ~500-bar per-response cap.
            var lookback: TimeInterval {
                let day: TimeInterval = 60 * 60 * 24
                switch self {
                case .oneHour: return 7 * day  // 168 1h-bars
                case .oneDay: return 90 * day  // 90 1d-bars (legacy default)
                case .oneWeek: return 365 * day  // 52 1w-bars
                case .oneMonth: return 30 * day  // 30 1d-bars
                case .oneYear: return 365 * day  // 365 1d-bars
                }
            }

            /// Short label for the segmented picker.
            var label: String {
                switch self {
                case .oneHour: return "1h"
                case .oneDay: return "1D"
                case .oneWeek: return "1W"
                case .oneMonth: return "1M"
                case .oneYear: return "1y"
                }
            }
        }

        /// Granularity Hyperliquid is queried at for this mode.
        var interval: CandleInterval {
            switch self {
            case .standardInterval(let preset): return preset.interval
            case .customRange(let range): return CandleInterval.bestFit(for: range)
            }
        }
    }

    /// Validation rules for a custom date range. Pure check; UI binds to the
    /// thrown error to disable the Apply button or show inline feedback.
    enum CustomRangeError: Error, Sendable, Equatable {
        case endBeforeStart
        case endInFuture
        case spanTooLarge  // > maxCustomSpan
    }

    /// Maximum span the user can request in Custom mode. Three years.
    /// Rationale: at the bestFit ladder's coarsest `.oneWeek` granularity,
    /// 3 years = ~156 bars — comfortably under the 500-bar cap. Larger spans
    /// would force the bestFit ladder onto `.oneDay` (>500 bars; truncated)
    /// or coarser intervals we haven't validated against real data.
    static let maxCustomSpan: TimeInterval = 60 * 60 * 24 * 365 * 3

    private(set) var state: State = .idle

    /// The currently-selected mode. View binds the picker to this; setting
    /// it triggers a refetch.
    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            Task { await self.reloadForMode() }
        }
    }

    /// The last custom `DateInterval` the user applied. Persisted so that
    /// re-tapping "Custom" reopens the sheet pre-filled with the prior range
    /// rather than resetting to the 7-day default. `nil` until the user
    /// applies a custom range for the first time on this screen instance.
    private(set) var lastCustomRange: DateInterval?

    /// Derived granularity for the current `mode`. Read-only — set `mode` to
    /// change it. Preserved as a property (rather than `mode.interval`) so
    /// existing view code (`viewModel.interval`) keeps compiling unchanged.
    var interval: CandleInterval { mode.interval }

    var market: Market
    private let client: any HyperliquidClient
    private let clock: any Clock

    init(
        market: Market,
        client: any HyperliquidClient,
        clock: any Clock,
        initialMode: Mode = .standardInterval(.oneHour)
    ) {
        self.market = market
        self.client = client
        self.clock = clock
        self.mode = initialMode
    }

    var lastLoaded: [Candle]? {
        switch state {
        case .loaded(let c): return c
        case .error(_, let c): return c
        default: return nil
        }
    }

    /// Validate a candidate custom range against the rules. Pure — does not
    /// mutate `mode`. Call before `setMode(.customRange(...))` so the picker
    /// sheet can surface errors inline without round-tripping through state.
    ///
    /// Takes raw `start` and `end` (rather than a `DateInterval`) because
    /// `DateInterval(start:end:)` traps on `end < start` — the picker sheet
    /// has two separately-bound `DatePicker`s and can hold a transiently
    /// invalid combination before the user fixes it. Validation must be
    /// reachable in that state.
    static func validate(start: Date, end: Date, now: Date) throws {
        guard end >= start else { throw CustomRangeError.endBeforeStart }
        guard end <= now else { throw CustomRangeError.endInFuture }
        guard end.timeIntervalSince(start) <= maxCustomSpan else {
            throw CustomRangeError.spanTooLarge
        }
    }

    /// Apply a new mode. Equivalent to assigning `mode` directly; provided as
    /// a method for symmetry with `load()` / `refresh()` and so call sites
    /// read as "user picked X" rather than "property mutated."
    /// For `.customRange`, callers should `validate(customRange:now:)` first.
    /// Automatically stores the range in `lastCustomRange` when the mode is
    /// `.customRange` so the sheet can pre-fill on next open.
    /// Apply a live `AssetContext` update to the header market snapshot.
    /// Called by the view's `.task` that subscribes to
    /// `liveStore.activeAssetCtx(coin:)`.
    func applyAssetCtx(_ ctx: AssetContext) {
        market = Market(
            coin: market.coin,
            maxLeverage: market.maxLeverage,
            szDecimals: market.szDecimals,
            onlyIsolated: market.onlyIsolated,
            markPrice: ctx.markPx,
            midPrice: ctx.midPx,
            prevDayPrice: ctx.prevDayPx,
            openInterest: ctx.openInterest,
            dayNotionalVolume: ctx.dayNotionalVolume,
            fundingRate: ctx.funding
        )
    }

    /// Apply a live mid-price update to the header. Called when the
    /// Markets list receives `allMids` and the user happens to be on
    /// Coin Detail — keeps the header in sync without waiting for
    /// `activeAssetCtx`.
    func applyMid(_ mid: Decimal) {
        market = Market(
            coin: market.coin,
            maxLeverage: market.maxLeverage,
            szDecimals: market.szDecimals,
            onlyIsolated: market.onlyIsolated,
            markPrice: mid,
            midPrice: mid,
            prevDayPrice: market.prevDayPrice,
            openInterest: market.openInterest,
            dayNotionalVolume: market.dayNotionalVolume,
            fundingRate: market.fundingRate
        )
    }

    /// Replace the last (current open) candle bar with a live tick.
    /// Called by the view's candle subscription. If `state` is `.loaded`
    /// and the bar shares its `openTime` with the last bar, it replaces
    /// it; otherwise it is appended as a new bar.
    func applyLiveCandle(_ live: Candle) {
        guard case .loaded(var candles) = state, !candles.isEmpty else { return }
        if let last = candles.last, last.openTime == live.openTime {
            candles[candles.count - 1] = live
        } else {
            candles.append(live)
        }
        state = .loaded(candles)
    }

    func setMode(_ newMode: Mode) {
        if case .customRange(let range) = newMode {
            lastCustomRange = range
        }
        mode = newMode
    }

    func load() async {
        guard case .idle = state else { return }
        state = .loading
        await fetch(preservingPrior: nil)
    }

    func refresh() async {
        await fetch(preservingPrior: lastLoaded)
    }

    func retry() async {
        let prior = lastLoaded
        if prior == nil { state = .loading }
        await fetch(preservingPrior: prior)
    }

    private func reloadForMode() async {
        // Switching modes replaces the dataset entirely. Don't preserve
        // prior bars — they're at the wrong granularity or window and would
        // look broken alongside new ones.
        state = .loading
        await fetch(preservingPrior: nil)
    }

    private func fetch(preservingPrior prior: [Candle]?) async {
        let (start, end): (Date, Date)
        switch mode {
        case .standardInterval(let preset):
            let now = clock.now()
            start = now.addingTimeInterval(-preset.lookback)
            end = now
        case .customRange(let range):
            // Custom mode uses the user's exact window — no `defaultLookback`
            // substitution. `end` may be in the past; that's expected.
            start = range.start
            end = range.end
        }
        do {
            let bars = try await client.candles(
                coin: market.coin,
                interval: interval,
                startTime: start,
                endTime: end
            )
            guard !Task.isCancelled else { return }
            state = .loaded(bars)
        } catch is CancellationError {
            // Cancelled — leave state alone.
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(ViewErrorState(any: error), lastLoaded: prior)
        }
    }
}
