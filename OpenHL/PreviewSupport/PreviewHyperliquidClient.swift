// SPDX-License-Identifier: MIT

#if DEBUG
    import Foundation
    import HyperliquidAPI
    import OpenHLCore

    /// A fake `HyperliquidClient` for SwiftUI previews and basic manual testing.
    /// Returns a hard-coded snapshot with a couple of positions.
    struct PreviewHyperliquidClient: HyperliquidClient {
        var delay: TimeInterval = 0.5
        var shouldFail: Bool = false

        func clearinghouseState(for user: Address) async throws -> ClearinghouseState {
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            if shouldFail {
                throw HyperliquidError.offline
            }
            return ClearinghouseState(
                summary: ClearinghouseState.AccountSummary(
                    accountValue: Decimal(string: "12453.21")!,
                    totalNotionalPosition: Decimal(string: "9800.00")!,
                    totalRawUSD: Decimal(string: "12000.00")!,
                    totalMarginUsed: Decimal(string: "4201.10")!,
                    withdrawable: Decimal(string: "8252.11")!
                ),
                positions: [
                    ClearinghouseState.Position(
                        coin: "BTC",
                        size: Decimal(string: "0.5")!,
                        side: .long,
                        entryPrice: Decimal(string: "62400.00")!,
                        positionValue: Decimal(string: "30590.00")!,
                        unrealizedPnL: Decimal(string: "-610.00")!,
                        returnOnEquity: Decimal(string: "-0.0098")!,
                        liquidationPrice: Decimal(string: "58200.00")!,
                        marginUsed: Decimal(string: "2100.00")!,
                        leverage: .cross(10)
                    ),
                    ClearinghouseState.Position(
                        coin: "ETH",
                        size: Decimal(string: "-2.0")!,
                        side: .short,
                        entryPrice: Decimal(string: "3210.00")!,
                        positionValue: Decimal(string: "6389.00")!,
                        unrealizedPnL: Decimal(string: "31.00")!,
                        returnOnEquity: Decimal(string: "0.0048")!,
                        liquidationPrice: Decimal(string: "3480.00")!,
                        marginUsed: Decimal(string: "1100.00")!,
                        leverage: .cross(5)
                    ),
                    ClearinghouseState.Position(
                        coin: "SOL",
                        size: Decimal(string: "10.0")!,
                        side: .long,
                        entryPrice: Decimal(string: "142.80")!,
                        positionValue: Decimal(string: "1430.00")!,
                        unrealizedPnL: Decimal(string: "15.00")!,
                        returnOnEquity: Decimal(string: "0.0105")!,
                        liquidationPrice: nil,
                        marginUsed: Decimal(string: "144.30")!,
                        leverage: .isolated(5)
                    ),
                ],
                serverTime: Date(),
                fetchedAt: Date()
            )
        }
    }
#endif
