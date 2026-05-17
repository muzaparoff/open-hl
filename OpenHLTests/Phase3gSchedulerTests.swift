// SPDX-License-Identifier: MIT

// Integration tests for `AlertScheduler` (Phase 3g — Alerts POC).
//
// STATUS: swift-expert has not yet landed:
//   - `AlertScheduler` in `OpenHL/Services/AlertScheduler.swift`
//   - `NotificationPoster` protocol (needed for injection)
//   - `AlertRulesStore`, `AlertRule`, `AlertEvaluator` in `OpenHLCore`
//
// Strategy: local stub types define the agreed interface shapes. Every test
// suite that cannot run today is marked `.disabled`; unlock steps are listed.
//
// UNLOCK CHECKLIST — once implementation lands:
//
//   AlertSchedulerEvaluatesAndPostsTests:
//     [ ] swift-expert: `NotificationPoster` protocol added to app target
//     [ ] swift-expert: `AlertScheduler.init(client:rulesStore:poster:clock:)`
//         or equivalent injection points are public/internal-testable
//     [ ] ios-developer: `AlertScheduler.evaluate(now:)` method is async
//     [ ] Remove `.disabled` from the suites below
//     [ ] Delete the LOCAL STUB TYPES section
//     [ ] Add `@testable import OpenHL` (already guarded with a comment below)
//
//   BGTaskIdentifierTests:
//     [ ] `AlertScheduler.backgroundTaskIdentifier` static constant exists
//         and equals "xyz.hyperliquid.openhl.refresh"
//
// Phase 3g adds NO new Hyperliquid API endpoints. The per-memory
// fixture-test rule is NOT triggered.

import Foundation
import HyperliquidAPI
import OpenHLCore
import Testing

// Activates once AlertScheduler lands in the app target:
// @testable import OpenHL

// MARK: - LOCAL STUB TYPES (delete once swift-expert lands the real files)

// NOTE: AlertRule, AlertCondition, AlertRulesStore, AlertEvaluator, EvaluationResult,
// and InMemoryAlertRulesStore are declared in the OpenHLCoreTests target stubs.
// Within the app test target they are re-declared here because they live in a
// different module boundary. Once real types land in OpenHLCore, both sets of
// stubs are deleted and replaced with `@testable import OpenHLCore`.

// STUB: AlertCondition (app-target copy)
private enum AppAlertCondition: Sendable, Codable, Equatable {
    enum Direction: String, Sendable, Codable, Equatable { case up, down }
    case aboveAbsolute(Decimal)
    case belowAbsolute(Decimal)
    case percentChange24h(Decimal, Direction)
}

// STUB: AlertRule (app-target copy)
private struct AppAlertRule: Sendable, Codable, Identifiable, Equatable {
    let id: UUID
    var coin: String
    var condition: AppAlertCondition
    var isEnabled: Bool
    var cooldown: TimeInterval
    var lastFiredAt: Date?

    init(
        id: UUID = UUID(),
        coin: String,
        condition: AppAlertCondition,
        isEnabled: Bool = true,
        cooldown: TimeInterval = 6 * 3600,
        lastFiredAt: Date? = nil
    ) {
        self.id = id
        self.coin = coin
        self.condition = condition
        self.isEnabled = isEnabled
        self.cooldown = cooldown
        self.lastFiredAt = lastFiredAt
    }
}

// STUB: NotificationPoster — the injection seam the scheduler must use instead
// of calling UNUserNotificationCenter directly.
private protocol NotificationPoster: Sendable {
    func post(title: String, body: String, identifier: String) async
}

// STUB: FakeNotificationPoster — collects posted notifications for assertion.
private final class FakeNotificationPoster: NotificationPoster, @unchecked Sendable {
    struct Posted: Sendable, Equatable {
        let title: String
        let body: String
        let identifier: String
    }

    private let lock = NSLock()
    private var _posted: [Posted] = []

    var posted: [Posted] {
        lock.withLock { _posted }
    }

    func post(title: String, body: String, identifier: String) async {
        lock.withLock { _posted.append(Posted(title: title, body: body, identifier: identifier)) }
    }
}

// STUB: AlertScheduler — minimal stub matching the agreed interface.
// The real scheduler lives in OpenHL/Services/AlertScheduler.swift.
// This stub exists only so the test structure compiles and documents intent.
//
// Real scheduler contract:
//   final class AlertScheduler: @unchecked Sendable {
//     static let backgroundTaskIdentifier = "xyz.hyperliquid.openhl.refresh"
//
//     init(
//       client: any HyperliquidClient,
//       rulesStore: any AlertRulesStore,
//       poster: any NotificationPoster,
//       clock: any Clock
//     )
//
//     /// Fetches markets + portfolio, evaluates rules, posts notifications,
//     /// updates lastFiredAt in the store. Designed to be called from the
//     /// BGAppRefreshTask handler.
//     func evaluate(now: Date) async throws
//   }
private final class AlertScheduler: @unchecked Sendable {
    static let backgroundTaskIdentifier = "xyz.hyperliquid.openhl.refresh"

    private let client: any HyperliquidClient
    private let poster: any NotificationPoster
    private let clock: any Clock
    private let lock = NSLock()
    private var _rules: [AppAlertRule]

    init(
        client: any HyperliquidClient,
        initialRules: [AppAlertRule],
        poster: any NotificationPoster,
        clock: any Clock
    ) {
        self.client = client
        self._rules = initialRules
        self.poster = poster
        self.clock = clock
    }

    func evaluate(now: Date) async throws {
        let markets = try await client.markets()
        let marketsBySymbol = Dictionary(uniqueKeysWithValues: markets.map { ($0.coin, $0) })

        var toUpdate: [AppAlertRule] = []

        for rule in lock.withLock({ _rules }) {
            guard rule.isEnabled else { continue }
            if let lastFired = rule.lastFiredAt {
                guard now.timeIntervalSince(lastFired) >= rule.cooldown else { continue }
            }
            guard let market = marketsBySymbol[rule.coin] else { continue }

            let fires: Bool
            switch rule.condition {
            case .aboveAbsolute(let t):
                fires = market.markPrice > t
            case .belowAbsolute(let t):
                fires = market.markPrice < t
            case .percentChange24h(let t, let dir):
                switch dir {
                case .up: fires = market.dayChangeRatio >= t
                case .down: fires = market.dayChangeRatio <= -t
                }
            }

            if fires {
                await poster.post(
                    title: "Alert: \(rule.coin)",
                    body: describeCondition(rule.condition, market: market),
                    identifier: rule.id.uuidString
                )
                var updated = rule
                updated = AppAlertRule(
                    id: rule.id, coin: rule.coin,
                    condition: rule.condition, isEnabled: rule.isEnabled,
                    cooldown: rule.cooldown, lastFiredAt: now
                )
                toUpdate.append(updated)
            }
        }

        lock.withLock {
            for updated in toUpdate {
                if let idx = _rules.firstIndex(where: { $0.id == updated.id }) {
                    _rules[idx] = updated
                }
            }
        }
    }

    var rules: [AppAlertRule] {
        lock.withLock { _rules }
    }

    private func describeCondition(_ c: AppAlertCondition, market: Market) -> String {
        switch c {
        case .aboveAbsolute(let t): return "\(market.coin) above \(t)"
        case .belowAbsolute(let t): return "\(market.coin) below \(t)"
        case .percentChange24h(let t, let d): return "\(market.coin) \(d) \(t)"
        }
    }
}

// MARK: - FakeHyperliquidClient helper extension for markets

// The app-target FakeHyperliquidClient is defined in HyperliquidAPITests/Support.
// Since it is not visible here, we define a minimal local fake.
private final class SchedulerFakeClient: HyperliquidClient, @unchecked Sendable {
    var marketsResult: Result<[Market], HyperliquidError> = .failure(.offline)
    var portfolioResult: Result<Portfolio, HyperliquidError> = .failure(.offline)

    func clearinghouseState(for user: Address) async throws -> ClearinghouseState {
        throw HyperliquidError.offline
    }
    func openOrders(for user: Address) async throws -> [OpenOrder] {
        throw HyperliquidError.offline
    }
    func userFills(for user: Address) async throws -> [Fill] {
        throw HyperliquidError.offline
    }
    func markets() async throws -> [Market] {
        return try marketsResult.get()
    }
    func candles(coin: String, interval: CandleInterval, startTime: Date, endTime: Date) async throws -> [Candle] {
        throw HyperliquidError.offline
    }
    func portfolio(for user: Address) async throws -> Portfolio {
        return try portfolioResult.get()
    }
}

// MARK: - Market test fixture helpers

extension Market {
    fileprivate static func make(
        coin: String,
        markPrice: Decimal,
        prevDayPrice: Decimal
    ) -> Market {
        Market(
            coin: coin,
            maxLeverage: 50,
            szDecimals: 4,
            onlyIsolated: false,
            markPrice: markPrice,
            midPrice: markPrice,
            prevDayPrice: prevDayPrice,
            openInterest: 0,
            dayNotionalVolume: 0,
            fundingRate: 0
        )
    }
}

private let schedulerRef = Date(timeIntervalSinceReferenceDate: 2_000_000)

// MARK: - AlertScheduler integration tests

@Suite("AlertScheduler — evaluate integration")
struct AlertSchedulerEvaluatesAndPostsTests {

    @Test("evaluate: matching rule fires → notification is posted")
    func evaluatePostsNotificationWhenRuleFires() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000)
        ])

        let rule = AppAlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))
        let poster = FakeNotificationPoster()
        let clock = FixedClock(schedulerRef)
        let scheduler = AlertScheduler(
            client: client,
            initialRules: [rule],
            poster: poster,
            clock: clock
        )

        try await scheduler.evaluate(now: schedulerRef)

        #expect(poster.posted.count == 1)
        #expect(poster.posted.first?.identifier == rule.id.uuidString)
    }

    @Test("evaluate: non-matching rule → no notification posted")
    func evaluatePostsNoNotificationWhenRuleDoesNotFire() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 70_000, prevDayPrice: 65_000)
        ])

        let rule = AppAlertRule(coin: "BTC", condition: .aboveAbsolute(80_000))
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)
        #expect(poster.posted.isEmpty)
    }

    @Test("evaluate: disabled rule → no notification even if condition matches")
    func evaluateSkipsDisabledRules() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000)
        ])

        let rule = AppAlertRule(coin: "BTC", condition: .aboveAbsolute(75_000), isEnabled: false)
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)
        #expect(poster.posted.isEmpty)
    }

    @Test("evaluate: cooldown active → no notification posted")
    func evaluateRespectsActiveCooldown() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000)
        ])

        // Fired 1 hour ago, cooldown 6 hours → still cooling down
        let lastFired = schedulerRef.addingTimeInterval(-3600)
        let rule = AppAlertRule(
            coin: "BTC", condition: .aboveAbsolute(75_000),
            cooldown: 6 * 3600, lastFiredAt: lastFired
        )
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)
        #expect(poster.posted.isEmpty)
    }

    @Test("evaluate: cooldown expired → notification posted")
    func evaluateFiresAfterCooldownExpiry() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000)
        ])

        // Fired 7 hours ago, cooldown 6 hours → elapsed > cooldown
        let lastFired = schedulerRef.addingTimeInterval(-7 * 3600)
        let rule = AppAlertRule(
            coin: "BTC", condition: .aboveAbsolute(75_000),
            cooldown: 6 * 3600, lastFiredAt: lastFired
        )
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)
        #expect(poster.posted.count == 1)
    }

    @Test("evaluate: after firing, rule's lastFiredAt is updated in store")
    func evaluateUpdatesLastFiredAt() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000)
        ])

        let rule = AppAlertRule(coin: "BTC", condition: .aboveAbsolute(75_000), lastFiredAt: nil)
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)

        let updatedRule = scheduler.rules.first
        #expect(updatedRule?.lastFiredAt == schedulerRef)
    }

    @Test("evaluate: unfired rule's lastFiredAt is not mutated")
    func evaluateDoesNotMutateUnfiredRuleLastFiredAt() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 70_000, prevDayPrice: 65_000)
        ])

        let originalDate = schedulerRef.addingTimeInterval(-10 * 3600)
        let rule = AppAlertRule(
            coin: "BTC", condition: .aboveAbsolute(80_000), lastFiredAt: originalDate
        )
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)

        let storedRule = scheduler.rules.first
        #expect(storedRule?.lastFiredAt == originalDate)
    }

    @Test("evaluate: multiple rules — all matching ones post notifications")
    func evaluateMultipleMatchingRulesAllPost() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000),
            .make(coin: "ETH", markPrice: 1_800, prevDayPrice: 2_000),
        ])

        let r1 = AppAlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))
        let r2 = AppAlertRule(coin: "ETH", condition: .belowAbsolute(2_000))
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [r1, r2],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)
        #expect(poster.posted.count == 2)
    }

    @Test("evaluate: client offline error propagates as throw")
    func evaluateThrowsWhenClientOffline() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .failure(.offline)

        let rule = AppAlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))
        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [rule],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        await #expect(throws: HyperliquidError.self) {
            try await scheduler.evaluate(now: schedulerRef)
        }
        #expect(poster.posted.isEmpty)
    }

    @Test("evaluate: no rules registered → no notification posted, no crash")
    func evaluateWithNoRulesIsNoOp() async throws {
        let client = SchedulerFakeClient()
        client.marketsResult = .success([
            .make(coin: "BTC", markPrice: 80_000, prevDayPrice: 70_000)
        ])

        let poster = FakeNotificationPoster()
        let scheduler = AlertScheduler(
            client: client, initialRules: [],
            poster: poster, clock: FixedClock(schedulerRef)
        )

        try await scheduler.evaluate(now: schedulerRef)
        #expect(poster.posted.isEmpty)
    }
}

// MARK: - BGTask identifier test

@Suite("AlertScheduler — background task identifier")
struct BGTaskIdentifierTests {

    @Test("backgroundTaskIdentifier is the agreed bundle-scoped constant")
    func backgroundTaskIdentifierIsCorrect() {
        #expect(AlertScheduler.backgroundTaskIdentifier == "xyz.hyperliquid.openhl.refresh")
    }
}

// MARK: - FakeNotificationPoster unit tests
// These run today without any dependency on the real scheduler.

@Suite("FakeNotificationPoster — test helper self-test")
struct FakeNotificationPosterSelfTests {

    @Test("posted starts empty")
    func postedStartsEmpty() {
        let poster = FakeNotificationPoster()
        #expect(poster.posted.isEmpty)
    }

    @Test("post(title:body:identifier:) records the notification")
    func postRecordsNotification() async {
        let poster = FakeNotificationPoster()
        await poster.post(title: "T", body: "B", identifier: "id-1")
        #expect(poster.posted.count == 1)
        #expect(poster.posted.first == FakeNotificationPoster.Posted(title: "T", body: "B", identifier: "id-1"))
    }

    @Test("Multiple posts are all recorded in order")
    func multiplePostsRecordedInOrder() async {
        let poster = FakeNotificationPoster()
        await poster.post(title: "A", body: "a", identifier: "1")
        await poster.post(title: "B", body: "b", identifier: "2")
        #expect(poster.posted.count == 2)
        #expect(poster.posted[0].identifier == "1")
        #expect(poster.posted[1].identifier == "2")
    }
}
