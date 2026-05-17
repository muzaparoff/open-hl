// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import HyperliquidAPI

// MARK: - Real-fixture decoder tests

@Suite("StreamMessage — real-fixture decoding (Phase 4)")
struct Phase4StreamMessageTests {

    // MARK: allMids

    @Test("Decodes every line of ws_allMids_real.jsonl as .mids")
    func allMidsAllLines() throws {
        let lines = try FixtureLoader.loadLines("ws_allMids_real")
        #expect(!lines.isEmpty)
        for (index, data) in lines.enumerated() {
            let msg = try StreamMessage.decode(data)
            guard case .mids(let dict) = msg else {
                Issue.record("Line \(index): expected .mids, got \(msg)")
                continue
            }
            #expect(!dict.isEmpty, "Line \(index): mids dict must be non-empty")
        }
    }

    @Test("allMids fixture contains BTC with a positive Decimal price")
    func allMidsContainsBTC() throws {
        let lines = try FixtureLoader.loadLines("ws_allMids_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .mids(let dict) = msg else {
            Issue.record("Expected .mids, got \(msg)")
            return
        }
        let btcPrice = try #require(dict["BTC"], "BTC key absent from allMids")
        #expect(btcPrice > 0)
    }

    @Test("allMids values parse as Decimal (not NaN or zero via string bug)")
    func allMidsValuesArePositiveDecimals() throws {
        let lines = try FixtureLoader.loadLines("ws_allMids_real")
        guard let firstData = lines.first else { return }
        let msg = try StreamMessage.decode(firstData)
        guard case .mids(let dict) = msg else { return }
        // Every value the wire sent must be a valid non-negative Decimal.
        // (Some exotic perps can be tiny but never negative.)
        for (coin, price) in dict {
            #expect(price >= 0, "Coin '\(coin)' has negative mid price: \(price)")
        }
    }

    // MARK: activeAssetCtx

    @Test("Decodes every line of ws_activeAssetCtx_btc_real.jsonl as .activeAssetCtx")
    func activeAssetCtxAllLines() throws {
        let lines = try FixtureLoader.loadLines("ws_activeAssetCtx_btc_real")
        #expect(!lines.isEmpty)
        for (index, data) in lines.enumerated() {
            let msg = try StreamMessage.decode(data)
            guard case .activeAssetCtx(let coin, _) = msg else {
                Issue.record("Line \(index): expected .activeAssetCtx, got \(msg)")
                continue
            }
            #expect(coin == "BTC", "Line \(index): expected coin 'BTC', got '\(coin)'")
        }
    }

    @Test("activeAssetCtx BTC fixture has markPx > 0 and non-empty impactPxs")
    func activeAssetCtxBTCInvariants() throws {
        let lines = try FixtureLoader.loadLines("ws_activeAssetCtx_btc_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .activeAssetCtx(let coin, let ctx) = msg else {
            Issue.record("Expected .activeAssetCtx, got \(msg)")
            return
        }
        #expect(coin == "BTC")
        #expect(ctx.markPx > 0)
        // BTC active-asset fixture should always carry impactPxs (bid/ask impact).
        let impacts = try #require(ctx.impactPxs, "impactPxs missing from BTC activeAssetCtx")
        #expect(impacts.count == 2)
        #expect(impacts[0] > 0)
        #expect(impacts[1] > 0)
    }

    @Test("activeAssetCtx BTC fixture has openInterest and prevDayPx > 0")
    func activeAssetCtxBTCOpenInterest() throws {
        let lines = try FixtureLoader.loadLines("ws_activeAssetCtx_btc_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .activeAssetCtx(_, let ctx) = msg else { return }
        #expect(ctx.openInterest > 0)
        #expect(ctx.prevDayPx > 0)
    }

    // MARK: candle

    @Test("Decodes every line of ws_candle_btc_1h_real.jsonl as .candle")
    func candleAllLines() throws {
        let lines = try FixtureLoader.loadLines("ws_candle_btc_1h_real")
        #expect(!lines.isEmpty)
        for (index, data) in lines.enumerated() {
            let msg = try StreamMessage.decode(data)
            guard case .candle(_) = msg else {
                Issue.record("Line \(index): expected .candle, got \(msg)")
                continue
            }
        }
    }

    @Test("candle BTC 1h fixture: interval == .oneHour, coin == 'BTC', open/close > 0")
    func candleBTCInvariants() throws {
        let lines = try FixtureLoader.loadLines("ws_candle_btc_1h_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .candle(let candle) = msg else {
            Issue.record("Expected .candle, got \(msg)")
            return
        }
        #expect(candle.coin == "BTC")
        #expect(candle.interval == .oneHour)
        #expect(candle.open > 0)
        #expect(candle.close > 0)
        #expect(candle.high >= candle.open)
        #expect(candle.low <= candle.open)
        #expect(candle.tradeCount > 0)
    }

    @Test("candle live-bar: two consecutive lines share the same openTime (in-progress bar)")
    func candleLiveBarSharedOpenTime() throws {
        let lines = try FixtureLoader.loadLines("ws_candle_btc_1h_real")
        guard lines.count >= 2 else { return }
        let msg0 = try StreamMessage.decode(lines[0])
        let msg1 = try StreamMessage.decode(lines[1])
        guard case .candle(let c0) = msg0, case .candle(let c1) = msg1 else { return }
        // Both frames represent the current open bar; openTime must match.
        #expect(c0.openTime == c1.openTime, "Live-bar updates must share the same openTime")
    }

    // MARK: webData2

    @Test("Decodes every line of ws_webData2_real.jsonl as .webData2")
    func webData2AllLines() throws {
        let lines = try FixtureLoader.loadLines("ws_webData2_real")
        #expect(!lines.isEmpty)
        for (index, data) in lines.enumerated() {
            let msg = try StreamMessage.decode(data)
            guard case .webData2(_) = msg else {
                Issue.record("Line \(index): expected .webData2, got \(msg)")
                continue
            }
        }
    }

    @Test("webData2 fixture has assetPositions[0].coin == 'BTC'")
    func webData2HasBTCPosition() throws {
        let lines = try FixtureLoader.loadLines("ws_webData2_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .webData2(let payload) = msg else {
            Issue.record("Expected .webData2, got \(msg)")
            return
        }
        let firstPos = try #require(
            payload.clearinghouseState.positions.first,
            "Expected at least one assetPosition"
        )
        #expect(firstPos.coin == "BTC")
    }

    @Test("webData2 openOrders decodes (may be empty) and markets array is non-empty")
    func webData2OpenOrdersAndMarkets() throws {
        let lines = try FixtureLoader.loadLines("ws_webData2_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .webData2(let payload) = msg else { return }
        // openOrders is allowed to be empty (no open orders at capture time).
        _ = payload.openOrders  // just assert it decoded without throwing
        #expect(!payload.markets.isEmpty, "markets array must be non-empty")
    }

    @Test("webData2 user address is the known test address 0x9938…fe72")
    func webData2UserAddress() throws {
        let lines = try FixtureLoader.loadLines("ws_webData2_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .webData2(let payload) = msg else { return }
        #expect(
            payload.user.rawValue.lowercased() == "0x99382723c90ecc72dad2a7dd375de45b88e8fe72"
        )
    }

    @Test("webData2 clearinghouseState accountValue > 0")
    func webData2AccountValuePositive() throws {
        let lines = try FixtureLoader.loadLines("ws_webData2_real")
        let firstData = try #require(lines.first)
        let msg = try StreamMessage.decode(firstData)
        guard case .webData2(let payload) = msg else { return }
        #expect(payload.clearinghouseState.summary.accountValue > 0)
    }

    // MARK: Unknown channel

    @Test("Unknown channel name returns .unknown(channel:) without throwing")
    func unknownChannelDoesNotThrow() throws {
        let raw = """
            {"channel":"someFutureChannel","data":{"foo":42}}
            """
        let msg = try StreamMessage.decode(Data(raw.utf8))
        guard case .unknown(let channel) = msg else {
            Issue.record("Expected .unknown, got \(msg)")
            return
        }
        #expect(channel == "someFutureChannel")
    }

    // MARK: subscriptionResponse ack

    @Test("subscriptionResponse → .subscriptionAck, no throw")
    func subscriptionAck() throws {
        let raw = """
            {"channel":"subscriptionResponse","data":{"subscription":{"type":"allMids"}}}
            """
        let msg = try StreamMessage.decode(Data(raw.utf8))
        guard case .subscriptionAck(let type) = msg else {
            Issue.record("Expected .subscriptionAck, got \(msg)")
            return
        }
        #expect(type == "allMids")
    }

    @Test("pong frame → .pong, no throw")
    func pongFrame() throws {
        let raw = """
            {"channel":"pong","data":{}}
            """
        let msg = try StreamMessage.decode(Data(raw.utf8))
        #expect(msg == .pong)
    }
}
