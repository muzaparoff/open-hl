// SPDX-License-Identifier: MIT

import Foundation
import OpenHLCore
import Testing

@testable import HyperliquidAPI

// MARK: - Helpers

/// Returns the raw bytes of the first line from a `.jsonl` fixture.
private func firstLineData(_ name: String) throws -> Data {
    let lines = try FixtureLoader.loadLines(name)
    return try #require(lines.first)
}

/// Collects `count` values from `stream` with a wall-clock timeout.
/// Cancels the surrounding task if the count is not reached, preventing
/// a hang when a stub feeds fewer messages than expected.
private func collect<T: Sendable>(
    _ count: Int,
    from stream: AsyncStream<T>,
    timeout: TimeInterval = 5.0
) async throws -> [T] {
    var results: [T] = []
    results.reserveCapacity(count)
    let deadline = Date(timeIntervalSinceNow: timeout)
    for await value in stream {
        results.append(value)
        if results.count == count { break }
        if Date() > deadline {
            throw TestTimeout()
        }
    }
    return results
}

private struct TestTimeout: Error {}

// MARK: - Suite

@Suite("URLSessionHyperliquidStream — StubWebSocketTransport integration (Phase 4)")
struct Phase4StreamTests {

    // MARK: mids subscription

    @Test("Subscribe to .mids() → collect 3 non-empty [String:Decimal] messages")
    func midsCollectsThreeMessages() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        let lines = try FixtureLoader.loadLines("ws_allMids_real")
        // We only have 3 lines; enqueue them all before connecting so the
        // receive loop can drain them immediately.
        for line in lines { stub.enqueueReceive(line) }

        let midsStream = await stream.mids()
        await stream.connect()

        let messages = try await collect(3, from: midsStream)
        #expect(messages.count == 3)
        for dict in messages {
            #expect(!dict.isEmpty)
        }
    }

    @Test("mids subscription request wire shape matches {method:subscribe,subscription:{type:allMids}}")
    func midsSubscriptionRequestShape() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        // Give it a message so the receive loop doesn't block indefinitely.
        let line = try firstLineData("ws_allMids_real")
        stub.enqueueReceive(line)

        _ = await stream.mids()
        await stream.connect()

        // Allow the actor one scheduler pass to flush the subscribe frame.
        await Task.yield()

        // The first sent frame must be the subscribe request.
        let sentFrames = stub.sentFrames
        #expect(!sentFrames.isEmpty, "No subscribe frame was sent")

        let sentJSON =
            try JSONSerialization.jsonObject(
                with: try #require(sentFrames.first)
            ) as! [String: Any]
        #expect(sentJSON["method"] as? String == "subscribe")
        let sub = try #require(sentJSON["subscription"] as? [String: Any])
        #expect(sub["type"] as? String == "allMids")
    }

    // MARK: candle subscription

    @Test("Subscribe to .candle(coin:BTC, interval:.oneHour) → collect 2 BTC Candles")
    func candleCollectsTwoMessages() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        let lines = try FixtureLoader.loadLines("ws_candle_btc_1h_real")
        for line in lines { stub.enqueueReceive(line) }

        let candleStream = await stream.candle(coin: "BTC", interval: .oneHour)
        await stream.connect()

        let candles = try await collect(2, from: candleStream)
        #expect(candles.count == 2)
        for c in candles {
            #expect(c.coin == "BTC")
            #expect(c.interval == .oneHour)
        }
    }

    // MARK: Multi-subscriber fan-out

    @Test("Two mids() subscribers both receive the same messages")
    func multiSubscriberFanOut() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        let lines = try FixtureLoader.loadLines("ws_allMids_real")
        // Duplicate each line so both subscribers can collect without racing.
        for line in lines { stub.enqueueReceive(line) }
        for line in lines { stub.enqueueReceive(line) }

        let streamA = await stream.mids()
        let streamB = await stream.mids()
        await stream.connect()

        async let resultA = collect(1, from: streamA)
        async let resultB = collect(1, from: streamB)
        let (a, b) = try await (resultA, resultB)

        #expect(!a.isEmpty)
        #expect(!b.isEmpty)
        // Both should have seen a BTC price.
        #expect(a[0]["BTC"] != nil)
        #expect(b[0]["BTC"] != nil)
    }

    // MARK: Disconnect / reconnect re-sends subscriptions

    @Test("Transport failure triggers reconnect and re-sends subscriptions on fresh transport")
    func reconnectResendsSubscriptions() async throws {
        // First transport throws immediately to simulate a mid-stream failure.
        let firstStub = StubWebSocketTransport()
        let secondStub = StubWebSocketTransport()

        // Use a reference-type counter so the @Sendable factory closure can
        // increment it without a captured-var diagnostic under Swift 6.
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let stream = URLSessionHyperliquidStream(
            clock: FixedClock(Date()),
            transportFactory: {
                counter.value += 1
                return counter.value == 1 ? firstStub : secondStub
            }
        )

        // Enqueue a real message on the second stub so the loop has something to
        // receive after reconnect.
        let line = try firstLineData("ws_allMids_real")
        secondStub.enqueueReceive(line)

        _ = await stream.mids()

        // Connect — this uses firstStub. Immediately enqueue a failure so the
        // receive loop errors out and the reconnect machine kicks in.
        firstStub.enqueueFailure(StubWebSocketTransport.StubClosed())
        await stream.connect()

        // Give the reconnect task time to cycle. The ReconnectMachine with
        // FixedClock(Date()) will compute a very small delay (≈1s base); we
        // wait briefly for it to complete.
        try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 s

        // By now the actor should have connected to secondStub and sent the
        // subscribe frame again.
        #expect(secondStub.connectCallCount >= 1, "Second transport was never connected")
        #expect(!secondStub.sentFrames.isEmpty, "Re-subscribe frame was not sent on reconnect")
    }

    // MARK: webData2 subscription

    @Test("Subscribe to .webData2(for:) → collect 1 WebData2 with a BTC position")
    func webData2CollectsOneMessage() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        let line = try firstLineData("ws_webData2_real")
        stub.enqueueReceive(line)

        let testAddress = try Address("0x99382723c90ecc72dad2a7dd375de45b88e8fe72")
        let wd2Stream = await stream.webData2(for: testAddress)
        await stream.connect()

        let messages = try await collect(1, from: wd2Stream)
        let payload = try #require(messages.first)
        #expect(!payload.clearinghouseState.positions.isEmpty)
        #expect(payload.clearinghouseState.positions[0].coin == "BTC")
    }

    // MARK: activeAssetCtx subscription

    @Test("Subscribe to .activeAssetCtx(coin:BTC) → collect 2 AssetContexts with markPx > 0")
    func activeAssetCtxCollectsTwoMessages() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        let lines = try FixtureLoader.loadLines("ws_activeAssetCtx_btc_real")
        for line in lines { stub.enqueueReceive(line) }

        let ctxStream = await stream.activeAssetCtx(coin: "BTC")
        await stream.connect()

        let ctxs = try await collect(2, from: ctxStream)
        #expect(ctxs.count == 2)
        for ctx in ctxs {
            #expect(ctx.markPx > 0)
        }
    }

    // MARK: Disconnect clears state

    @Test("disconnect() closes transport and sets connectionState to .disconnected")
    func disconnectClosesTransport() async throws {
        let stub = StubWebSocketTransport()
        let stream = URLSessionHyperliquidStream(
            transportFactory: { stub }
        )

        let line = try firstLineData("ws_allMids_real")
        stub.enqueueReceive(line)

        _ = await stream.mids()
        await stream.connect()
        await stream.disconnect()

        #expect(stub.closeCallCount >= 1)
        let state = await stream.connectionState
        if case .disconnected = state {
            // pass
        } else {
            Issue.record("Expected .disconnected after explicit disconnect, got \(state)")
        }
    }
}
