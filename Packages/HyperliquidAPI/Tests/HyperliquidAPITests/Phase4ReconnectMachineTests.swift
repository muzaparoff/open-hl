// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import HyperliquidAPI

// MARK: - Helpers

/// A jitter source that always returns a fixed value so tests assert
/// exact delay bounds without depending on real randomness.
private func zeroJitter() -> @Sendable () -> Double { { 0.0 } }
private func maxJitter() -> @Sendable () -> Double { { 0.9999 } }  // just under 1.0

private let epoch = Date(timeIntervalSinceReferenceDate: 0)

// MARK: - Suite

@Suite("ReconnectMachine — pure state-machine unit tests")
struct Phase4ReconnectMachineTests {

    // MARK: Initial state

    @Test("Initial state is .idle")
    func initialStateIsIdle() {
        let m = ReconnectMachine()
        #expect(m.state == .idle)
    }

    // MARK: connectionAttempted

    @Test("connectionAttempted transitions to .connecting")
    func connectionAttemptedTransitionsToConnecting() {
        var m = ReconnectMachine(jitter: zeroJitter())
        m.connectionAttempted()
        #expect(m.state == .connecting)
    }

    // MARK: connectionSucceeded

    @Test("connectionSucceeded from .connecting sets .connected(since:, lastMessageAt:)")
    func connectionSucceededSetsConnected() {
        var m = ReconnectMachine(jitter: zeroJitter())
        m.connectionAttempted()
        m.connectionSucceeded(at: epoch)
        if case .connected(let since, let lastMsg) = m.state {
            #expect(since == epoch)
            #expect(lastMsg == epoch)
        } else {
            Issue.record("Expected .connected, got \(m.state)")
        }
    }

    // MARK: connectionFailed from .idle / .connected

    @Test("First connectionFailed from .idle → .reconnecting(attempt: 1, delay ≈ 1s)")
    func firstFailureFromIdleReconnecting() {
        var m = ReconnectMachine(jitter: zeroJitter())
        let nextAt = m.connectionFailed(at: epoch)
        if case .reconnecting(let attempt, let nextAttemptAt) = m.state {
            #expect(attempt == 1)
            // delay = min(60, 2^0 + 0.0) = 1.0 s
            #expect(nextAttemptAt.timeIntervalSince(epoch) == 1.0)
            #expect(nextAt == nextAttemptAt)
        } else {
            Issue.record("Expected .reconnecting, got \(m.state)")
        }
    }

    @Test("First connectionFailed from .connected → .reconnecting(attempt: 1)")
    func firstFailureFromConnectedReconnecting() {
        var m = ReconnectMachine(jitter: zeroJitter())
        m.connectionAttempted()
        m.connectionSucceeded(at: epoch)
        m.connectionFailed(at: epoch)
        if case .reconnecting(let attempt, _) = m.state {
            #expect(attempt == 1)
        } else {
            Issue.record("Expected .reconnecting, got \(m.state)")
        }
    }

    // MARK: Escalating delays

    @Test("Consecutive failures escalate attempt counter and delay exponentially")
    func escalatingDelays() {
        var m = ReconnectMachine(jitter: zeroJitter())
        // Attempt 1 → delay 1s (2^0)
        // Attempt 2 → delay 2s (2^1)
        // Attempt 3 → delay 4s (2^2)
        // Attempt 4 → delay 8s (2^3)
        // Attempt 5 → delay 16s (2^4)
        // Attempt 6 → delay 32s (2^5)
        let expectedDelays: [Double] = [1, 2, 4, 8, 16, 32]
        for (index, expectedDelay) in expectedDelays.enumerated() {
            let expectedAttempt = index + 1
            m.connectionFailed(at: epoch)
            if case .reconnecting(let attempt, let nextAttemptAt) = m.state {
                #expect(attempt == expectedAttempt)
                #expect(nextAttemptAt.timeIntervalSince(epoch) == expectedDelay)
            } else {
                Issue.record("Attempt \(expectedAttempt): expected .reconnecting, got \(m.state)")
            }
            // Simulate the timer firing and a fresh attempt before failing again.
            m.connectionAttempted()
        }
    }

    // MARK: Cap at 60 s

    @Test("Attempt 7 delay is clamped to 60 s (2^6 = 64 > 60)")
    func delayCappedAt60s() {
        var m = ReconnectMachine(jitter: zeroJitter())
        for _ in 0..<6 {
            m.connectionFailed(at: epoch)
            m.connectionAttempted()
        }
        // Seventh failure: 2^6 = 64 → clamped to 60.
        m.connectionFailed(at: epoch)
        if case .reconnecting(let attempt, let nextAttemptAt) = m.state {
            #expect(attempt == 7)
            #expect(nextAttemptAt.timeIntervalSince(epoch) == ReconnectMachine.maxBackoff)
        } else {
            Issue.record("Expected .reconnecting, got \(m.state)")
        }
    }

    @Test("High-jitter attempt 7 still caps at 60 s (jitter must not break the cap)")
    func highJitterStillCapped() {
        var m = ReconnectMachine(jitter: maxJitter())
        for _ in 0..<6 {
            m.connectionFailed(at: epoch)
            m.connectionAttempted()
        }
        m.connectionFailed(at: epoch)
        if case .reconnecting(_, let nextAttemptAt) = m.state {
            #expect(nextAttemptAt.timeIntervalSince(epoch) <= ReconnectMachine.maxBackoff)
        } else {
            Issue.record("Expected .reconnecting")
        }
    }

    // MARK: Jitter bounds

    @Test("Jitter always in [0, 1) — zero-jitter machine uses exactly the base delay")
    func zeroJitterExactBaseDelay() {
        var m = ReconnectMachine(jitter: zeroJitter())
        m.connectionFailed(at: epoch)
        if case .reconnecting(_, let nextAt) = m.state {
            let delay = nextAt.timeIntervalSince(epoch)
            // 2^0 + 0.0 = 1.0
            #expect(delay == 1.0)
        }
    }

    @Test("Near-max jitter adds just under 1 s to the base delay")
    func nearMaxJitterUnderOneSecond() {
        var m = ReconnectMachine(jitter: maxJitter())
        m.connectionFailed(at: epoch)
        if case .reconnecting(_, let nextAt) = m.state {
            let delay = nextAt.timeIntervalSince(epoch)
            // 2^0 + 0.9999 = 1.9999; must be < 2.0
            #expect(delay >= 1.0)
            #expect(delay < 2.0)
        }
    }

    // MARK: connectionSucceeded resets counter

    @Test("connectionSucceeded resets attempt counter so next failure starts from 1")
    func successResetsAttemptCounter() {
        var m = ReconnectMachine(jitter: zeroJitter())
        // Drive to attempt 3.
        for _ in 0..<3 {
            m.connectionFailed(at: epoch)
            m.connectionAttempted()
        }
        m.connectionSucceeded(at: epoch)
        // One new failure must restart at attempt 1, delay 1s.
        m.connectionFailed(at: epoch)
        if case .reconnecting(let attempt, let nextAt) = m.state {
            #expect(attempt == 1)
            #expect(nextAt.timeIntervalSince(epoch) == 1.0)
        } else {
            Issue.record("Expected .reconnecting after reset, got \(m.state)")
        }
    }

    // MARK: messageReceived

    @Test("messageReceived updates lastMessageAt while preserving since")
    func messageReceivedUpdatesLastMessageAt() {
        var m = ReconnectMachine(jitter: zeroJitter())
        m.connectionAttempted()
        m.connectionSucceeded(at: epoch)
        let later = epoch.addingTimeInterval(5)
        m.messageReceived(at: later)
        if case .connected(let since, let lastMsg) = m.state {
            #expect(since == epoch)
            #expect(lastMsg == later)
        } else {
            Issue.record("Expected .connected after messageReceived, got \(m.state)")
        }
    }

    @Test("messageReceived is a no-op when not .connected")
    func messageReceivedNoOpWhenNotConnected() {
        var m = ReconnectMachine(jitter: zeroJitter())
        // Idle
        m.messageReceived(at: epoch)
        #expect(m.state == .idle)
    }

    // MARK: disconnect

    @Test("disconnect transitions to .disconnected(reason: .userInitiated)")
    func disconnectUserInitiated() {
        var m = ReconnectMachine(jitter: zeroJitter())
        m.connectionAttempted()
        m.connectionSucceeded(at: epoch)
        m.disconnect(reason: .userInitiated)
        #expect(m.state == .disconnected(reason: .userInitiated))
    }

    @Test("disconnect from .reconnecting transitions to .disconnected and resets counter")
    func disconnectFromReconnecting() {
        var m = ReconnectMachine(jitter: zeroJitter())
        for _ in 0..<4 {
            m.connectionFailed(at: epoch)
            m.connectionAttempted()
        }
        m.connectionFailed(at: epoch)
        // Now in .reconnecting(attempt: 5)
        m.disconnect(reason: .backgrounded)
        #expect(m.state == .disconnected(reason: .backgrounded))
        // After disconnect, a fresh connectionFailed should restart from attempt 1.
        m.connectionFailed(at: epoch)
        if case .reconnecting(let attempt, _) = m.state {
            #expect(attempt == 1)
        }
    }

    // MARK: maxBackoff constant

    @Test("maxBackoff is 60 s")
    func maxBackoffIs60() {
        #expect(ReconnectMachine.maxBackoff == 60.0)
    }
}
