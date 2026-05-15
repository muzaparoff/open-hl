// SPDX-License-Identifier: MIT

import HyperliquidAPI
import OpenHLCore
import SwiftUI
import UIKit

/// The main account overview screen shown after a valid address is submitted.
struct PositionsView: View {
    @State var viewModel: PositionsViewModel

    /// Called when the user saves a new address from the settings/change sheet.
    var onAddressChanged: ((ClearinghouseState) -> Void)?

    // MARK: - Sheet state

    @State private var showSettings = false
    @State private var showChangeAddress = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Dependencies for change-address sheet

    let client: any HyperliquidClient
    let addressStore: any AddressStore
    let clock: any Clock

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                loadingView

            case .loading:
                loadingView

            case .loaded(let snapshot):
                loadedView(snapshot: snapshot, isRefreshing: false, errorState: nil)

            case .error(let errorState, let lastLoaded):
                if let lastLoaded {
                    // Refresh failure: keep showing data + inline error banner
                    loadedView(snapshot: lastLoaded, isRefreshing: false, errorState: errorState)
                } else {
                    // Cold-start failure: full-page error
                    fullPageErrorView(errorState: errorState)
                }
            }
        }
        .navigationTitle("open-hl")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("open-hl")
                    .font(.headline)
            }
            ToolbarItem(placement: .topBarLeading) {
                Text(viewModel.address.rawValue.truncated(maxLength: 12))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Wallet address \(viewModel.address.rawValue)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task {
            await viewModel.load()
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .sheet(isPresented: $showChangeAddress) {
            changeAddressSheet
        }
    }

    // MARK: - Loading view

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
            Text("Fetching account\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fetching account data")
    }

    // MARK: - Loaded view

    private func loadedView(
        snapshot: ClearinghouseState,
        isRefreshing: Bool,
        errorState: ViewErrorState?
    ) -> some View {
        List {
            // Inline error banner (refresh failure)
            if let errorState {
                Section {
                    errorBanner(errorState: errorState)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Account summary header
            Section {
                accountSummaryView(
                    summary: snapshot.summary,
                    positions: snapshot.positions,
                    fetchedAt: snapshot.fetchedAt
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // Positions section
            Section {
                if snapshot.positions.isEmpty {
                    emptyPositionsView
                } else {
                    ForEach(snapshot.positions) { position in
                        PositionRowView(position: position)
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                            .listRowInsets(
                                EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
                            )
                    }
                }
            } header: {
                if !snapshot.positions.isEmpty {
                    Text("OPEN POSITIONS (\(snapshot.positions.count))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            let generator = UINotificationFeedbackGenerator()
            await viewModel.refresh()
            if case .error = viewModel.state {
                generator.notificationOccurred(.error)
            } else {
                generator.notificationOccurred(.success)
            }
        }
        .animation(reduceMotion ? nil : .default, value: snapshot.fetchedAt)
        .opacity(isRefreshing ? 0.6 : 1.0)
    }

    // MARK: - Account summary

    private func accountSummaryView(
        summary: ClearinghouseState.AccountSummary,
        positions: [ClearinghouseState.Position],
        fetchedAt: Date
    ) -> some View {
        let totalUnrealizedPnL = positions.reduce(Decimal(0)) { $0 + $1.unrealizedPnL }

        return VStack(alignment: .leading, spacing: 0) {
            // Account value — large, prominent
            Text("Account value")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text(MoneyFormatter.usd(summary.accountValue))
                .font(.largeTitle)
                .fontWeight(.bold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .accessibilityLabel(accessibilityAmount(summary.accountValue, label: "Account value"))

            Divider()
                .padding(.vertical, 12)

            // PnL row
            summaryRow(
                label: "Unrealized PnL",
                value: totalUnrealizedPnL,
                isSigned: true
            )

            summaryRow(label: "Margin used", value: summary.totalMarginUsed, isSigned: false)
            summaryRow(label: "Available margin", value: summary.withdrawable, isSigned: false)

            // Timestamp
            HStack {
                Spacer()
                Text("Updated \(fetchedAt, format: .dateTime.hour().minute().second())")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(
                        "Last updated at \(fetchedAt, format: .dateTime.hour().minute(.twoDigits))"
                    )
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 4)
    }

    private func summaryRow(label: String, value: Decimal, isSigned: Bool) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if isSigned {
                signedPnLText(value)
                    .font(.subheadline)
                    .accessibilityLabel(accessibilitySignedAmount(value, label: label))
            } else {
                Text(MoneyFormatter.usd(value))
                    .font(.subheadline)
                    .accessibilityLabel(accessibilityAmount(value, label: label))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Error banner (inline, refresh failure)

    private func errorBanner(errorState: ViewErrorState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(errorBannerTitle(errorState))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Button("Try again") {
                    Task { await viewModel.retry() }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(errorBannerTitle(errorState))")
    }

    private func errorBannerTitle(_ state: ViewErrorState) -> String {
        switch state {
        case .offline: return "No internet connection."
        case .timeout: return "Request timed out."
        case .serverError(let code): return "Server error (HTTP \(code))."
        case .badRequest: return "Request rejected."
        case .unexpectedResponse: return "Unexpected API response."
        case .unknown: return "Could not refresh."
        }
    }

    // MARK: - Empty positions view

    private var emptyPositionsView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 32)
            Text("No open positions")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Pull down to refresh.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    // MARK: - Full-page error view

    private func fullPageErrorView(errorState: ViewErrorState) -> some View {
        let (symbol, title, message) = errorContent(errorState)
        return VStack(spacing: 20) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.bordered)

            if case .unexpectedResponse = errorState {
                Link(
                    "If this persists, please file an issue on GitHub.",
                    destination: URL(string: "https://github.com/open-hl/open-hl/issues")!
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func errorContent(_ state: ViewErrorState) -> (String, String, String) {
        switch state {
        case .offline:
            return (
                "wifi.slash",
                "No internet connection",
                "Connect and pull down to refresh."
            )
        case .timeout:
            return (
                "clock.badge.exclamationmark",
                "Request timed out",
                "Hyperliquid may be slow.\nPull down or tap to try again."
            )
        case .serverError(let code):
            return (
                "exclamationmark.circle",
                "Hyperliquid is unavailable",
                "The server returned an error (HTTP \(code)). Try again in a moment."
            )
        case .badRequest:
            return (
                "exclamationmark.circle",
                "Request rejected",
                "The server rejected the request. Try again."
            )
        case .unexpectedResponse:
            return (
                "xmark.circle",
                "Could not read account data",
                "The API returned a response the app did not recognize. This may be a temporary API change."
            )
        case .unknown:
            return (
                "exclamationmark.triangle",
                "Could not load account",
                "An unexpected error occurred. Check your connection and try again."
            )
        }
    }

    // MARK: - Settings sheet

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("WALLET ADDRESS") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.address.rawValue)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change address") {
                            showSettings = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                showChangeAddress = true
                            }
                        }
                        .accessibilityLabel("Change wallet address")
                    }
                    .padding(.vertical, 4)
                }

                Section("ABOUT") {
                    HStack {
                        Text("open-hl")
                        Spacer()
                        Text(
                            "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))"
                        )
                        .foregroundStyle(.secondary)
                    }

                    Link(
                        "MIT licensed, open source",
                        destination: URL(string: "https://github.com/open-hl/open-hl")!
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
    }

    // MARK: - Change address sheet

    private var changeAddressSheet: some View {
        NavigationStack {
            AddressEntryView(
                viewModel: AddressEntryViewModel(
                    client: client,
                    addressStore: addressStore,
                    clock: clock,
                    existingAddress: viewModel.address
                ),
                onSuccess: { newState in
                    showChangeAddress = false
                    onAddressChanged?(newState)
                },
                onCancel: { showChangeAddress = false }
            )
        }
    }

    // MARK: - Accessibility helpers

    private func accessibilityAmount(_ value: Decimal, label: String) -> String {
        // Format as "X dollars and Y cents" for VoiceOver
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = .current
        let formatted = formatter.string(from: value as NSDecimalNumber) ?? MoneyFormatter.usd(value)
        return "\(label), \(formatted)"
    }

    private func accessibilitySignedAmount(_ value: Decimal, label: String) -> String {
        let formatted = MoneyFormatter.signedUSD(value)
        return "\(label), \(formatted)"
    }

    // MARK: - PnL color helper

    @ViewBuilder
    private func signedPnLText(_ value: Decimal) -> some View {
        if value > 0 {
            HStack(spacing: 2) {
                Text(MoneyFormatter.signedUSD(value))
                    .foregroundStyle(.green)
                Image(systemName: "arrow.up")
                    .imageScale(.small)
                    .foregroundStyle(.green)
            }
        } else if value < 0 {
            HStack(spacing: 2) {
                Text(MoneyFormatter.signedUSD(value))
                    .foregroundStyle(.red)
                Image(systemName: "arrow.down")
                    .imageScale(.small)
                    .foregroundStyle(.red)
            }
        } else {
            Text(MoneyFormatter.usd(value))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Position row view

struct PositionRowView: View {
    let position: ClearinghouseState.Position
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isAccessibilitySize = dynamicTypeSize >= .accessibility3

        Group {
            if isAccessibilitySize {
                accessibilityLayout
            } else {
                compactLayout
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    // MARK: - Compact layout (default and Large text)

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Asset + side on same line
            HStack {
                Text(position.coin)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                sideChip
            }

            rowField(label: "Size", value: sizeFormatted)
            rowField(label: "Entry", value: MoneyFormatter.usd(position.entryPrice))
            rowField(label: "Mark", value: MoneyFormatter.usd(abs(position.positionValue / position.size)))
            pnlRow
            if let liq = position.liquidationPrice {
                rowField(label: "Liq.", value: MoneyFormatter.usd(liq))
            }
        }
    }

    // MARK: - Accessibility layout (AX3+)

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(position.coin)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            sideChip
            Divider()
            verticalField(label: "Size", value: sizeFormatted)
            Divider()
            verticalField(label: "Entry", value: MoneyFormatter.usd(position.entryPrice))
            Divider()
            verticalField(
                label: "Mark",
                value: MoneyFormatter.usd(abs(position.positionValue / position.size))
            )
            Divider()
            Text("Unrealized PnL")
                .font(.footnote)
                .foregroundStyle(.secondary)
            pnlRow
            if let liq = position.liquidationPrice {
                Divider()
                verticalField(label: "Liquidation price", value: MoneyFormatter.usd(liq))
            }
        }
    }

    // MARK: - Shared subviews

    private var sideChip: some View {
        HStack(spacing: 4) {
            Text(position.side == .long ? "Long" : "Short")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(position.side == .long ? .blue : .orange)
            Image(systemName: position.side == .long ? "arrow.up" : "arrow.down")
                .imageScale(.small)
                .foregroundStyle(position.side == .long ? .blue : .orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (position.side == .long ? Color.blue : Color.orange).opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(position.side == .long ? "Long position" : "Short position")
    }

    private func rowField(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.body)
        }
    }

    private func verticalField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
    }

    private var pnlRow: some View {
        HStack(spacing: 6) {
            pnlText(position.unrealizedPnL)
            Text(MoneyFormatter.signedPercent(position.returnOnEquity))
                .font(.body)
                .foregroundStyle(pnlColor)
            pnlArrow
        }
    }

    @ViewBuilder
    private func pnlText(_ value: Decimal) -> some View {
        Text(MoneyFormatter.signedUSD(value))
            .font(.body)
            .foregroundStyle(pnlColor)
    }

    private var pnlColor: Color {
        if position.unrealizedPnL > 0 { return .green }
        if position.unrealizedPnL < 0 { return .red }
        return .primary
    }

    @ViewBuilder
    private var pnlArrow: some View {
        if position.unrealizedPnL > 0 {
            Image(systemName: "arrow.up")
                .imageScale(.small)
                .foregroundStyle(.green)
        } else if position.unrealizedPnL < 0 {
            Image(systemName: "arrow.down")
                .imageScale(.small)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Formatting

    private var sizeFormatted: String {
        // Use 4 decimal places for position sizes in Phase 1
        MoneyFormatter.decimal(
            abs(position.size),
            minimumFractionDigits: 4,
            maximumFractionDigits: 4
        ) + " \(position.coin)"
    }

    // MARK: - Accessibility

    private var rowAccessibilityLabel: String {
        let side = position.side == .long ? "long" : "short"
        let size = MoneyFormatter.decimal(
            abs(position.size), minimumFractionDigits: 2, maximumFractionDigits: 4
        )
        let entry = MoneyFormatter.usd(position.entryPrice)
        let mark =
            position.size != 0
            ? MoneyFormatter.usd(abs(position.positionValue / position.size)) : "unknown"
        let pnl = MoneyFormatter.signedUSD(position.unrealizedPnL)
        let pct = MoneyFormatter.signedPercent(position.returnOnEquity)
        var label =
            "\(position.coin) \(side), size \(size) \(position.coin), entry \(entry), mark \(mark), unrealized PnL \(pnl), \(pct)"
        if let liq = position.liquidationPrice {
            label += ", liquidation price \(MoneyFormatter.usd(liq))"
        } else {
            label += ", no liquidation price"
        }
        return label
    }
}

// MARK: - String truncation helper

extension String {
    fileprivate func truncated(maxLength: Int) -> String {
        guard count > maxLength else { return self }
        let half = maxLength / 2 - 1
        return "\(prefix(half + 2))\u{2026}\(suffix(half))"
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PositionsView(
            viewModel: PositionsViewModel(
                client: PreviewHyperliquidClient(),
                address: Address(validating: "0x0000000000000000000000000000000000000001")!,
                clock: SystemClock()
            ),
            client: PreviewHyperliquidClient(),
            addressStore: InMemoryAddressStore(),
            clock: SystemClock()
        )
    }
}
