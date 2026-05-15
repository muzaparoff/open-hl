// SPDX-License-Identifier: MIT

import HyperliquidAPI
import OpenHLCore
import SwiftUI

@main
struct OpenHLApp: App {
    private let clock: any Clock
    private let client: any HyperliquidClient
    private let addressStore: any AddressStore

    init() {
        self.clock = SystemClock()

        #if DEBUG
            // UI-test stub injection. When OPENHL_UI_TEST_STUB is set, swap
            // the production URLSession client for a deterministic in-memory
            // client and pre-seed the address store so the positions screen is
            // shown immediately without a network call.
            //
            // Supported values:
            //   "clearinghouseState_single_long"  – one BTC long, sensible numbers
            //   "error_offline"                   – always throws HyperliquidError.offline
            let stubKey = ProcessInfo.processInfo.environment["OPENHL_UI_TEST_STUB"] ?? ""
            if !stubKey.isEmpty {
                let memStore = InMemoryAddressStore(
                    initial: try? Address("0xabcdef1234567890abcdef1234567890abcdef12")
                )
                self.addressStore = memStore
                self.client = UITestStubClient(stubKey: stubKey, clock: clock)
                return
            }
        #endif

        self.client = URLSessionHyperliquidClient(clock: clock)
        self.addressStore = UserDefaultsAddressStore()
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                client: client,
                addressStore: addressStore,
                clock: clock
            )
        }
    }
}

/// Root view: checks for a saved address and routes to either the
/// address entry screen or the positions screen.
struct RootView: View {
    let client: any HyperliquidClient
    let addressStore: any AddressStore
    let clock: any Clock

    @State private var route: AppRoute

    enum AppRoute {
        case addressEntry
        case positions(Address, ClearinghouseState?)
    }

    init(
        client: any HyperliquidClient,
        addressStore: any AddressStore,
        clock: any Clock
    ) {
        self.client = client
        self.addressStore = addressStore
        self.clock = clock
        // Check for a saved address on startup
        if let saved = addressStore.load() {
            _route = State(initialValue: .positions(saved, nil))
        } else {
            _route = State(initialValue: .addressEntry)
        }
    }

    var body: some View {
        NavigationStack {
            switch route {
            case .addressEntry:
                AddressEntryView(
                    viewModel: AddressEntryViewModel(
                        client: client,
                        addressStore: addressStore,
                        clock: clock
                    ),
                    onSuccess: { state in
                        guard let address = addressStore.load() else { return }
                        route = .positions(address, state)
                    }
                )

            case .positions(let address, _):
                PositionsView(
                    viewModel: PositionsViewModel(
                        client: client,
                        address: address,
                        clock: clock
                    ),
                    onAddressChanged: { state in
                        guard let newAddress = addressStore.load() else { return }
                        route = .positions(newAddress, state)
                    },
                    client: client,
                    addressStore: addressStore,
                    clock: clock
                )
            }
        }
    }
}
