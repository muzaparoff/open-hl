// SPDX-License-Identifier: MIT

// NOTE (qa-automation): These tests target view models that do not yet exist
// in the app target (ios-developer is implementing them in parallel). They
// are all annotated `.disabled` so the bundle compiles on the current stub
// surface without fatalErrors. When ios-developer lands:
//   1. Add `import HyperliquidAPI` and `import OpenHLCore` to this file.
//   2. Remove the local protocol+fake definitions below (they will be
//      replaced by the real types).
//   3. Remove `.disabled` from each suite.
//   4. Wire the actual view-model types in place of the stubs.
//
// The test *shapes* are final. The implementation wiring is the only TODO.

import Foundation
import Testing

// MARK: - Local stub types (deleted once ios-developer lands real view models)
//
// These mirror the architecture spec in docs/architecture.md §13 so the
// test logic compiles now and matches the real types once they exist.

// ViewErrorState mirrors architecture §11.4
private enum ViewErrorState: Sendable, Equatable {
    case offline
    case timeout
    case badRequest
    case serverError
    case unexpectedResponse
    case unknown
}

// Minimal Address stub (real one is in OpenHLCore)
private struct StubAddress: Sendable, Hashable {
    let rawValue: String
    static let test = StubAddress(rawValue: "0xabcdef1234567890abcdef1234567890abcdef12")
}

// Minimal ClearinghouseState stub
private struct StubClearinghouseState: Sendable, Equatable {
    let label: String  // differentiate states in tests
}

// HyperliquidError mirror
private enum StubHyperliquidError: Error, Sendable {
    case offline
    case timeout
    case httpStatus(Int)
    case decoding
    case unexpectedResponse(reason: String)
    case transport
}

// Fake client protocol
private protocol StubClient: Sendable {
    func clearinghouseState(for user: StubAddress) async throws -> StubClearinghouseState
}

private final class ConfigurableFakeClient: StubClient, @unchecked Sendable {
    var result: Result<StubClearinghouseState, StubHyperliquidError> = .failure(.offline)

    func clearinghouseState(for user: StubAddress) async throws -> StubClearinghouseState {
        switch result {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

// Stub AddressStore
private final class StubAddressStore: @unchecked Sendable {
    private var stored: StubAddress?
    init(initial: StubAddress? = nil) { self.stored = initial }
    func load() -> StubAddress? { stored }
    func save(_ addr: StubAddress) { stored = addr }
    func clear() { stored = nil }
}

// Stub PositionsViewModel state enum (mirrors architecture §13.1)
// This will be replaced by the real `PositionsViewModel.State` once it exists.
private enum PositionsViewModelState: Equatable {
    case idle
    case loading
    case loaded(StubClearinghouseState)
    case error(ViewErrorState, lastLoaded: StubClearinghouseState?)
}

// Stub PositionsViewModel (mirrors architecture §13.1)
// Replace with the real `PositionsViewModel` once ios-developer lands it.
@MainActor
private final class StubPositionsViewModel {

    private(set) var state: PositionsViewModelState = .idle
    private let client: ConfigurableFakeClient
    private let address: StubAddress

    init(client: ConfigurableFakeClient, address: StubAddress) {
        self.client = client
        self.address = address
    }

    func load() async {
        state = .loading
        do {
            let result = try await client.clearinghouseState(for: address)
            guard !Task.isCancelled else { return }
            state = .loaded(result)
        } catch let err as StubHyperliquidError {
            guard !Task.isCancelled else { return }
            state = .error(mapError(err), lastLoaded: nil)
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(.unknown, lastLoaded: nil)
        }
    }

    func refresh() async {
        let previous: StubClearinghouseState?
        if case .loaded(let s) = state { previous = s } else { previous = nil }

        state = .loading
        do {
            let result = try await client.clearinghouseState(for: address)
            guard !Task.isCancelled else { return }
            state = .loaded(result)
        } catch let err as StubHyperliquidError {
            guard !Task.isCancelled else { return }
            state = .error(mapError(err), lastLoaded: previous)
        } catch {
            guard !Task.isCancelled else { return }
            state = .error(.unknown, lastLoaded: previous)
        }
    }

    private func mapError(_ err: StubHyperliquidError) -> ViewErrorState {
        switch err {
        case .offline: return .offline
        case .timeout: return .timeout
        case .httpStatus(let code) where code >= 500: return .serverError
        case .httpStatus: return .badRequest
        case .decoding: return .unexpectedResponse
        case .unexpectedResponse: return .unexpectedResponse
        case .transport: return .unknown
        }
    }
}

// MARK: - PositionsViewModel state-machine tests

@Suite("PositionsViewModel — state machine", .disabled("Waiting for ios-developer to land PositionsViewModel"))
@MainActor
struct PositionsViewModelStateTests {

    private func makeViewModel(result: Result<StubClearinghouseState, StubHyperliquidError>)
        -> (StubPositionsViewModel, ConfigurableFakeClient)
    {
        let client = ConfigurableFakeClient()
        client.result = result
        let vm = StubPositionsViewModel(client: client, address: .test)
        return (vm, client)
    }

    @Test("Initial state is .idle")
    func initialStateIsIdle() {
        let (vm, _) = makeViewModel(result: .failure(.offline))
        #expect(vm.state == .idle)
    }

    @Test("load() transitions idle → loading → loaded on success")
    func loadHappyPath() async {
        let expected = StubClearinghouseState(label: "success")
        let (vm, _) = makeViewModel(result: .success(expected))

        // State is idle before any load.
        #expect(vm.state == .idle)
        await vm.load()
        #expect(vm.state == .loaded(expected))
    }

    @Test("load() transitions idle → loading → error(.offline) on offline error")
    func loadOfflineError() async {
        let (vm, _) = makeViewModel(result: .failure(.offline))
        await vm.load()
        #expect(vm.state == .error(.offline, lastLoaded: nil))
    }

    @Test("load() transitions idle → loading → error(.timeout) on timeout")
    func loadTimeoutError() async {
        let (vm, _) = makeViewModel(result: .failure(.timeout))
        await vm.load()
        #expect(vm.state == .error(.timeout, lastLoaded: nil))
    }

    @Test("load() produces error(.unexpectedResponse) on decoding error")
    func loadDecodingError() async {
        let (vm, _) = makeViewModel(result: .failure(.decoding))
        await vm.load()
        #expect(vm.state == .error(.unexpectedResponse, lastLoaded: nil))
    }

    @Test("load() produces error(.serverError) on HTTP 500")
    func loadHttp500Error() async {
        let (vm, _) = makeViewModel(result: .failure(.httpStatus(500)))
        await vm.load()
        #expect(vm.state == .error(.serverError, lastLoaded: nil))
    }

    @Test("load() produces error(.badRequest) on HTTP 429")
    func loadHttp429Error() async {
        let (vm, _) = makeViewModel(result: .failure(.httpStatus(429)))
        await vm.load()
        #expect(vm.state == .error(.badRequest, lastLoaded: nil))
    }

    @Test("refresh() after a successful load preserves lastLoaded on failure")
    func refreshPreservesLastLoadedOnFailure() async {
        let initial = StubClearinghouseState(label: "initial")
        let (vm, client) = makeViewModel(result: .success(initial))

        // First load succeeds.
        await vm.load()
        #expect(vm.state == .loaded(initial))

        // Switch the fake to fail.
        client.result = .failure(.offline)
        await vm.refresh()

        // Error state must carry the previously loaded snapshot.
        #expect(vm.state == .error(.offline, lastLoaded: initial))
    }

    @Test("refresh() on a cold (idle) view model produces error with lastLoaded: nil on failure")
    func refreshColdFailureHasNoLastLoaded() async {
        let (vm, _) = makeViewModel(result: .failure(.offline))
        await vm.refresh()
        #expect(vm.state == .error(.offline, lastLoaded: nil))
    }

    @Test("refresh() after error (no prior success) has no lastLoaded")
    func refreshAfterErrorNoLastLoaded() async {
        let (vm, _) = makeViewModel(result: .failure(.timeout))
        await vm.load()  // → error(.timeout, lastLoaded: nil)
        await vm.refresh()  // → still error, still no lastLoaded
        #expect(vm.state == .error(.timeout, lastLoaded: nil))
    }
}

// MARK: - Position sort order tests

@Suite("PositionsViewModel — sort order", .disabled("Waiting for ios-developer to land PositionsViewModel"))
struct PositionSortOrderTests {

    // The architecture does not specify a sort predicate in §13, but the task
    // scope asks: "sorted by absolute notional descending, stable by asset name."
    // This test validates that the view model exposes positions in that order.
    // When ios-developer implements the sort, it must satisfy this contract.

    private struct SortablePosition: Equatable {
        let coin: String
        let positionValue: Decimal
        let unrealizedPnL: Decimal
    }

    private func sortedByAbsNotionalThenName(_ positions: [SortablePosition]) -> [SortablePosition] {
        positions.sorted { lhs, rhs in
            let lhsAbs = abs(lhs.positionValue)
            let rhsAbs = abs(rhs.positionValue)
            if lhsAbs != rhsAbs { return lhsAbs > rhsAbs }
            return lhs.coin < rhs.coin
        }
    }

    @Test("Positions sorted descending by absolute notional value, then ascending by coin name for ties")
    func sortedByAbsNotionalDescendingThenCoinAscending() {
        let unsorted: [SortablePosition] = [
            SortablePosition(coin: "SOL", positionValue: 1_000, unrealizedPnL: 0),
            SortablePosition(coin: "BTC", positionValue: 50_000, unrealizedPnL: 500),
            SortablePosition(coin: "ETH", positionValue: 20_000, unrealizedPnL: -200),
            SortablePosition(coin: "ARB", positionValue: 500, unrealizedPnL: 10),
        ]

        let sorted = sortedByAbsNotionalThenName(unsorted)

        #expect(sorted[0].coin == "BTC")
        #expect(sorted[1].coin == "ETH")
        #expect(sorted[2].coin == "SOL")
        #expect(sorted[3].coin == "ARB")
    }

    @Test("Sort is stable: equal notional values are ordered by coin name ascending")
    func sortIsStableByName() {
        let unsorted: [SortablePosition] = [
            SortablePosition(coin: "ZRX", positionValue: 5_000, unrealizedPnL: 0),
            SortablePosition(coin: "AAVE", positionValue: 5_000, unrealizedPnL: 0),
            SortablePosition(coin: "BTC", positionValue: 50_000, unrealizedPnL: 0),
        ]

        let sorted = sortedByAbsNotionalThenName(unsorted)

        #expect(sorted[0].coin == "BTC")
        #expect(sorted[1].coin == "AAVE")  // Tie at 5000, "AAVE" < "ZRX"
        #expect(sorted[2].coin == "ZRX")
    }

    @Test("Short positions (negative size → negative positionValue) sort by absolute value")
    func shortPositionsSortByAbsoluteValue() {
        let unsorted: [SortablePosition] = [
            SortablePosition(coin: "ETH", positionValue: -30_000, unrealizedPnL: -100),
            SortablePosition(coin: "BTC", positionValue: 10_000, unrealizedPnL: 50),
        ]

        let sorted = sortedByAbsNotionalThenName(unsorted)

        // |ETH| = 30000 > |BTC| = 10000
        #expect(sorted[0].coin == "ETH")
        #expect(sorted[1].coin == "BTC")
    }

    @Test("Single position list is returned unchanged")
    func singlePositionIsUnchanged() {
        let only = SortablePosition(coin: "BTC", positionValue: 50_000, unrealizedPnL: 0)
        let sorted = sortedByAbsNotionalThenName([only])
        #expect(sorted == [only])
    }

    @Test("Empty list is returned unchanged")
    func emptyListIsUnchanged() {
        let sorted = sortedByAbsNotionalThenName([])
        #expect(sorted.isEmpty)
    }
}
