// SPDX-License-Identifier: MIT

import Charts
import HyperliquidAPI
import OpenHLCore
import SwiftUI

/// Coin detail screen: header price + 24h change, interval picker,
/// native Swift Charts candlestick, stats row. Real Hyperliquid data
/// from `candleSnapshot`.
///
/// Phase 4: when `liveStore` is provided, subscribes to `activeAssetCtx`
/// (live mark/funding/OI tick) and `candle` (live current-bar update) for
/// the displayed coin. Subscriptions are scoped to view lifetime via `.task`.
struct CoinDetailView: View {
    @State var viewModel: CoinDetailViewModel
    /// Optional favorites store. When provided, a star button appears in
    /// the toolbar so the user can pin/unpin the coin from the Markets list
    /// without navigating back. `nil` only in standalone previews that are
    /// not embedded in the Markets navigation stack.
    var favoritesStore: (any FavoriteCoinsStore)?
    /// Optional live store. When provided, the header price and stats row
    /// update in real time from `activeAssetCtx`; the last candle bar is
    /// patched in place from the `candle` channel.
    var liveStore: LiveStore? = nil

    // Sheet presentation
    @State private var showingCustomSheet = false
    // Track the last active non-custom mode so Cancel can revert to it.
    @State private var lastStandardMode: CoinDetailViewModel.Mode = .standardInterval(.oneHour)
    /// Mirrors store state so the toolbar star re-renders on toggle.
    @State private var isFavorite: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Stale indicator sits above the price header when the
                // connection is stale so the user knows prices may lag.
                if liveStore?.connectionState == .stale {
                    HStack {
                        Spacer()
                        StaleIndicatorView()
                        Spacer()
                    }
                    .padding(.horizontal)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
                header
                intervalChipPicker
                chartSection
                statsRow
            }
            .padding(.vertical)
        }
        .navigationTitle(viewModel.market.coin)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let store = favoritesStore {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            store.toggle(viewModel.market.coin)
                        }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? .yellow : .secondary)
                    }
                    .accessibilityLabel(
                        isFavorite
                            ? "Unpin \(viewModel.market.coin) from Markets"
                            : "Pin \(viewModel.market.coin) to Markets"
                    )
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .task(id: viewModel.market.coin) {
            // Subscribe to favorites changes for this coin. Tied to view
            // lifetime; restarts if the coin identity ever changes.
            guard let store = favoritesStore else { return }
            for await updated in store.didChange {
                isFavorite = updated.contains(viewModel.market.coin)
            }
        }
        .task(id: viewModel.market.coin) {
            // Subscribe to activeAssetCtx for live header stats.
            guard let store = liveStore else { return }
            let coin = viewModel.market.coin
            let ctxStream = await store.activeAssetCtx(coin: coin)
            for await ctx in ctxStream {
                viewModel.applyAssetCtx(ctx)
            }
        }
        .task(id: "\(viewModel.market.coin):\(viewModel.interval.rawValue)") {
            // Subscribe to the live candle for the current coin+interval.
            // Restarts on interval change so we always track the right bar.
            guard let store = liveStore else { return }
            let coin = viewModel.market.coin
            let interval = viewModel.interval
            let candleStream = await store.candle(coin: coin, interval: interval)
            for await live in candleStream {
                viewModel.applyLiveCandle(live)
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $showingCustomSheet) {
            CoinDetailCustomRangeSheet(
                initial: viewModel.lastCustomRange,
                now: Date.now,
                onApply: { range in
                    viewModel.setMode(.customRange(range))
                },
                onCancel: {
                    // Revert to the last standard mode only if we haven't
                    // already committed a custom range.
                    if case .customRange = viewModel.mode {
                        // A prior custom range is active — keep it.
                    } else {
                        viewModel.setMode(lastStandardMode)
                    }
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.market.coin)
                .font(.largeTitle)
                .fontWeight(.bold)
            Text(MoneyFormatter.usd(viewModel.market.markPrice))
                .font(.title2)
                .monospacedDigit()
            HStack(spacing: 6) {
                Image(systemName: viewModel.market.dayChangeRatio >= 0 ? "arrow.up" : "arrow.down")
                    .font(.caption)
                Text(MoneyFormatter.signedUSD(viewModel.market.dayChange))
                    .monospacedDigit()
                Text(MoneyFormatter.signedPercent(viewModel.market.dayChangeRatio))
                    .monospacedDigit()
                Text("24h")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(viewModel.market.dayChangeRatio >= 0 ? Color.green : Color.red)
        }
        .padding(.horizontal)
    }

    // MARK: - Interval chip picker

    private var intervalChipPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Standard preset chips
                    ForEach(CoinDetailViewModel.Mode.Preset.allCases) { preset in
                        let chipMode = CoinDetailViewModel.Mode.standardInterval(preset)
                        IntervalChip(
                            label: preset.label,
                            isSelected: viewModel.mode == chipMode,
                            accessibilityLabel: preset.accessibilityLabel
                        )
                        .id(chipMode)
                        .onTapGesture {
                            lastStandardMode = chipMode
                            viewModel.setMode(chipMode)
                        }
                    }

                    // Custom chip
                    let customLabel = customChipLabel
                    let isCustomSelected: Bool = {
                        if case .customRange = viewModel.mode { return true }
                        return false
                    }()
                    IntervalChip(
                        label: customLabel,
                        isSelected: isCustomSelected,
                        accessibilityLabel: customChipAccessibilityLabel
                    )
                    .id("custom")
                    .onTapGesture {
                        showingCustomSheet = true
                    }
                }
                .padding(.horizontal)
            }
            // Scroll the selected chip into view whenever the mode changes.
            .onChange(of: viewModel.mode) { _, newMode in
                withAnimation {
                    switch newMode {
                    case .standardInterval:
                        proxy.scrollTo(newMode, anchor: .center)
                    case .customRange:
                        proxy.scrollTo("custom", anchor: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Custom chip label

    /// Compressed range label for the Custom chip when a custom range is active.
    /// Format: same year → `MMM d → MMM d`; cross-year → `MMM d, yyyy → MMM d, yyyy`.
    private var customChipLabel: String {
        guard case .customRange(let range) = viewModel.mode else {
            return "Custom"
        }
        return compressedRangeLabel(range)
    }

    private var customChipAccessibilityLabel: String {
        guard case .customRange(let range) = viewModel.mode else {
            return "Custom date range, not set"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "Custom date range, \(f.string(from: range.start)) to \(f.string(from: range.end))"
    }

    /// Produces "May 1 → Jun 14" (same year) or "Dec 1, 2025 → Jan 5, 2026" (cross-year).
    private func compressedRangeLabel(_ range: DateInterval) -> String {
        let cal = Calendar.current
        let startYear = cal.component(.year, from: range.start)
        let endYear = cal.component(.year, from: range.end)
        if startYear == endYear {
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return "\(f.string(from: range.start)) \u{2192} \(f.string(from: range.end))"
        } else {
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return "\(f.string(from: range.start)) \u{2192} \(f.string(from: range.end))"
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        switch viewModel.state {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 280)

        case .loading where viewModel.lastLoaded == nil:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 280)

        case .loading:
            // Loading after interval change with stale data — show a faded chart.
            candleChart(viewModel.lastLoaded ?? [])
                .opacity(0.5)
                .overlay(ProgressView())
                .frame(height: 280)
                .padding(.horizontal)

        case .loaded(let candles):
            if candles.isEmpty {
                emptyDataState
                    .frame(minHeight: 280)
            } else {
                candleChart(candles)
                    .frame(height: 280)
                    .padding(.horizontal)
            }

        case .error(let errorState, let prior):
            if let prior, !prior.isEmpty {
                VStack(spacing: 8) {
                    candleChart(prior)
                        .frame(height: 280)
                    ErrorBannerView(errorState: errorState) {
                        await viewModel.retry()
                    }
                }
                .padding(.horizontal)
            } else {
                ErrorStateView(errorState: errorState) {
                    await viewModel.retry()
                }
                .frame(minHeight: 280)
            }
        }
    }

    // MARK: - Empty data state

    /// Shown when the API returns zero candles for the selected window.
    /// Uses `calendar.badge.exclamationmark` (date-related, not network-error
    /// vocabulary) per the design spec.
    @ViewBuilder
    private var emptyDataState: some View {
        let (startLabel, endLabel) = emptyStateLabels
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No data for this period")
                .font(.title3)
                .multilineTextAlignment(.center)
            VStack(spacing: 4) {
                Text(
                    "\(viewModel.market.coin) may not have traded during \(startLabel) \u{2192} \(endLabel)."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                Text("Try a different range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "No chart data for the selected period. \(viewModel.market.coin) may not have traded during \(startLabel) to \(endLabel). Try a different range."
        )
    }

    private var emptyStateLabels: (String, String) {
        let f = DateFormatter()
        switch viewModel.mode {
        case .standardInterval(let preset):
            f.dateFormat = "MMM d"
            let now = Date.now
            let start = now.addingTimeInterval(-preset.lookback)
            return (f.string(from: start), f.string(from: now))
        case .customRange(let range):
            let cal = Calendar.current
            let startYear = cal.component(.year, from: range.start)
            let endYear = cal.component(.year, from: range.end)
            if startYear == endYear {
                f.dateFormat = "MMM d"
            } else {
                f.dateFormat = "MMM d, yyyy"
            }
            return (f.string(from: range.start), f.string(from: range.end))
        }
    }

    // MARK: - Candle chart

    private func candleChart(_ candles: [Candle]) -> some View {
        Chart {
            ForEach(candles) { candle in
                RuleMark(
                    x: .value("Time", candle.openTime),
                    yStart: .value("Low", candle.low.asDouble),
                    yEnd: .value("High", candle.high.asDouble)
                )
                .foregroundStyle(candle.isUp ? .green : .red)

                RectangleMark(
                    x: .value("Time", candle.openTime),
                    yStart: .value("Open", candle.open.asDouble),
                    yEnd: .value("Close", candle.close.asDouble),
                    width: .fixed(6)
                )
                .foregroundStyle(candle.isUp ? .green : .red)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                if let date = value.as(Date.self) {
                    AxisValueLabel(xAxisFormat(date: date))
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
    }

    /// Returns the x-axis date label for `date`, adjusted to the current
    /// interval and the effective window width.
    ///
    /// For custom ranges the window can be wide enough that `.oneDay` bars
    /// should show month+year rather than month+day. Likewise `.oneWeek` bars
    /// on a year+ window are shown as `MMM yyyy`.
    private func xAxisFormat(date: Date) -> String {
        let f = DateFormatter()
        let windowDays = effectiveWindowDays
        switch viewModel.interval {
        case .oneHour:
            f.dateFormat = "HH:mm"
        case .fourHour:
            // Reachable via Custom mode's bestFit ladder (2–30 day spans).
            f.dateFormat = windowDays > 7 ? "MMM d" : "HH:mm"
        case .oneDay:
            // 1M preset = ~30 days, 1y preset = ~365 days, and custom.
            f.dateFormat = windowDays > 90 ? "MMM yyyy" : "MMM d"
        case .oneWeek:
            f.dateFormat = "MMM yyyy"
        default:
            f.dateFormat = "MMM d"
        }
        return f.string(from: date)
    }

    /// Approximate window width in days for the current mode.
    private var effectiveWindowDays: Double {
        switch viewModel.mode {
        case .standardInterval(let preset):
            return preset.lookback / (60 * 60 * 24)
        case .customRange(let range):
            return range.duration / (60 * 60 * 24)
        }
    }

    // MARK: - Stats row

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            statRow(
                label: "Open interest",
                value: MoneyFormatter.decimal(
                    viewModel.market.openInterest,
                    minimumFractionDigits: 0,
                    maximumFractionDigits: 2
                )
            )
            statRow(
                label: "24h volume",
                value: MoneyFormatter.usd(viewModel.market.dayNotionalVolume)
            )
            statRow(
                label: "Funding rate",
                value: MoneyFormatter.signedPercent(viewModel.market.fundingRate)
            )
            statRow(
                label: "Max leverage",
                value: "\(viewModel.market.maxLeverage)\u{00D7}"
            )
        }
        .padding(.horizontal)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - IntervalChip

/// A single selectable chip in the horizontal interval picker row.
private struct IntervalChip: View {
    let label: String
    let isSelected: Bool
    let accessibilityLabel: String

    var body: some View {
        Text(label)
            .font(.body)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : Color(uiColor: .secondarySystemGroupedBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isSelected ? "selected" : "")
    }
}

// MARK: - Preset accessibility labels

extension CoinDetailViewModel.Mode.Preset {
    fileprivate var accessibilityLabel: String {
        switch self {
        case .oneHour: return "1 hour interval"
        case .oneDay: return "1 day interval"
        case .oneWeek: return "1 week interval"
        case .oneMonth: return "1 month interval"
        case .oneYear: return "1 year interval"
        }
    }
}

// MARK: - Decimal → Double for chart Y-values

// SwiftUI Charts wants `Double` (not `Decimal`) for plottable values.
// Conversion is lossy at extreme precision but the chart only needs
// visual approximation; all display values still use `MoneyFormatter`.
extension Decimal {
    fileprivate var asDouble: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

// MARK: - Preview

#if DEBUG
    #Preview {
        NavigationStack {
            CoinDetailView(
                viewModel: CoinDetailViewModel(
                    market: Market(
                        coin: "BTC",
                        maxLeverage: 50,
                        szDecimals: 3,
                        onlyIsolated: false,
                        markPrice: Decimal(string: "62401.50")!,
                        midPrice: Decimal(string: "62401.50")!,
                        prevDayPrice: Decimal(string: "61641.00")!,
                        openInterest: Decimal(string: "1234.5")!,
                        dayNotionalVolume: Decimal(string: "830000000")!,
                        fundingRate: Decimal(string: "0.0001")!
                    ),
                    client: PreviewHyperliquidClient(),
                    clock: SystemClock()
                )
            )
        }
    }
#endif
