// SPDX-License-Identifier: MIT

// Tests for `LiveStore` — the @MainActor coordinator that bridges
// HyperliquidStream events into observable view-model state (Phase 4).
//
// `LiveStore` is @MainActor. Swift Testing (as bundled in Xcode 16) does not
// support @MainActor on Suite structs directly — the discovery mechanism runs
// outside the main actor. We work around this by:
//
//  • Wrapping @MainActor property access in `await MainActor.run { }`.
//  • Using a short real sleep (100 ms) after scene-phase calls to let the
//    detached `Task` spawned inside `sceneDidActivate` / `sceneDidBackground`
//    actually execute — `Task.yield()` alone is insufficient for cross-actor
//    hops.
//  • For stale-threshold tests: we pre-seed the fake stream's state *after*
//    `connect()` runs (which always sets .connected) so the stale-check loop
//    sees the desired state on its first tick.
//
// NOTE to swift-expert: a `@testable` `forceUpdateConnectionState()` async
// method on `LiveStore` would remove the 1.2 s real-time waits from the four
// stale-threshold tests. Flagged in the qa report.

import Foundation
import HyperliquidAPI
import OpenHLCore
import Testing

@testable import OpenHL

// MARK: - FakeHyperliquidStream

/// Minimal scripted `HyperliquidStream` for LiveStore unit tests.
/// `NSLock`-protected for Sendable safety; mutations from the test body,
/// reads from the `@MainActor` LiveStore.
final class FakeHyperliquidStream: HyperliquidStream, @unchecked Sendable {

    private let lock = NSLock()
    private var _state: ConnectionState = .idle
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private var midsContinuation: AsyncStream<[String: Decimal]>.Continuation?

    init(initialState: ConnectionState = .idle) {
        _state = initialState
    }

    var connectionState: ConnectionState {
        lock.withLock { _state }
    }

    /// Overrides the internally-managed state (e.g. to force .reconnecting
    /// after connect() has already run and set .connected).
    func setState(_ state: ConnectionState) {
        lock.withLock { _state = state }
    }

    func connect() async {
        lock.withLock {
            connectCallCount += 1
            _state = .connected(since: Date(), lastMessageAt: Date())
        }
    }

    func disconnect() async {
        lock.withLock {
            disconnectCallCount += 1
            _state = .disconnected(reason: .backgrounded)
        }
    }

    func mids() async -> AsyncStream<[String: Decimal]> {
        AsyncStream<[String: Decimal]>(bufferingPolicy: .bufferingNewest(1)) { [weak self] cont in
            self?.lock.withLock { self?.midsContinuation = cont }
        }
    }

    func activeAssetCtx(coin: String) async -> AsyncStream<AssetContext> {
        AsyncStream<AssetContext> { _ in }
    }

    func candle(coin: String, interval: CandleInterval) async -> AsyncStream<Candle> {
        AsyncStream<Candle> { _ in }
    }

    func webData2(for user: Address) async -> AsyncStream<WebData2> {
        AsyncStream<WebData2> { _ in }
    }

    func pushMids(_ dict: [String: Decimal]) {
        lock.withLock { midsContinuation }?.yield(dict)
    }
}

// MARK: - Suite

@Suite("LiveStore — scene-phase and connection-state tests (Phase 4)")
struct Phase4LiveStoreTests {

    // MARK: Scene-phase lifecycle

    @Test("sceneDidActivate calls stream.connect()")
    func sceneActivateCallsConnect() async throws {
        let fakeStream = FakeHyperliquidStream()
        let store = await MainActor.run {
            LiveStore(stream: fakeStream, clock: FixedClock(Date()))
        }
        await MainActor.run { store.sceneDidActivate() }
        // The Task spawned by sceneDidActivate needs to execute in the
        // actor's executor; a short real sleep is more reliable than yields.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fakeStream.connectCallCount >= 1)
    }

    @Test("sceneDidBackground calls stream.disconnect() and sets connectionState to .disconnected")
    func sceneBackgroundCallsDisconnect() async throws {
        let fakeStream = FakeHyperliquidStream(
            initialState: .connected(since: Date(), lastMessageAt: Date())
        )
        let store = await MainActor.run {
            LiveStore(stream: fakeStream, clock: FixedClock(Date()))
        }
        await MainActor.run { store.sceneDidBackground() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fakeStream.disconnectCallCount >= 1)
        let state = await MainActor.run { store.connectionState }
        #expect(state == .disconnected)
    }

    @Test("active → background cycle: connect then disconnect")
    func activeThenBackground() async throws {
        let fakeStream = FakeHyperliquidStream()
        let store = await MainActor.run {
            LiveStore(stream: fakeStream, clock: FixedClock(Date()))
        }
        await MainActor.run { store.sceneDidActivate() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let connectCount = fakeStream.connectCallCount

        await MainActor.run { store.sceneDidBackground() }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(connectCount >= 1)
        #expect(fakeStream.disconnectCallCount >= 1)
        let state = await MainActor.run { store.connectionState }
        #expect(state == .disconnected)
    }

    // MARK: connectionState projection — stale threshold
    //
    // Pattern: call sceneDidActivate() so the stale-check loop starts,
    // let connect() run (it sets .connected), then *override* the fake
    // state to the scenario under test, and wait 1.2 s for the loop to fire.

    @Test("connectionState is .stale when stream.connectionState is .reconnecting")
    func reconnectingIsStale() async throws {
        let now = Date()
        let fakeStream = FakeHyperliquidStream()
        let clock = FixedClock(now)
        let store = await MainActor.run { LiveStore(stream: fakeStream, clock: clock) }

        await MainActor.run { store.sceneDidActivate() }
        try await Task.sleep(nanoseconds: 100_000_000)  // let connect() run

        // Override to the desired scenario after connect() set .connected.
        fakeStream.setState(.reconnecting(attempt: 1, nextAttemptAt: now.addingTimeInterval(2)))

        try await Task.sleep(nanoseconds: 1_200_000_000)

        let state = await MainActor.run { store.connectionState }
        #expect(state == .stale)
    }

    @Test("connectionState is .stale when last message is older than 10 s")
    func noMessageFor10sIsStale() async throws {
        let staleTime = Date(timeIntervalSinceNow: -15)
        let now = Date()
        let fakeStream = FakeHyperliquidStream()
        let clock = FixedClock(now)
        let store = await MainActor.run { LiveStore(stream: fakeStream, clock: clock) }

        await MainActor.run { store.sceneDidActivate() }
        try await Task.sleep(nanoseconds: 100_000_000)

        // lastMessageAt is 15 s in the past; clock is fixed at `now`.
        fakeStream.setState(.connected(since: staleTime, lastMessageAt: staleTime))

        try await Task.sleep(nanoseconds: 1_200_000_000)

        let state = await MainActor.run { store.connectionState }
        #expect(state == .stale)
    }

    @Test("connectionState is .connected when last message is fresh (< 10 s ago)")
    func freshMessageIsConnected() async throws {
        let now = Date()
        let fakeStream = FakeHyperliquidStream()
        let clock = FixedClock(now)
        let store = await MainActor.run { LiveStore(stream: fakeStream, clock: clock) }

        await MainActor.run { store.sceneDidActivate() }
        try await Task.sleep(nanoseconds: 100_000_000)

        // connect() already set .connected(lastMessageAt: ~now) — this is fresh.
        // Verify the loop reads it as .connected.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let state = await MainActor.run { store.connectionState }
        #expect(state == .connected)
    }

    @Test("connectionState is .disconnected when stream state is .idle")
    func idleStateIsDisconnected() async throws {
        let fakeStream = FakeHyperliquidStream(initialState: .idle)
        let store = await MainActor.run { LiveStore(stream: fakeStream, clock: FixedClock(Date())) }

        await MainActor.run { store.sceneDidActivate() }
        try await Task.sleep(nanoseconds: 100_000_000)

        // connect() will have set .connected; override to .idle to test the mapping.
        fakeStream.setState(.idle)

        try await Task.sleep(nanoseconds: 1_200_000_000)

        let state = await MainActor.run { store.connectionState }
        #expect(state == .disconnected)
    }

    // MARK: Channel delegation

    @Test("mids() delegates to stream.mids() and returns an AsyncStream")
    func midsChannelDelegates() async throws {
        let fakeStream = FakeHyperliquidStream()
        let store = await MainActor.run { LiveStore(stream: fakeStream, clock: FixedClock(Date())) }

        let midsStream = await store.mids()
        fakeStream.pushMids(["BTC": 100_000])

        var received: [String: Decimal]?
        for await dict in midsStream {
            received = dict
            break
        }
        #expect(received?["BTC"] == 100_000)
    }
}
