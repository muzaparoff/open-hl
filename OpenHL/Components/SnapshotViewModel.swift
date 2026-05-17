// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OSLog
import OpenHLCore

/// Generic state machine for any "fetch a snapshot and show it" screen.
/// Replaces the three near-identical Positions / Orders / Fills view models
/// with one shape, and now also drives Markets:
///
/// - `idle` until `load()` is called
/// - `loading` while the first fetch is in-flight
/// - `loaded(Snapshot)` once the fetch returns
/// - `error(_, lastLoaded:)` carries the prior snapshot on refresh failure
///   so the view can keep showing data with an inline banner
///
/// Typealiased specializations supply:
/// - the concrete `Snapshot` type
/// - a fetch closure that captures whatever it needs (client, address, …)
/// - an optional post-process closure (sort, filter, normalize)
/// - a logger category for OSLog
/// - optionally an `Address` for views that want to display it
@MainActor
@Observable
final class SnapshotViewModel<Snapshot: Sendable & Equatable>: Sendable {

    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded(Snapshot)
        case error(ViewErrorState, lastLoaded: Snapshot?)
    }

    private(set) var state: State = .idle

    /// Optional. Address-scoped view models (Positions/Orders/Fills) set this
    /// so views can show the truncated address in the header. Address-agnostic
    /// view models (Markets) leave it nil.
    let address: Address?

    private let fetchClosure: @Sendable () async throws -> Snapshot
    private let postProcess: @MainActor (Snapshot) -> Snapshot
    private let logger: Logger

    init(
        address: Address? = nil,
        category: String,
        fetch: @escaping @Sendable () async throws -> Snapshot,
        postProcess: @escaping @MainActor (Snapshot) -> Snapshot = { $0 }
    ) {
        self.address = address
        self.fetchClosure = fetch
        self.postProcess = postProcess
        self.logger = Logger(subsystem: "xyz.hyperliquid.openhl", category: category)
    }

    var lastLoaded: Snapshot? {
        switch state {
        case .loaded(let s): return s
        case .error(_, let s): return s
        default: return nil
        }
    }

    /// Apply a live snapshot delivered by the WebSocket layer.
    /// Replaces `.loaded` state in place so the view re-renders immediately.
    /// The supplied `snapshot` is passed through `postProcess` first so
    /// sorting/filtering rules stay consistent between REST and WS data.
    /// No-op when there is no prior loaded snapshot — WS data should not
    /// pre-empt the cold-load `.loading` state.
    func applyLiveSnapshot(_ snapshot: Snapshot) {
        guard lastLoaded != nil else { return }
        state = .loaded(postProcess(snapshot))
    }

    /// Mutate the currently-loaded snapshot in place via a transform.
    /// The transform receives the current snapshot and returns the new one.
    /// The result is stored **without** re-applying `postProcess` because the
    /// caller is responsible for any post-processing (e.g. `applyMids`
    /// already filters unchanged values). No-op if not in `.loaded` state.
    func mutateLoaded(_ transform: (Snapshot) -> Snapshot) {
        guard case .loaded(let current) = state else { return }
        state = .loaded(transform(current))
    }

    /// Cold-start load. No-op unless `state == .idle`.
    func load() async {
        guard case .idle = state else { return }
        state = .loading
        await fetch(isRefresh: false)
    }

    /// Pull-to-refresh. Preserves stale data on failure so the view can
    /// show an inline banner over prior content.
    func refresh() async {
        switch state {
        case .loaded:
            await fetch(isRefresh: true)
        case .error(_, let prior):
            if prior == nil { state = .loading }
            await fetch(isRefresh: prior != nil)
        default:
            await fetch(isRefresh: false)
        }
    }

    /// Explicit "Try again" from the error view. Treats a previously-loaded
    /// snapshot as a refresh; otherwise behaves like a cold load.
    func retry() async {
        let prior = lastLoaded
        if prior == nil { state = .loading }
        await fetch(isRefresh: prior != nil)
    }

    private func fetch(isRefresh: Bool) async {
        let prior = lastLoaded
        do {
            let raw = try await fetchClosure()
            guard !Task.isCancelled else { return }
            state = .loaded(postProcess(raw))
        } catch is CancellationError {
            // Cancelled: do not mutate state.
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(ViewErrorState(any: error), lastLoaded: prior)
            logger.error(
                "fetch failed (refresh=\(isRefresh, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
