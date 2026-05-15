// SPDX-License-Identifier: MIT

import Foundation

/// Abstracts "what time is it now" for testability. Anything in
/// `OpenHLCore`, `HyperliquidAPI`, or view models that needs the wall
/// clock takes a `Clock` by constructor injection rather than calling
/// `Date()` directly.
///
/// Phase 1 use cases:
/// - Stamping the snapshot's `fetchedAt` so the UI can render "Updated 12s
///   ago" (and tests can assert the value without sleeping).
/// - Backoff scheduling in the future (Phase 3 WebSocket reconnect).
///
/// We deliberately do not use Swift's standard-library `Clock` protocol
/// (which is built around `Duration` and `InstantProtocol`). We need
/// `Date` for display and for SwiftUI's `Date`-relative APIs, and the
/// stdlib protocol adds ceremony with no payoff here. If a future need
/// for monotonic clocks emerges, we add a second protocol; we do not
/// retrofit this one.
///
/// `Sendable` so it can be held by `Sendable` clients (the API client,
/// view models) without isolation pain.
public protocol Clock: Sendable {
    func now() -> Date
}

/// Production implementation: returns `Date()`.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date {
        Date()
    }
}

/// Test implementation: returns a fixed `Date`, settable from tests.
/// Internally synchronized so tests can mutate from any actor.
public final class FixedClock: Clock, @unchecked Sendable {
    private var _current: Date
    private let lock = NSLock()

    public init(_ initial: Date) {
        _current = initial
    }

    public func now() -> Date {
        lock.withLock { _current }
    }

    public func set(_ date: Date) {
        lock.withLock { _current = date }
    }

    public func advance(by interval: TimeInterval) {
        lock.withLock { _current = _current.addingTimeInterval(interval) }
    }
}
