// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OpenHLCore

typealias MarketsViewModel = SnapshotViewModel<[Market]>

extension SnapshotViewModel where Snapshot == [Market] {
    /// Build a `MarketsViewModel` wired to `client.markets()`.
    /// Sorted by 24h notional volume descending so the most-traded
    /// perps surface first; stable secondary by coin name.
    static func markets(client: any HyperliquidClient) -> MarketsViewModel {
        MarketsViewModel(
            category: "Markets",
            fetch: { try await client.markets() },
            postProcess: sortByDayVolume
        )
    }

    private static func sortByDayVolume(_ markets: [Market]) -> [Market] {
        markets.sorted { lhs, rhs in
            if lhs.dayNotionalVolume != rhs.dayNotionalVolume {
                return lhs.dayNotionalVolume > rhs.dayNotionalVolume
            }
            return lhs.coin < rhs.coin
        }
    }

    /// Apply a live `allMids` dictionary to the loaded market array.
    /// Replaces `markPrice` and `midPrice` for any coin present in `mids`.
    /// No-op if the view model is not in `.loaded` state.
    ///
    /// Coalescing note: the view model itself applies every emission it
    /// receives; the caller (MarketsView) gates the subscription to at most
    /// ~1 Hz via the stream's latest-wins buffering policy
    /// (`bufferingPolicy: .bufferingNewest(1)`).
    func applyMids(_ mids: [String: Decimal]) {
        mutateLoaded { current in
            var updated = false
            let newMarkets = current.map { market -> Market in
                guard let mid = mids[market.coin] else { return market }
                // Only replace when the value changed — avoids SwiftUI diffing noise.
                if mid == market.markPrice { return market }
                updated = true
                return Market(
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
            return updated ? newMarkets : current
        }
    }
}
