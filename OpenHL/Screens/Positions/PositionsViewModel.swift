// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OpenHLCore

typealias PositionsViewModel = SnapshotViewModel<ClearinghouseState>

extension SnapshotViewModel where Snapshot == ClearinghouseState {
    static func positions(
        client: any HyperliquidClient,
        address: Address
    ) -> PositionsViewModel {
        PositionsViewModel(
            address: address,
            category: "Positions",
            fetch: { try await client.clearinghouseState(for: address) },
            postProcess: sortByAbsoluteNotional
        )
    }

    /// Apply a live `WebData2` update to the loaded positions snapshot.
    /// Routes through `applyLiveSnapshot` so `postProcess` (the sort) is
    /// applied consistently. No-op until the first REST fetch completes.
    func applyWebData2(_ payload: WebData2) {
        applyLiveSnapshot(payload.clearinghouseState)
    }

    /// Sort positions by absolute notional descending; stable secondary by coin.
    private static func sortByAbsoluteNotional(_ state: ClearinghouseState) -> ClearinghouseState {
        let sorted = state.positions.sorted { lhs, rhs in
            let lhsNotional = abs(lhs.positionValue)
            let rhsNotional = abs(rhs.positionValue)
            if lhsNotional != rhsNotional {
                return lhsNotional > rhsNotional
            }
            return lhs.coin < rhs.coin
        }
        return ClearinghouseState(
            summary: state.summary,
            positions: sorted,
            serverTime: state.serverTime,
            fetchedAt: state.fetchedAt
        )
    }
}
