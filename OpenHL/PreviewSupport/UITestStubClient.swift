// SPDX-License-Identifier: MIT

#if DEBUG
    import Foundation
    import HyperliquidAPI
    import OpenHLCore

    /// A deterministic `HyperliquidClient` injected when the app is launched
    /// with the `OPENHL_UI_TEST_STUB` environment variable set. Bypasses the
    /// network entirely so UI tests can assert against known values without
    /// a live API connection.
    ///
    /// Supported `stubKey` values:
    ///
    /// - `"clearinghouseState_single_long"`: Returns one open BTC long position
    ///   with known numbers that UI tests can assert against (BTC row visible,
    ///   positive PnL, account summary populated).
    ///
    /// - `"error_offline"`: Throws `HyperliquidError.offline` immediately, so
    ///   UI tests can verify that the offline error state is rendered.
    ///
    /// Any unrecognized `stubKey` falls back to `clearinghouseState_single_long`
    /// so tests that forget to update the key still get a usable state.
    struct UITestStubClient: HyperliquidClient, Sendable {
        let stubKey: String
        let clock: any Clock

        func clearinghouseState(for user: Address) async throws -> ClearinghouseState {
            switch stubKey {
            case "error_offline":
                throw HyperliquidError.offline

            case "clearinghouseState_single_long", _:
                return makeSingleLong()
            }
        }

        // MARK: - Fixture data

        private func makeSingleLong() -> ClearinghouseState {
            ClearinghouseState(
                summary: ClearinghouseState.AccountSummary(
                    accountValue: Decimal(string: "12500.50")!,
                    totalNotionalPosition: Decimal(string: "10000.00")!,
                    totalRawUSD: Decimal(string: "12500.50")!,
                    totalMarginUsed: Decimal(string: "1000.00")!,
                    withdrawable: Decimal(string: "11500.50")!
                ),
                positions: [
                    ClearinghouseState.Position(
                        coin: "BTC",
                        size: Decimal(string: "0.25")!,
                        side: .long,
                        entryPrice: Decimal(string: "38000.00")!,
                        positionValue: Decimal(string: "10000.00")!,
                        unrealizedPnL: Decimal(string: "500.00")!,
                        returnOnEquity: Decimal(string: "0.05")!,
                        liquidationPrice: Decimal(string: "30000.00")!,
                        marginUsed: Decimal(string: "1000.00")!,
                        leverage: .cross(10)
                    ),
                    ClearinghouseState.Position(
                        coin: "ETH",
                        size: Decimal(string: "-5.0")!,
                        side: .short,
                        entryPrice: Decimal(string: "2000.00")!,
                        positionValue: Decimal(string: "10000.00")!,
                        unrealizedPnL: Decimal(string: "-250.00")!,
                        returnOnEquity: Decimal(string: "-0.025")!,
                        liquidationPrice: Decimal(string: "2200.00")!,
                        marginUsed: Decimal(string: "1000.00")!,
                        leverage: .isolated(10)
                    ),
                ],
                serverTime: Date(timeIntervalSince1970: 1_715_774_400),
                fetchedAt: clock.now()
            )
        }
    }
#endif
