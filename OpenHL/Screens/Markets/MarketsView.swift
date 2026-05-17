// SPDX-License-Identifier: MIT

import HyperliquidAPI
import OpenHLCore
import SwiftUI

/// Markets tab — the new app home. Shows every Hyperliquid perpetual
/// with current mark price and 24h change. Real Hyperliquid data, no
/// address required.
///
/// State machine + error handling come from `SnapshotViewModel`; this
/// view handles re-sectioning into PINNED / MARKETS based on
/// `favoritesStore`. The VM's postProcess still sorts by volume; the
/// view groups into sections at render time without touching the VM.
struct MarketsView: View {
    @State var viewModel: MarketsViewModel
    let client: any HyperliquidClient
    let favoritesStore: any FavoriteCoinsStore
    let clock: any Clock
    var liveStore: LiveStore? = nil
    var onOpenSettings: (() -> Void)? = nil

    @State private var searchText: String = ""
    /// Mirrors `favoritesStore.all()` so SwiftUI re-renders on every toggle.
    @State private var favorites: Set<String> = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Markets")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $searchText, prompt: "Search coins")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onOpenSettings?()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .refreshable {
                    await viewModel.refresh()
                }
                .task {
                    // Load market data concurrently with subscribing to
                    // favorites changes. Both are tied to view lifetime.
                    await viewModel.load()
                }
                .task {
                    // Subscribe to favorites changes for the lifetime of
                    // this view. `didChange` emits the current set
                    // immediately, so we don't need a separate read-once.
                    for await updated in favoritesStore.didChange {
                        favorites = updated
                    }
                }
                .task {
                    // Subscribe to live allMids updates. The stream's
                    // latest-wins buffering (bufferingNewest(1)) means
                    // slow iteration never accumulates a backlog; we
                    // always see the freshest mid snapshot.
                    guard let store = liveStore else { return }
                    let midsStream = await store.mids()
                    for await mids in midsStream {
                        viewModel.applyMids(mids)
                    }
                }
                .onChange(of: viewModel.state) { _, newState in
                    // Foreground alert evaluation: run after every
                    // successful markets fetch. No account value here —
                    // the Wallet tab passes it when it has a loaded
                    // ClearinghouseState.
                    if case .loaded(let markets) = newState {
                        AlertScheduler.shared.evaluate(
                            markets: markets,
                            accountValue: nil,
                            now: clock.now()
                        )
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle,
            .loading where viewModel.lastLoaded == nil:
            ProgressView("Loading markets…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            loadedList(filtered(viewModel.lastLoaded ?? []), banner: nil)

        case .loaded(let markets):
            loadedList(filtered(markets), banner: nil)

        case .error(let errorState, let prior):
            if let prior {
                loadedList(filtered(prior), banner: errorState)
            } else {
                ErrorStateView(errorState: errorState) {
                    await viewModel.retry()
                }
            }
        }
    }

    // MARK: - List with optional PINNED section

    @ViewBuilder
    private func loadedList(_ markets: [Market], banner: ViewErrorState?) -> some View {
        // Partition after search filter is applied so a pinned coin shows
        // under PINNED even when the search query matches it.
        let pinned = markets.filter { favorites.contains($0.coin) }
            .sorted { $0.coin < $1.coin }
        let rest = markets.filter { !favorites.contains($0.coin) }

        List {
            // Stale/reconnecting indicator at the very top of the list.
            if liveStore?.connectionState == .stale {
                Section {
                    HStack {
                        Spacer()
                        StaleIndicatorView()
                        Spacer()
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if let banner {
                Section {
                    ErrorBannerView(errorState: banner) {
                        await viewModel.retry()
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if markets.isEmpty {
                emptyState
            } else {
                // PINNED section — only when at least one favorite is visible.
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { market in
                            marketRow(for: market)
                        }
                    } header: {
                        Text("PINNED")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARKETS section — always present when there are markets.
                if !rest.isEmpty {
                    Section {
                        ForEach(rest) { market in
                            marketRow(for: market)
                        }
                    } header: {
                        Text("MARKETS")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func marketRow(for market: Market) -> some View {
        NavigationLink {
            CoinDetailView(
                viewModel: CoinDetailViewModel(
                    market: market,
                    client: client,
                    clock: clock
                ),
                favoritesStore: favoritesStore,
                liveStore: liveStore
            )
        } label: {
            MarketRowView(
                market: market,
                isFollowed: favorites.contains(market.coin),
                onToggleFollow: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        favoritesStore.toggle(market.coin)
                    }
                }
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No markets match \"\(searchText)\"")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Try a different symbol.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    // MARK: - Search filter

    private func filtered(_ markets: [Market]) -> [Market] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return markets }
        return markets.filter { $0.coin.localizedCaseInsensitiveContains(query) }
    }
}

#if DEBUG
    #Preview {
        MarketsView(
            viewModel: .markets(client: PreviewHyperliquidClient()),
            client: PreviewHyperliquidClient(),
            favoritesStore: InMemoryFavoriteCoinsStore(),
            clock: SystemClock()
        )
    }
#endif
