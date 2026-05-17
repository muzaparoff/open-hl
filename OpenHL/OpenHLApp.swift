// SPDX-License-Identifier: MIT

import HyperliquidAPI
import OpenHLCore
import SwiftUI

@main
struct OpenHLApp: App {
    private let clock: any Clock
    private let client: any HyperliquidClient
    private let addressStore: any AddressStore
    private let favoritesStore: any FavoriteCoinsStore
    private let backupToggle: any ICloudBackupToggle
    private let rulesStore: any AlertRulesStore
    /// Non-nil only in production. UI-test stubs use `nil` so iCloud is never touched.
    private let backedAddressStore: ICloudBackedAddressStore?
    private let backedFavoritesStore: ICloudBackedFavoriteCoinsStore?
    /// Live WebSocket store. `nil` in UI-test stub paths that must not touch the network.
    private let liveStore: LiveStore?

    init() {
        self.clock = SystemClock()

        #if DEBUG
            // UI-test stub injection. When OPENHL_UI_TEST_STUB is set, swap
            // the production URLSession client for a deterministic in-memory
            // client. If the stub key is one of the address-scoped variants,
            // we also pre-seed an in-memory address store so the Wallet tab
            // lands directly on data without manual entry.
            //
            // Supported values:
            //   "clearinghouseState_single_long"  – one BTC long, sensible numbers
            //   "openOrders_two_resting"          – two resting open orders
            //   "userFills_recent_three"          – three recent fills
            //   "tab_shell_stub"                  – populated data for all sections
            //   "error_offline"                   – every endpoint throws .offline
            //
            // Any unrecognized key falls back to "clearinghouseState_single_long".
            let stubKey = ProcessInfo.processInfo.environment["OPENHL_UI_TEST_STUB"] ?? ""
            if !stubKey.isEmpty {
                let memAddressStore = InMemoryAddressStore(
                    initial: try? Address("0xabcdef1234567890abcdef1234567890abcdef12")
                )
                let memClient = UITestStubClient(stubKey: stubKey, clock: clock)
                let memFavorites = InMemoryFavoriteCoinsStore()
                let memRules = InMemoryAlertRulesStore()
                self.addressStore = memAddressStore
                self.client = memClient
                self.favoritesStore = memFavorites
                self.rulesStore = memRules
                self.backupToggle = InMemoryICloudBackupToggle(initial: false)
                self.backedAddressStore = nil
                self.backedFavoritesStore = nil
                // Stub stream so UI tests see simulated live prices without
                // a real WebSocket connection.
                let stubStream = StubHyperliquidStream()
                self.liveStore = LiveStore(stream: stubStream, clock: clock)
                AlertScheduler.shared.configure(
                    rulesStore: memRules,
                    client: memClient,
                    addressStore: memAddressStore,
                    clock: clock
                )
                return
            }
        #endif

        self.client = URLSessionHyperliquidClient(clock: clock)

        #if DEBUG
            // UI-test seam: when OPENHL_UI_TEST_RESET=1, the test wants to
            // exercise the real address-entry flow against the real network.
            // Use an empty in-memory store so prior runs don't leak in.
            if ProcessInfo.processInfo.environment["OPENHL_UI_TEST_RESET"] == "1" {
                let resetAddressStore = InMemoryAddressStore()
                let resetRules = InMemoryAlertRulesStore()
                self.addressStore = resetAddressStore
                self.favoritesStore = InMemoryFavoriteCoinsStore()
                self.rulesStore = resetRules
                self.backupToggle = InMemoryICloudBackupToggle(initial: false)
                self.backedAddressStore = nil
                self.backedFavoritesStore = nil
                // Reset path still gets a live WebSocket (it exercises the
                // real address-entry flow against the real network).
                let wsStream = URLSessionHyperliquidStream()
                self.liveStore = LiveStore(stream: wsStream, clock: clock)
                AlertScheduler.shared.configure(
                    rulesStore: resetRules,
                    client: client,
                    addressStore: resetAddressStore,
                    clock: clock
                )
                return
            }
        #endif

        // Production composition: build the bare stores, then layer the
        // iCloud-backup decorators on top. The decorators dual-write to
        // KVS *only when the toggle is enabled*, and the toggle defaults
        // to OFF — so a user who never touches Settings sees identical
        // on-device behavior to the pre-Phase-3f build.
        //
        // The `SystemUbiquitousKeyValueStore` wrapper is always
        // constructed. If the iCloud Key-Value entitlement is missing
        // (or the user isn't signed into iCloud), the underlying
        // `NSUbiquitousKeyValueStore` silently no-ops; reads return
        // `nil`, writes are dropped. That degrades to "local-only"
        // without any composition-root branching, which keeps the
        // dependency graph the same shape on every build.
        let bareAddress = UserDefaultsAddressStore()
        let bareFavorites = UserDefaultsFavoriteCoinsStore()
        let toggle = UserDefaultsICloudBackupToggle()
        let kvs = SystemUbiquitousKeyValueStore()
        let backedAddr = ICloudBackedAddressStore(
            wrapping: bareAddress,
            kvs: kvs,
            toggle: toggle
        )
        let backedFavs = ICloudBackedFavoriteCoinsStore(
            wrapping: bareFavorites,
            kvs: kvs,
            toggle: toggle
        )
        self.backedAddressStore = backedAddr
        self.backedFavoritesStore = backedFavs
        self.addressStore = backedAddr
        self.favoritesStore = backedFavs
        self.backupToggle = toggle

        let rules = UserDefaultsAlertRulesStore()
        self.rulesStore = rules

        // Production WebSocket stream + live store. One instance; the
        // scene-phase observer in RootTabShell drives connect/disconnect.
        let wsStream = URLSessionHyperliquidStream()
        self.liveStore = LiveStore(stream: wsStream, clock: clock)

        // Wire AlertScheduler. BG task registration happens in body's
        // onAppear (via scene lifecycle) but configure must happen here so
        // the scheduler has its dependencies before any BG launch.
        AlertScheduler.shared.configure(
            rulesStore: rules,
            client: URLSessionHyperliquidClient(clock: clock),
            addressStore: backedAddr,
            clock: clock
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabShell(
                client: client,
                addressStore: addressStore,
                favoritesStore: favoritesStore,
                rulesStore: rulesStore,
                backupToggle: backupToggle,
                backedAddressStore: backedAddressStore,
                backedFavoritesStore: backedFavoritesStore,
                liveStore: liveStore,
                clock: clock
            )
            .onAppear {
                AlertScheduler.shared.registerBackgroundTask()
                AlertScheduler.shared.scheduleNextRefresh()
            }
        }
    }
}

// MARK: - Root tab shell (Phase 3a + Phase 3f Settings)

/// Two-tab home: **Markets** (always available, no address required) and
/// **Wallet** (optional, address-scoped, houses the existing Positions /
/// Orders / Fills behind a segmented control).
///
/// View models are owned here via `@State` so they survive tab switches
/// without re-fetching.
///
/// The Settings sheet (Phase 3f) is owned here — a single `@State` bool
/// opens it from either tab's gear icon. Both toolbar items bind to the
/// same `showSettings` flag, so the sheet is always the same instance
/// regardless of which tab triggered it.
struct RootTabShell: View {
    let client: any HyperliquidClient
    let addressStore: any AddressStore
    let favoritesStore: any FavoriteCoinsStore
    let rulesStore: any AlertRulesStore
    let backupToggle: any ICloudBackupToggle
    let backedAddressStore: ICloudBackedAddressStore?
    let backedFavoritesStore: ICloudBackedFavoriteCoinsStore?
    let liveStore: LiveStore?
    let clock: any Clock

    @State private var marketsVM: MarketsViewModel
    @State private var selectedTab: Tab = .markets
    @State private var showSettings = false

    @Environment(\.scenePhase) private var scenePhase

    enum Tab {
        case markets, wallet
    }

    init(
        client: any HyperliquidClient,
        addressStore: any AddressStore,
        favoritesStore: any FavoriteCoinsStore,
        rulesStore: any AlertRulesStore,
        backupToggle: any ICloudBackupToggle,
        backedAddressStore: ICloudBackedAddressStore?,
        backedFavoritesStore: ICloudBackedFavoriteCoinsStore?,
        liveStore: LiveStore?,
        clock: any Clock
    ) {
        self.client = client
        self.addressStore = addressStore
        self.favoritesStore = favoritesStore
        self.rulesStore = rulesStore
        self.backupToggle = backupToggle
        self.backedAddressStore = backedAddressStore
        self.backedFavoritesStore = backedFavoritesStore
        self.liveStore = liveStore
        self.clock = clock
        _marketsVM = State(initialValue: .markets(client: client))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            MarketsView(
                viewModel: marketsVM,
                client: client,
                favoritesStore: favoritesStore,
                clock: clock,
                liveStore: liveStore,
                onOpenSettings: { showSettings = true }
            )
            .tabItem {
                Label("Markets", systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(Tab.markets)
            .accessibilityLabel("Markets tab")

            WalletView(
                client: client,
                addressStore: addressStore,
                clock: clock,
                liveStore: liveStore,
                onOpenSettings: { showSettings = true }
            )

            .tabItem {
                Label("Wallet", systemImage: "wallet.pass")
            }
            .tag(Tab.wallet)
            .accessibilityLabel("Wallet tab")
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                liveStore?.sceneDidActivate()
            case .background:
                liveStore?.sceneDidBackground()
            default:
                break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                viewModel: SettingsViewModel(
                    toggle: backupToggle,
                    addressStore: addressStore,
                    favoritesStore: favoritesStore,
                    backedAddressStore: backedAddressStore,
                    backedFavoritesStore: backedFavoritesStore
                ),
                rulesStore: rulesStore,
                clock: clock
            )
            .presentationDetents([.large])
        }
    }
}
