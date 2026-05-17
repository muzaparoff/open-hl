// SPDX-License-Identifier: MIT

import Foundation
import OSLog
import OpenHLCore

private let logger = Logger(subsystem: "xyz.hyperliquid.openhl", category: "HyperliquidStream")

/// The protocol view-model-adjacent code depends on. The app's
/// `LiveStore` (the actor that bridges WS events into `@Observable`
/// view-model state) holds an `any HyperliquidStream`. Tests inject a
/// fake stream that emits scripted values.
///
/// Every method returns an `AsyncStream<T>`. Multiple subscribers per
/// channel are supported — each call to `mids()` returns a fresh
/// stream and is fanned-out independently. The stream actor owns the
/// underlying transport; subscribers do not.
///
/// **Buffer policy:** each per-channel continuation has a tailored
/// buffering policy applied at registration time (latest-wins for the
/// price-update channels, latest-bar-wins for candle, latest-snapshot
/// for webData2). Subscribers that fall behind always see the freshest
/// value, never a backlog.
public protocol HyperliquidStream: Sendable {

    /// Subscribe to the `allMids` channel. Emits a `[String: Decimal]`
    /// mids dictionary (~1Hz). Latest-wins buffering — slow subscribers
    /// always see the freshest snapshot.
    func mids() async -> AsyncStream<[String: Decimal]>

    /// Subscribe to `activeAssetCtx` for one coin. Emits the full
    /// `AssetContext` per tick. Latest-wins per coin.
    func activeAssetCtx(coin: String) async -> AsyncStream<AssetContext>

    /// Subscribe to live candles for one coin+interval. Emits the
    /// current-bar update on every tick (the bar shares its
    /// `openTime` until it closes; on close, the next emission is a
    /// new bar). Latest-wins for the in-flight bar.
    func candle(coin: String, interval: CandleInterval) async -> AsyncStream<Candle>

    /// Subscribe to the address-scoped `webData2` snapshot. Emits a
    /// complete account dump per message (positions + orders + market
    /// list). Latest-wins.
    func webData2(for user: Address) async -> AsyncStream<WebData2>

    /// Initiate a connection. `LiveStore` calls this on scene-phase `.active`
    /// to (re-)connect after a background period. Idempotent: calling
    /// `connect()` while already connected is a no-op.
    func connect() async

    /// Cleanly tear down the underlying transport and all subscribers.
    /// `LiveStore` calls this on scene-phase `.background`.
    func disconnect() async

    /// Current connection state, for the UI to render the
    /// "Reconnecting…" pill.
    var connectionState: ConnectionState { get async }
}

// MARK: - URLSessionHyperliquidStream

/// Production `HyperliquidStream`. One instance per app, constructed
/// in the composition root.
///
/// **Why an actor.** The stream maintains shared mutable state — the
/// transport handle, the active subscription set, the reconnect machine,
/// the receive task — that is touched from at least three concurrent
/// contexts: the composition root (`connect`/`disconnect`), every view's
/// `.task` block (subscribe), and the internal receive loop (dispatch).
/// An actor serializes all of that without `NSLock` ceremony and is
/// implicitly `Sendable`.
///
/// **Lifecycle.**
/// - `LiveStore` constructs the stream once and never tears it down
///   short of process exit.
/// - On scene `.active` the stream `connect()`s — it walks the active
///   subscriptions and re-sends each subscribe frame after the socket
///   opens.
/// - On scene `.background` the stream `disconnect()`s — the receive
///   task is cancelled, the transport closed, continuations remain
///   registered (so re-subscribers don't have to re-call `mids()`).
/// - On transport failure (mid-stream throw from `receive()`) the
///   reconnect machine schedules the next attempt; the stream
///   `Task.sleep`s and tries again. Re-subscription is automatic.
///
/// **Address re-subscription.** `webData2(for:)` is the only
/// address-scoped channel. If `LiveStore` switches addresses (the user
/// enters a new wallet), it tears down its existing `webData2` stream
/// (the continuation is cancelled when the surrounding `.task` ends),
/// and calls `webData2(for: newAddress)` afresh. The actor de-duplicates
/// subscription keys, so a second subscribe to the same address reuses
/// the wire subscription with zero extra traffic.
public actor URLSessionHyperliquidStream: HyperliquidStream {

    // MARK: Dependencies

    private let url: URL
    private let transportFactory: @Sendable () -> any WebSocketTransport
    private let clock: any Clock

    // MARK: Connection state

    private var transport: (any WebSocketTransport)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnect: ReconnectMachine

    /// Subscriptions the actor *wants* to be live. Each entry's key is
    /// `SubscriptionRequest.subscriptionKey`. Re-sent on every
    /// successful reconnect.
    private var activeSubscriptions: [String: SubscriptionRequest] = [:]

    // MARK: Subscriber bookkeeping

    /// Multi-subscriber fan-out. One dictionary per channel kind, keyed
    /// by a per-subscription scoping value (coin for activeAssetCtx,
    /// coin+interval for candle, etc.). The inner `[UUID: Continuation]`
    /// is the broadcaster.
    private var midsSubscribers: [UUID: AsyncStream<[String: Decimal]>.Continuation] = [:]
    private var activeAssetCtxSubscribers: [String: [UUID: AsyncStream<AssetContext>.Continuation]] = [:]
    private var candleSubscribers: [String: [UUID: AsyncStream<Candle>.Continuation]] = [:]
    private var webData2Subscribers: [Address: [UUID: AsyncStream<WebData2>.Continuation]] = [:]

    // MARK: Init

    public init(
        url: URL = URL(string: "wss://api.hyperliquid.xyz/ws")!,
        clock: any Clock = SystemClock(),
        transportFactory: (@Sendable () -> any WebSocketTransport)? = nil
    ) {
        self.url = url
        self.clock = clock
        if let provided = transportFactory {
            self.transportFactory = provided
        } else {
            self.transportFactory = { URLSessionWebSocketTransport(url: url) }
        }
        self.reconnect = ReconnectMachine()
    }

    public var connectionState: ConnectionState {
        reconnect.state
    }

    // MARK: Public API — subscribe

    public func mids() -> AsyncStream<[String: Decimal]> {
        let token = UUID()
        let stream = AsyncStream<[String: Decimal]>(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            midsSubscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeMidsSubscriber(token: token)
                }
            }
        }
        ensureSubscription(.allMids)
        return stream
    }

    public func activeAssetCtx(coin: String) -> AsyncStream<AssetContext> {
        let token = UUID()
        let coinKey = coin
        let stream = AsyncStream<AssetContext>(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            var bucket = activeAssetCtxSubscribers[coinKey] ?? [:]
            bucket[token] = continuation
            activeAssetCtxSubscribers[coinKey] = bucket
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeActiveAssetCtxSubscriber(coin: coinKey, token: token)
                }
            }
        }
        ensureSubscription(.activeAssetCtx(coin: coin))
        return stream
    }

    public func candle(coin: String, interval: CandleInterval) -> AsyncStream<Candle> {
        let token = UUID()
        let key = "\(coin):\(interval.rawValue)"
        let stream = AsyncStream<Candle>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var bucket = candleSubscribers[key] ?? [:]
            bucket[token] = continuation
            candleSubscribers[key] = bucket
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeCandleSubscriber(key: key, token: token)
                }
            }
        }
        ensureSubscription(.candle(coin: coin, interval: interval))
        return stream
    }

    public func webData2(for user: Address) -> AsyncStream<WebData2> {
        let token = UUID()
        let key = user
        let stream = AsyncStream<WebData2>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            var bucket = webData2Subscribers[key] ?? [:]
            bucket[token] = continuation
            webData2Subscribers[key] = bucket
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeWebData2Subscriber(user: key, token: token)
                }
            }
        }
        ensureSubscription(.webData2(user: user))
        return stream
    }

    // MARK: Subscriber removal (actor-isolated)

    private func removeMidsSubscriber(token: UUID) {
        midsSubscribers.removeValue(forKey: token)
    }

    private func removeActiveAssetCtxSubscriber(coin: String, token: UUID) {
        if var bucket = activeAssetCtxSubscribers[coin] {
            bucket.removeValue(forKey: token)
            if bucket.isEmpty {
                activeAssetCtxSubscribers.removeValue(forKey: coin)
            } else {
                activeAssetCtxSubscribers[coin] = bucket
            }
        }
    }

    private func removeCandleSubscriber(key: String, token: UUID) {
        if var bucket = candleSubscribers[key] {
            bucket.removeValue(forKey: token)
            if bucket.isEmpty {
                candleSubscribers.removeValue(forKey: key)
            } else {
                candleSubscribers[key] = bucket
            }
        }
    }

    private func removeWebData2Subscriber(user: Address, token: UUID) {
        if var bucket = webData2Subscribers[user] {
            bucket.removeValue(forKey: token)
            if bucket.isEmpty {
                webData2Subscribers.removeValue(forKey: user)
            } else {
                webData2Subscribers[user] = bucket
            }
        }
    }

    // MARK: Subscription bookkeeping

    /// Record a desired subscription and, if the transport is connected,
    /// send the subscribe frame. Idempotent on `subscriptionKey`.
    private func ensureSubscription(_ request: SubscriptionRequest) {
        let key = request.subscriptionKey
        if activeSubscriptions[key] != nil { return }
        activeSubscriptions[key] = request

        switch reconnect.state {
        case .connected:
            Task { [weak self] in await self?.sendSubscribe(request) }
        case .idle, .disconnected:
            // Bring the connection up; subscriptions will be flushed once connected.
            Task { [weak self] in await self?.connect() }
        case .connecting, .reconnecting:
            // The connect path's success branch flushes activeSubscriptions.
            break
        }
    }

    private func sendSubscribe(_ request: SubscriptionRequest) async {
        guard let transport else { return }
        do {
            let data = try JSONEncoder().encode(request)
            try await transport.send(data)
        } catch {
            logger.error(
                "subscribe failed for \(request.subscriptionKey, privacy: .public): \(error, privacy: .public)"
            )
        }
    }

    // MARK: Connection lifecycle

    /// Bring the transport up and (re-)send every active subscription.
    /// Idempotent: calling `connect()` while already connected is a
    /// no-op.
    public func connect() async {
        switch reconnect.state {
        case .connected, .connecting:
            return
        default:
            break
        }
        reconnect.connectionAttempted()
        let transport = transportFactory()
        self.transport = transport
        do {
            try await transport.connect()
            reconnect.connectionSucceeded(at: clock.now())
            for request in activeSubscriptions.values {
                await sendSubscribe(request)
            }
            startReceiveLoop()
        } catch {
            logger.error("connect failed: \(error, privacy: .public)")
            handleTransportFailure()
        }
    }

    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        await transport?.close()
        transport = nil
        reconnect.disconnect(reason: .backgrounded)
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        guard let transport else { return }
        while !Task.isCancelled {
            do {
                let data = try await transport.receive()
                reconnect.messageReceived(at: clock.now())
                await dispatch(data)
            } catch {
                if Task.isCancelled { return }
                logger.notice("receive loop error: \(error, privacy: .public)")
                handleTransportFailure()
                return
            }
        }
    }

    // MARK: Reconnect

    private func handleTransportFailure() {
        let next = reconnect.connectionFailed(at: clock.now())
        Task { [weak self] in
            await self?.transport?.close()
        }
        transport = nil
        receiveTask?.cancel()
        receiveTask = nil

        reconnectTask?.cancel()
        let delay = next.timeIntervalSince(clock.now())
        reconnectTask = Task { [weak self] in
            if delay > 0 {
                let ns = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
            if Task.isCancelled { return }
            await self?.connect()
        }
    }

    // MARK: Dispatch

    private func dispatch(_ data: Data) async {
        let message: StreamMessage
        do {
            message = try StreamMessage.decode(data)
        } catch {
            logger.error("StreamMessage.decode failed: \(error, privacy: .public)")
            return
        }
        switch message {
        case .mids(let dict):
            for cont in midsSubscribers.values {
                cont.yield(dict)
            }
        case .activeAssetCtx(let coin, let ctx):
            if let bucket = activeAssetCtxSubscribers[coin] {
                for cont in bucket.values { cont.yield(ctx) }
            }
        case .candle(let candle):
            let key = "\(candle.coin):\(candle.interval.rawValue)"
            if let bucket = candleSubscribers[key] {
                for cont in bucket.values { cont.yield(candle) }
            }
        case .webData2(let payload):
            if let bucket = webData2Subscribers[payload.user] {
                for cont in bucket.values { cont.yield(payload) }
            }
        case .subscriptionAck(let type):
            logger.debug("subscriptionAck: \(type, privacy: .public)")
        case .error(let msg):
            logger.error("server error frame: \(msg, privacy: .public)")
        case .pong:
            break
        case .unknown(let channel):
            logger.notice("unknown WS channel: \(channel, privacy: .public)")
        }
    }
}
