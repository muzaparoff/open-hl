// SPDX-License-Identifier: MIT

import Foundation
import HyperliquidAPI
import OSLog
import OpenHLCore
import SwiftUI

private let logger = Logger(subsystem: "xyz.hyperliquid.openhl", category: "LiveStore")

// MARK: - Connection state enum for UI

/// Simplified connection state the StaleIndicatorView reads.
/// Derived from the underlying `ConnectionState` plus a staleness check.
public enum LiveStoreConnectionState: Sendable, Equatable {
    /// Transport up and data is fresh (message within the last 10 s).
    case connected
    /// Connected but no message in ≥10 s, or in the process of reconnecting.
    case stale
    /// Explicitly disconnected (backgrounded). Pill hidden.
    case disconnected
}

// MARK: - LiveStore

/// App-level coordinator that bridges `HyperliquidStream` events into
/// `@Observable` view-model state on `@MainActor`.
///
/// **One instance per app.** Constructed in `OpenHLApp.init()`, injected
/// into the view hierarchy. Views call `sceneDidActivate()` /
/// `sceneDidBackground()` (driven by `@Environment(\.scenePhase)`) to
/// manage the connection lifecycle.
///
/// **Channel fan-out.** The store subscribes to each channel at most
/// once on the stream. Each call to `mids()` / `activeAssetCtx(coin:)` /
/// etc. returns a fresh `AsyncStream` that receives the same messages — the
/// underlying `URLSessionHyperliquidStream` performs the fan-out. The store
/// does not duplicate messages itself.
///
/// **Stale threshold.** If the stream is `.connected` but no message has
/// arrived for ≥10 s, `connectionState` transitions to `.stale`. The
/// stream's reconnect machine handles the actual reconnect; we just surface
/// the stale indicator so the user sees feedback immediately.
@MainActor
@Observable
public final class LiveStore {

    // MARK: - Published state

    /// UI-visible connection state. Drives `StaleIndicatorView`.
    public private(set) var connectionState: LiveStoreConnectionState = .disconnected

    // MARK: - Dependencies

    private let stream: any HyperliquidStream
    private let clock: any Clock

    // MARK: - Internal

    /// Task that polls `stream.connectionState` every second to compute
    /// derived `LiveStoreConnectionState` (stale threshold check).
    private var staleCheckTask: Task<Void, Never>?

    // MARK: - Init

    public init(stream: any HyperliquidStream, clock: any Clock = SystemClock()) {
        self.stream = stream
        self.clock = clock
    }

    // MARK: - Scene-phase lifecycle

    /// Call when `scenePhase == .active`. Reconnects the stream and restarts
    /// the stale-threshold polling loop.
    public func sceneDidActivate() {
        Task { [stream] in
            await stream.connect()
        }
        startStaleCheckLoop()
    }

    /// Call when `scenePhase == .background`. Cleanly tears down the transport.
    public func sceneDidBackground() {
        staleCheckTask?.cancel()
        staleCheckTask = nil
        Task { [stream] in
            await stream.disconnect()
        }
        connectionState = .disconnected
    }

    // MARK: - Channel projections

    /// Returns a fresh `AsyncStream` of mid-price dictionaries.
    /// Multiple concurrent callers each receive the same messages (fan-out
    /// is performed by `URLSessionHyperliquidStream`).
    public func mids() async -> AsyncStream<[String: Decimal]> {
        await stream.mids()
    }

    /// Returns a fresh `AsyncStream` of `AssetContext` updates for `coin`.
    public func activeAssetCtx(coin: String) async -> AsyncStream<AssetContext> {
        await stream.activeAssetCtx(coin: coin)
    }

    /// Returns a fresh `AsyncStream` of live candle ticks for `coin`+`interval`.
    public func candle(coin: String, interval: CandleInterval) async -> AsyncStream<Candle> {
        await stream.candle(coin: coin, interval: interval)
    }

    /// Returns a fresh `AsyncStream` of `WebData2` account snapshots for `address`.
    public func webData2(for address: Address) async -> AsyncStream<WebData2> {
        await stream.webData2(for: address)
    }

    // MARK: - Stale check loop

    private func startStaleCheckLoop() {
        staleCheckTask?.cancel()
        staleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateConnectionState()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func updateConnectionState() async {
        let raw = await stream.connectionState
        let now = clock.now()
        let staleThreshold: TimeInterval = 10

        switch raw {
        case .connected(_, let lastMessageAt):
            let age = now.timeIntervalSince(lastMessageAt)
            connectionState = age >= staleThreshold ? .stale : .connected
        case .reconnecting:
            connectionState = .stale
        case .connecting:
            // Treat connecting as stale — we don't have live prices yet.
            connectionState = .stale
        case .idle, .disconnected:
            connectionState = .disconnected
        }
    }
}

// MARK: - StubHyperliquidStream (preview + UI test)

#if DEBUG
    /// A scripted `HyperliquidStream` that never touches the network. Emits
    /// BTC ticking ±$1 every second on `mids()`. Other channels emit a
    /// single snapshot then stay silent. Used in previews and UI tests so
    /// the live-price path is exercised without a real WebSocket.
    public final class StubHyperliquidStream: HyperliquidStream, @unchecked Sendable {

        private let lock = NSLock()
        private var _state: ConnectionState = .idle

        public init() {}

        public var connectionState: ConnectionState {
            lock.withLock { _state }
        }

        public func connect() async {
            lock.withLock { _state = .connected(since: Date(), lastMessageAt: Date()) }
        }

        public func disconnect() async {
            lock.withLock { _state = .disconnected(reason: .backgrounded) }
        }

        public func mids() async -> AsyncStream<[String: Decimal]> {
            AsyncStream<[String: Decimal]> { continuation in
                Task {
                    var base = Decimal(string: "62401.50")!
                    var tick: Int = 0
                    while !Task.isCancelled {
                        let delta: Decimal = tick.isMultiple(of: 2) ? 1 : -1
                        base += delta
                        tick += 1
                        // Minimal dict — Markets list only needs the coins it knows about.
                        continuation.yield([
                            "BTC": base,
                            "ETH": Decimal(string: "3194.50")! + delta,
                            "SOL": Decimal(string: "144.30")! + delta * Decimal(string: "0.1")!,
                        ])
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    continuation.finish()
                }
            }
        }

        public func activeAssetCtx(coin: String) async -> AsyncStream<AssetContext> {
            AsyncStream<AssetContext> { continuation in
                Task {
                    var tick: Int = 0
                    while !Task.isCancelled {
                        let delta: Decimal = tick.isMultiple(of: 2) ? 1 : -1
                        let ctx = AssetContext(
                            funding: Decimal(string: "0.0001")!,
                            openInterest: Decimal(string: "1234.5")! + delta,
                            prevDayPx: Decimal(string: "61641.00")!,
                            markPx: Decimal(string: "62401.50")! + delta,
                            midPx: Decimal(string: "62401.50")! + delta,
                            oraclePx: Decimal(string: "62400.00")!,
                            premium: nil,
                            dayNotionalVolume: Decimal(string: "830000000")!,
                            dayBaseVolume: nil,
                            impactPxs: nil
                        )
                        continuation.yield(ctx)
                        tick += 1
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    continuation.finish()
                }
            }
        }

        public func candle(coin: String, interval: CandleInterval) async -> AsyncStream<Candle> {
            AsyncStream<Candle> { continuation in
                Task {
                    let step: TimeInterval
                    switch interval {
                    case .oneHour: step = 3600
                    case .fourHour: step = 14400
                    case .oneDay: step = 86400
                    case .oneWeek: step = 604_800
                    default: step = 3600
                    }
                    let now = Date()
                    let openTime = now.addingTimeInterval(-step)
                    var close = Decimal(string: "62401.50")!
                    var tick: Int = 0
                    while !Task.isCancelled {
                        let delta: Decimal = tick.isMultiple(of: 2) ? 1 : -1
                        close += delta
                        tick += 1
                        let c = Candle(
                            coin: coin,
                            interval: interval,
                            openTime: openTime,
                            closeTime: now,
                            open: Decimal(string: "62380.00")!,
                            close: close,
                            high: close + 50,
                            low: close - 50,
                            volume: 1000,
                            tradeCount: 200
                        )
                        continuation.yield(c)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    continuation.finish()
                }
            }
        }

        public func webData2(for user: Address) async -> AsyncStream<WebData2> {
            // webData2 requires building a realistic payload; for previews
            // we emit one snapshot immediately then keep the stream alive.
            AsyncStream<WebData2> { continuation in
                Task {
                    var tick: Int = 0
                    while !Task.isCancelled {
                        let delta: Decimal = tick.isMultiple(of: 2) ? 10 : -10
                        tick += 1
                        let summary = ClearinghouseState.AccountSummary(
                            accountValue: Decimal(string: "12453.21")! + delta,
                            totalNotionalPosition: Decimal(string: "9800.00")!,
                            totalRawUSD: Decimal(string: "12000.00")!,
                            totalMarginUsed: Decimal(string: "4201.10")!,
                            withdrawable: Decimal(string: "8252.11")! + delta
                        )
                        let state = ClearinghouseState(
                            summary: summary,
                            positions: [],
                            serverTime: Date(),
                            fetchedAt: Date()
                        )
                        let payload = WebData2(
                            user: user,
                            serverTime: Date(),
                            clearinghouseState: state,
                            openOrders: [],
                            markets: []
                        )
                        continuation.yield(payload)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    continuation.finish()
                }
            }
        }
    }
#endif
