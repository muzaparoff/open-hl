// SPDX-License-Identifier: MIT

import Foundation

/// Public connection state observable by the app.
///
/// `URLSessionHyperliquidStream` exposes its current `ConnectionState`
/// (read-only) so `LiveStore` and the UI can render the "Reconnecting…"
/// pill or surface attempt counters in debug builds. The cases mirror
/// the reconnect machine's internal model 1:1 — there's no second
/// translation layer.
///
/// `Equatable` for SwiftUI diffing; `Sendable` because the state crosses
/// the actor boundary when the UI reads it.
public enum ConnectionState: Sendable, Equatable {
    /// No connection attempt has been made yet (or the stream was
    /// `disconnect`-ed by the caller).
    case idle
    /// Currently opening the underlying transport.
    case connecting
    /// Transport is open. `lastMessageAt` is updated on every successful
    /// `receive()`; the UI uses `now - lastMessageAt > 10s` as the
    /// "stale" threshold.
    case connected(since: Date, lastMessageAt: Date)
    /// Backoff in progress. `attempt` is the number of *failed* attempts
    /// so far (incremented on the failure that put us into this state);
    /// `nextAttemptAt` is when the next `connect()` will be tried.
    case reconnecting(attempt: Int, nextAttemptAt: Date)
    /// Terminal-for-now. Either the user backgrounded the app or the
    /// stream was explicitly disconnected.
    case disconnected(reason: DisconnectReason)
}

public enum DisconnectReason: Sendable, Equatable {
    case userInitiated
    case backgrounded
    /// A transport-level error that we are *not* retrying — used when
    /// the reconnect machine surrenders (we don't surrender in v1, but
    /// the case exists for symmetry / future use).
    case transport(String)
}

/// Pure reconnect state machine.
///
/// **Pure** = no `URLSession`, no `Task.sleep`, no `Date()`. All time
/// inputs are passed in by the caller (the stream actor); all outputs
/// are pure values. This lets `qa-automation` test the schedule with
/// a fixed clock and no async ceremony.
///
/// **Schedule.** `min(60, 2^attempt + jitter)` seconds, where `jitter`
/// is `Double.random(in: 0..<1)` evaluated at the moment of failure.
/// The cap kicks in at attempt 6 (2^6 = 64 > 60). The jitter avoids
/// thundering-herd reconnect from many devices after an outage.
///
/// **Reset on success.** `connectionSucceeded(at:)` zeroes the attempt
/// counter — a long-lived healthy connection followed by a single drop
/// reconnects fast, not with a 60-s wait.
///
/// **Transitions:**
///
/// ```
/// idle ──connectionAttempted──▶ connecting
/// connecting ──connectionSucceeded──▶ connected
/// connecting ──connectionFailed──▶ reconnecting
/// connected  ──connectionFailed──▶ reconnecting
/// reconnecting ──connectionAttempted──▶ connecting    (when timer fires)
/// any ──disconnect──▶ disconnected
/// ```
///
/// The machine does not own a timer; the stream actor reads
/// `state.nextAttemptAt` (via pattern match) and `Task.sleep`s to it.
public struct ReconnectMachine: Sendable {

    /// Hard cap on the backoff schedule. Hyperliquid does not document
    /// a reconnect ceiling; 60s is a UI-friendly compromise.
    public static let maxBackoff: TimeInterval = 60

    public private(set) var state: ConnectionState

    /// Number of *consecutive* failures. Reset on `connectionSucceeded`.
    /// Held separately from `state.attempt` so it survives a
    /// `connectionAttempted` transition back to `.connecting`.
    private var consecutiveFailures: Int

    /// Injected for testability. Defaults to the system-random jitter.
    /// `Sendable` because closures captured into a `Sendable` struct
    /// must themselves be `@Sendable`.
    private let jitter: @Sendable () -> Double

    public init(jitter: @Sendable @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.state = .idle
        self.consecutiveFailures = 0
        self.jitter = jitter
    }

    /// Called by the stream actor when it begins a connection attempt
    /// (either the first one from `.idle` or one fired by the
    /// reconnect timer from `.reconnecting`).
    public mutating func connectionAttempted() {
        state = .connecting
    }

    /// Called when the transport reports a successful connection (the
    /// first frame arrived, or `URLSessionWebSocketTask.resume()`
    /// returned without throwing — caller's choice).
    public mutating func connectionSucceeded(at now: Date) {
        consecutiveFailures = 0
        state = .connected(since: now, lastMessageAt: now)
    }

    /// Called when a message arrives on the open connection. Updates
    /// the "last seen" timestamp the UI consults for the 10-s stale
    /// indicator. No-op if not in `.connected`.
    public mutating func messageReceived(at now: Date) {
        guard case .connected(let since, _) = state else { return }
        state = .connected(since: since, lastMessageAt: now)
    }

    /// Called when the transport fails (either at connect time or
    /// mid-stream). Returns the absolute `Date` at which the next
    /// attempt should fire. Caller `Task.sleep`s until then and then
    /// calls `connectionAttempted()`.
    @discardableResult
    public mutating func connectionFailed(at now: Date) -> Date {
        consecutiveFailures += 1
        let baseSeconds = pow(2.0, Double(consecutiveFailures - 1))
        let delay = min(Self.maxBackoff, baseSeconds + jitter())
        let next = now.addingTimeInterval(delay)
        state = .reconnecting(attempt: consecutiveFailures, nextAttemptAt: next)
        return next
    }

    /// Called by the stream actor when the app or user explicitly tears
    /// the stream down (scene phase → background, or `disconnect()`).
    public mutating func disconnect(reason: DisconnectReason) {
        consecutiveFailures = 0
        state = .disconnected(reason: reason)
    }
}
