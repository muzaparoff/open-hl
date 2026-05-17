// SPDX-License-Identifier: MIT

import Foundation

/// The wire-level seam between `URLSessionHyperliquidStream` and the OS.
///
/// **Why a protocol?** The stream actor owns subscription state, message
/// fan-out, and the reconnect machine. None of that should depend on a
/// real socket to be exercised. The protocol takes the smallest possible
/// shape that still expresses the four operations the stream actor needs:
/// connect, send a subscription frame, receive one frame, close.
///
/// **Why `Data` and not `URLSessionWebSocketTask.Message`?** The stream
/// actor decodes JSON from text frames; the wire payloads are always
/// JSON-as-UTF8 (verified via the four real captures). Mapping
/// `.string`/`.data` to `Data` at the transport boundary keeps the
/// `URLSessionWebSocketTask` API surface out of the stream's tests, which
/// otherwise would need to fabricate `URLSessionWebSocketTask.Message`
/// values (the type has no public initializer). The stub transport in
/// tests pushes raw `Data` objects in/out; the production transport
/// performs the `.string`/`.data` coercion.
///
/// **Error model.** Transport-level failures (the socket closed, a
/// `URLError`, EOF) surface as a throw from `receive()` or `send(_:)`.
/// The stream actor catches them, marks the connection as failed, and
/// hands control to the reconnect machine. The protocol itself does not
/// model "is connected"; the stream actor owns connection state.
///
/// **Sendable.** `Sendable` because the stream actor calls into the
/// transport across actor isolation. The production implementation is an
/// actor (which is implicitly `Sendable`); the test stub is a final
/// class with internal locking, `@unchecked Sendable`.
public protocol WebSocketTransport: Sendable {

    /// Opens the underlying socket. Calling `connect()` on an already-
    /// open transport is a programmer error — the stream actor only ever
    /// calls it once per transport instance.
    func connect() async throws

    /// Sends a frame. Production sends as a UTF-8 text frame.
    func send(_ data: Data) async throws

    /// Awaits the next inbound frame and returns it as `Data`. Binary
    /// and text frames are both returned as `Data`. The stream actor
    /// loops calling this; cancellation of the surrounding `Task`
    /// cancels the in-flight `receive`.
    func receive() async throws -> Data

    /// Closes the socket. Idempotent: calling `close()` on an already-
    /// closed transport is a no-op (production logs a debug message;
    /// the stub records the call).
    func close() async
}

// MARK: - Production: URLSessionWebSocketTask

/// Production transport. Wraps a single `URLSessionWebSocketTask`.
///
/// **One-shot per instance.** The actor is constructed with the target
/// URL; `connect()` builds and resumes a task; `close()` cancels and
/// nils it. To reconnect, the stream actor constructs a fresh
/// `URLSessionWebSocketTransport` — there is no internal reconnect.
/// This keeps the transport state machine trivial (idle → connected →
/// closed, no resurrection) and pushes reconnection into the one place
/// it belongs: the stream actor's `ReconnectMachine`.
///
/// **Why a private `URLSession`.** Sharing the REST `URLSession` would
/// couple the WebSocket lifecycle to per-request timeouts that make no
/// sense for a long-lived socket. The transport owns its own session
/// configured for "no timeout, wait for connectivity, no cache."
public actor URLSessionWebSocketTransport: WebSocketTransport {

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL = URL(string: "wss://api.hyperliquid.xyz/ws")!) {
        let config = URLSessionConfiguration.default
        // No request/resource timeouts on a long-lived socket; reconnect
        // is the stream actor's job, not the OS's.
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.url = url
        self.session = URLSession(configuration: config)
    }

    public func connect() async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    public func send(_ data: Data) async throws {
        guard let task else {
            throw TransportError.notConnected
        }
        // Hyperliquid's WS protocol is JSON-as-text. Send as text so any
        // upstream proxy that distinguishes binary from text frames does
        // not reject us.
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    public func receive() async throws -> Data {
        guard let task else {
            throw TransportError.notConnected
        }
        let message = try await task.receive()
        switch message {
        case .string(let s):
            return Data(s.utf8)
        case .data(let d):
            return d
        @unknown default:
            throw TransportError.unknownFrame
        }
    }

    public func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public enum TransportError: Error, Sendable, Equatable {
        case notConnected
        case unknownFrame
    }
}

// MARK: - Test stub

/// A test double that lets `qa-automation` script a sequence of inbound
/// frames and capture sent frames.
///
/// **Why a class, not an actor.** Tests build the stub synchronously,
/// pre-load it with frames, hand it to the stream actor, then poll its
/// captured-sends array from outside the actor. A class with an
/// `NSLock` is simpler than awaiting into an actor for every assertion.
/// `@unchecked Sendable` is justified by the lock.
///
/// **Failure injection.** Push a `.failure(error)` into `inbound` to
/// have `receive()` throw on that pull. The stream actor will treat
/// that as a transport failure and hand to the reconnect machine.
public final class StubWebSocketTransport: WebSocketTransport, @unchecked Sendable {

    public enum ScriptedReceive: Sendable {
        case data(Data)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var pendingReceives: [ScriptedReceive] = []
    private var receiveWaiters: [CheckedContinuation<ScriptedReceive, Never>] = []
    private(set) public var sentFrames: [Data] = []
    private(set) public var connectCallCount = 0
    private(set) public var closeCallCount = 0
    private var isClosed = false

    public init() {}

    /// Push a frame onto the inbound queue. If a `receive()` call is
    /// already waiting, it is resumed immediately.
    public func enqueueReceive(_ data: Data) {
        let waiter: CheckedContinuation<ScriptedReceive, Never>? = lock.withLock {
            if !receiveWaiters.isEmpty {
                return receiveWaiters.removeFirst()
            } else {
                pendingReceives.append(.data(data))
                return nil
            }
        }
        waiter?.resume(returning: .data(data))
    }

    /// Push a failure onto the inbound queue. The next `receive()`
    /// throws this error.
    public func enqueueFailure(_ error: any Error) {
        let waiter: CheckedContinuation<ScriptedReceive, Never>? = lock.withLock {
            if !receiveWaiters.isEmpty {
                return receiveWaiters.removeFirst()
            } else {
                pendingReceives.append(.failure(error))
                return nil
            }
        }
        waiter?.resume(returning: .failure(error))
    }

    public func connect() async throws {
        lock.withLock {
            connectCallCount += 1
            isClosed = false
        }
    }

    public func send(_ data: Data) async throws {
        lock.withLock { sentFrames.append(data) }
    }

    public func receive() async throws -> Data {
        let scripted: ScriptedReceive = await withCheckedContinuation { cont in
            lock.withLock {
                if !pendingReceives.isEmpty {
                    let next = pendingReceives.removeFirst()
                    cont.resume(returning: next)
                } else {
                    receiveWaiters.append(cont)
                }
            }
        }
        switch scripted {
        case .data(let d): return d
        case .failure(let e): throw e
        }
    }

    public func close() async {
        let waiters: [CheckedContinuation<ScriptedReceive, Never>] = lock.withLock {
            closeCallCount += 1
            isClosed = true
            let snapshot = receiveWaiters
            receiveWaiters.removeAll()
            return snapshot
        }
        // Fail any in-flight receivers so the stream actor exits its loop.
        for w in waiters {
            w.resume(returning: .failure(StubClosed()))
        }
    }

    public struct StubClosed: Error, Sendable, Equatable {}
}
