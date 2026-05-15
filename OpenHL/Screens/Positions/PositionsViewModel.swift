// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OSLog
import OpenHLCore

private let logger = Logger(subsystem: "xyz.hyperliquid.openhl", category: "Positions")

@MainActor
@Observable
final class PositionsViewModel {

    // MARK: - State

    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded(ClearinghouseState)
        /// Error with optional stale data: nil = cold-start failure,
        /// non-nil = refresh failure (keep showing old data).
        case error(ViewErrorState, lastLoaded: ClearinghouseState?)
    }

    private(set) var state: State = .idle

    // MARK: - Dependencies

    private let client: any HyperliquidClient
    let address: Address
    private let clock: any Clock

    // MARK: - Init

    init(client: any HyperliquidClient, address: Address, clock: any Clock) {
        self.client = client
        self.address = address
        self.clock = clock
    }

    // MARK: - Derived helpers for views

    var isRefreshing: Bool {
        if case .loaded = state { return false }
        return false
    }

    var lastLoadedState: ClearinghouseState? {
        switch state {
        case .loaded(let s): return s
        case .error(_, let s): return s
        default: return nil
        }
    }

    // MARK: - Actions

    /// Initial cold-start load. Called from `.task` on the view.
    func load() async {
        guard case .idle = state else { return }
        state = .loading
        await fetch(isRefresh: false)
    }

    /// Pull-to-refresh. Called from `.refreshable`.
    func refresh() async {
        // Only refresh when we already have data.
        guard case .loaded(let existing) = state else {
            // If we're in an error state, trigger a full reload.
            if case .error(_, let prior) = state {
                state = prior == nil ? .loading : state
                await fetch(isRefresh: prior != nil)
            } else {
                await fetch(isRefresh: false)
            }
            return
        }
        // Keep showing existing data while refreshing.
        _ = existing  // already held in .loaded
        await fetch(isRefresh: true)
    }

    /// Explicit "Try again" from the error view. Same as load from idle.
    func retry() async {
        let prior: ClearinghouseState?
        if case .error(_, let p) = state {
            prior = p
        } else {
            prior = nil
        }
        if prior == nil {
            state = .loading
        }
        await fetch(isRefresh: prior != nil)
    }

    // MARK: - Private

    private func fetch(isRefresh: Bool) async {
        let staleData: ClearinghouseState?
        switch state {
        case .loaded(let s):
            staleData = s
        case .error(_, let s):
            staleData = s
        default:
            staleData = nil
        }

        do {
            let result = try await client.clearinghouseState(for: address)
            guard !Task.isCancelled else { return }
            // Sort positions by absolute notional descending, then by coin name
            let sorted = result.positions.sorted { lhs, rhs in
                let lhsNotional = abs(lhs.positionValue)
                let rhsNotional = abs(rhs.positionValue)
                if lhsNotional != rhsNotional {
                    return lhsNotional > rhsNotional
                }
                return lhs.coin < rhs.coin
            }
            let sortedState = ClearinghouseState(
                summary: result.summary,
                positions: sorted,
                serverTime: result.serverTime,
                fetchedAt: result.fetchedAt
            )
            state = .loaded(sortedState)
        } catch is CancellationError {
            // Cancelled: do not mutate state. The view is gone or
            // a newer fetch superseded this one.
        } catch let error as HyperliquidError {
            guard !Task.isCancelled else { return }
            let errorState = viewErrorState(from: error)
            state = .error(errorState, lastLoaded: staleData)
            logger.error(
                "Positions fetch failed (refresh=\(isRefresh, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(.unknown, lastLoaded: staleData)
            logger.error("Unexpected error: \(error, privacy: .public)")
        }
    }

    private func viewErrorState(from error: HyperliquidError) -> ViewErrorState {
        switch error {
        case .offline:
            return .offline
        case .timeout:
            return .timeout
        case .httpStatus(let code):
            return code >= 500 ? .serverError(code) : .badRequest
        case .decoding, .unexpectedResponse:
            return .unexpectedResponse
        case .transport:
            return .unknown
        }
    }
}
