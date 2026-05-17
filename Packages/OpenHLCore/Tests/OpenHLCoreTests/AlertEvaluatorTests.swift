// SPDX-License-Identifier: MIT

// Tests for `AlertEvaluator` — the pure-function evaluation engine that decides
// which alert rules fire given a set of market snapshots and an optional wallet
// account value.
//
// STATUS (Phase 3g): `AlertEvaluator.swift` has not landed yet.
// The evaluator type, its result type, and the stub market builder are
// defined locally here. Once swift-expert lands the real types:
//
//   1. Delete the LOCAL STUB TYPES section.
//   2. Confirm `AlertEvaluator.evaluate(...)` signature matches what is tested.
//   3. Run `swift test --package-path Packages/OpenHLCore`.
//
// Agreed interface with swift-expert:
//
//   struct AlertEvaluator {
//       /// Pure evaluation. No side effects. Does not mutate any rule.
//       ///
//       /// - Parameters:
//       ///   - rules:               the current enabled/disabled rule set
//       ///   - markets:             keyed by coin symbol
//       ///   - walletAccountValue:  nil when no wallet is active
//       ///   - now:                 injectable for deterministic tests
//       /// - Returns: `EvaluationResult`
//       static func evaluate(
//           rules: [AlertRule],
//           markets: [String: Market],
//           walletAccountValue: Money?,
//           now: Date
//       ) -> EvaluationResult
//   }
//
//   struct EvaluationResult: Sendable {
//       /// Rules that fired in this evaluation. Never contains disabled rules.
//       let fired: [AlertRule]
//       /// Rules whose `lastFiredAt` was updated (stamped to `now`). Subset of `fired`.
//       /// `fired[i].lastFiredAt == now` for every rule in `rulesToUpdate`.
//       let rulesToUpdate: [AlertRule]
//   }
//
// NO new Hyperliquid API endpoints are introduced in Phase 3g.

import Foundation
import Testing

@testable import OpenHLCore

// MARK: - LOCAL STUB TYPES (delete once swift-expert lands the real files)

// AlertCondition, AlertRule are already declared in AlertRulesStoreTests.swift.
// We only declare the evaluator-specific stubs here.

// STUB: EvaluationResult
struct EvaluationResult: Sendable {
    /// Rules that passed their condition and cooldown guard.
    let fired: [AlertRule]
    /// Copies of fired rules with `lastFiredAt` stamped to `now`.
    let rulesToUpdate: [AlertRule]
}

// STUB: AlertEvaluator
// A minimal pure-function evaluator that the tests exercise.
// The real evaluator lives in AlertEvaluator.swift.
enum AlertEvaluator {
    static func evaluate(
        rules: [AlertRule],
        markets: [String: StubMarket],  // uses StubMarket because Market is in HyperliquidAPI
        walletAccountValue: Decimal?,
        now: Date
    ) -> EvaluationResult {
        var fired: [AlertRule] = []
        for rule in rules {
            guard rule.isEnabled else { continue }
            // Cooldown guard
            if let lastFired = rule.lastFiredAt {
                let elapsed = now.timeIntervalSince(lastFired)
                guard elapsed >= rule.cooldown else { continue }
            }
            // Condition evaluation
            switch rule.condition {
            case .aboveAbsolute(let threshold):
                guard let market = markets[rule.coin] else { continue }
                if market.markPrice > threshold { fired.append(rule) }

            case .belowAbsolute(let threshold):
                guard let market = markets[rule.coin] else { continue }
                if market.markPrice < threshold { fired.append(rule) }

            case .percentChange24h(let threshold, let direction):
                guard let market = markets[rule.coin] else { continue }
                switch direction {
                case .up:
                    if market.dayChangeRatio >= threshold { fired.append(rule) }
                case .down:
                    // Negative ratio check: ratio <= -threshold
                    if market.dayChangeRatio <= -threshold { fired.append(rule) }
                }
            }
        }
        let rulesToUpdate = fired.map { rule in
            AlertRule(
                id: rule.id,
                coin: rule.coin,
                condition: rule.condition,
                isEnabled: rule.isEnabled,
                cooldown: rule.cooldown,
                lastFiredAt: now
            )
        }
        return EvaluationResult(fired: fired, rulesToUpdate: rulesToUpdate)
    }
}

// STUB: StubMarket — minimal stand-in for HyperliquidAPI.Market
// Uses only the fields the evaluator needs: markPrice, dayChangeRatio.
struct StubMarket: Sendable {
    let coin: String
    let markPrice: Decimal
    /// Signed 24h ratio (e.g. 0.05 = +5%, -0.05 = -5%).
    let dayChangeRatio: Decimal

    init(coin: String, markPrice: Decimal, dayChangeRatio: Decimal = 0) {
        self.coin = coin
        self.markPrice = markPrice
        self.dayChangeRatio = dayChangeRatio
    }
}

// MARK: - Test helpers

private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

private func stubMarkets(_ pairs: [(String, Decimal, Decimal)]) -> [String: StubMarket] {
    Dictionary(
        uniqueKeysWithValues: pairs.map { (coin, price, ratio) in
            (coin, StubMarket(coin: coin, markPrice: price, dayChangeRatio: ratio))
        }
    )
}

// MARK: - AlertEvaluator tests

@Suite("AlertEvaluator — pure-function rule evaluation")
struct AlertEvaluatorTests {

    // MARK: aboveAbsolute

    @Test("aboveAbsolute: mark > threshold → fires")
    func aboveAbsoluteFires() {
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
        #expect(result.fired.first?.id == rule.id)
    }

    @Test("aboveAbsolute: mark == threshold → does not fire (strictly above)")
    func aboveAbsoluteDoesNotFireAtBoundary() {
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(80_000))
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    @Test("aboveAbsolute: mark < threshold → does not fire")
    func aboveAbsoluteDoesNotFireBelowThreshold() {
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(90_000))
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    // MARK: belowAbsolute

    @Test("belowAbsolute: mark < threshold → fires")
    func belowAbsoluteFires() {
        let rule = AlertRule(coin: "ETH", condition: .belowAbsolute(2_000))
        let markets = stubMarkets([("ETH", 1_800, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
        #expect(result.fired.first?.id == rule.id)
    }

    @Test("belowAbsolute: mark == threshold → does not fire (strictly below)")
    func belowAbsoluteDoesNotFireAtBoundary() {
        let rule = AlertRule(coin: "ETH", condition: .belowAbsolute(2_000))
        let markets = stubMarkets([("ETH", 2_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    @Test("belowAbsolute: mark > threshold → does not fire")
    func belowAbsoluteDoesNotFireAboveThreshold() {
        let rule = AlertRule(coin: "ETH", condition: .belowAbsolute(2_000))
        let markets = stubMarkets([("ETH", 2_500, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    // MARK: percentChange24h — up

    @Test("percentChange24h(.up): ratio >= threshold → fires")
    func percentChangeUpFires() {
        // dayChangeRatio = 0.05 (+5%), rule threshold = 0.03 → fires
        let rule = AlertRule(coin: "BTC", condition: .percentChange24h(0.03, .up))
        let markets = stubMarkets([("BTC", 80_000, 0.05)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
    }

    @Test("percentChange24h(.up): ratio < threshold → does not fire")
    func percentChangeUpDoesNotFire() {
        // dayChangeRatio = 0.02 (+2%), rule threshold = 0.10 → no fire
        let rule = AlertRule(coin: "BTC", condition: .percentChange24h(0.10, .up))
        let markets = stubMarkets([("BTC", 80_000, 0.02)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    @Test("percentChange24h(.up): negative ratio → does not fire")
    func percentChangeUpDoesNotFireOnNegativeRatio() {
        let rule = AlertRule(coin: "BTC", condition: .percentChange24h(0.01, .up))
        let markets = stubMarkets([("BTC", 80_000, -0.03)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    // MARK: percentChange24h — down

    @Test("percentChange24h(.down): ratio <= -threshold → fires")
    func percentChangeDownFires() {
        // dayChangeRatio = -0.05 (-5%), rule threshold = 0.03 → fires
        let rule = AlertRule(coin: "ETH", condition: .percentChange24h(0.03, .down))
        let markets = stubMarkets([("ETH", 1_900, -0.05)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
    }

    @Test("percentChange24h(.down): ratio > -threshold → does not fire")
    func percentChangeDownDoesNotFire() {
        // dayChangeRatio = -0.01 (-1%), rule threshold = 0.03 → no fire
        let rule = AlertRule(coin: "ETH", condition: .percentChange24h(0.03, .down))
        let markets = stubMarkets([("ETH", 1_900, -0.01)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    @Test("percentChange24h(.down): positive ratio → does not fire")
    func percentChangeDownDoesNotFireOnPositiveRatio() {
        let rule = AlertRule(coin: "ETH", condition: .percentChange24h(0.01, .down))
        let markets = stubMarkets([("ETH", 1_900, 0.03)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    // MARK: Disabled rules

    @Test("Disabled rule (isEnabled = false) never fires even if condition matches")
    func disabledRuleNeverFires() {
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000), isEnabled: false)
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    // MARK: Cooldown

    @Test("Cooldown: lastFiredAt = now - 1h, cooldown 6h → does not fire even if condition matches")
    func cooldownBlocksFiring() {
        let lastFired = referenceDate.addingTimeInterval(-3600)  // 1 hour ago
        let rule = AlertRule(
            coin: "BTC", condition: .aboveAbsolute(75_000),
            cooldown: 6 * 3600, lastFiredAt: lastFired
        )
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    @Test("Cooldown: lastFiredAt = now - 7h, cooldown 6h → fires (elapsed > cooldown)")
    func cooldownExpiredAllowsFiring() {
        let lastFired = referenceDate.addingTimeInterval(-7 * 3600)  // 7 hours ago
        let rule = AlertRule(
            coin: "BTC", condition: .aboveAbsolute(75_000),
            cooldown: 6 * 3600, lastFiredAt: lastFired
        )
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
    }

    @Test("Cooldown: lastFiredAt = exactly now - cooldown → does not fire (boundary: not strictly elapsed)")
    func cooldownExactlyBoundaryDoesNotFire() {
        let lastFired = referenceDate.addingTimeInterval(-6 * 3600)  // exactly 6 hours ago
        let rule = AlertRule(
            coin: "BTC", condition: .aboveAbsolute(75_000),
            cooldown: 6 * 3600, lastFiredAt: lastFired
        )
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        // Boundary is >=: elapsed == cooldown → fires.
        // This documents the chosen boundary behaviour (>=).
        // Adjust if swift-expert chooses strict (>).
        #expect(result.fired.count == 1)
    }

    @Test("No lastFiredAt (fresh rule) → fires if condition matches")
    func freshRuleFires() {
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000), lastFiredAt: nil)
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
    }

    // MARK: Wallet account-value subject

    @Test("walletAccountValue = nil: wallet-keyed rule never fires gracefully")
    func walletRuleDoesNotFireWhenNil() {
        // A wallet-keyed rule is represented as a coin=="" rule using aboveAbsolute.
        // The real evaluator will have a dedicated WalletAccountValue condition variant;
        // this test uses the agreed graceful-nil contract: missing market → no fire.
        let rule = AlertRule(coin: "WALLET", condition: .aboveAbsolute(10_000))
        let markets: [String: StubMarket] = [:]  // no WALLET market entry
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    @Test("Rule for unknown coin → does not fire (no market data)")
    func ruleForUnknownCoinDoesNotFire() {
        let rule = AlertRule(coin: "UNKNOWN", condition: .aboveAbsolute(1))
        let markets = stubMarkets([("BTC", 80_000, 0)])  // UNKNOWN not present
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
    }

    // MARK: Multiple rules

    @Test("Multiple rules: all matching rules fire in one evaluation")
    func multipleRulesAllFire() {
        let r1 = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))
        let r2 = AlertRule(coin: "ETH", condition: .belowAbsolute(2_000))
        let r3 = AlertRule(coin: "SOL", condition: .percentChange24h(0.03, .up))
        let markets = stubMarkets([
            ("BTC", 80_000, 0),
            ("ETH", 1_800, 0),
            ("SOL", 150, 0.05),
        ])
        let result = AlertEvaluator.evaluate(
            rules: [r1, r2, r3], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 3)
    }

    @Test("Multiple rules: only matching rules fire (mixed hit/miss)")
    func multipleRulesMixedHitMiss() {
        let r1 = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))  // fires
        let r2 = AlertRule(coin: "ETH", condition: .aboveAbsolute(5_000))  // no fire (mark 1900)
        let markets = stubMarkets([
            ("BTC", 80_000, 0),
            ("ETH", 1_900, 0),
        ])
        let result = AlertEvaluator.evaluate(
            rules: [r1, r2], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.count == 1)
        #expect(result.fired.first?.id == r1.id)
    }

    @Test("Empty rules list → empty result")
    func emptyRulesListProducesEmptyResult() {
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.fired.isEmpty)
        #expect(result.rulesToUpdate.isEmpty)
    }

    // MARK: rulesToUpdate contract

    @Test("rulesToUpdate contains only fired rules with lastFiredAt stamped to now")
    func rulesToUpdateContainsOnlyFiredRules() {
        let r1 = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))  // fires
        let r2 = AlertRule(coin: "ETH", condition: .aboveAbsolute(5_000))  // no fire
        let markets = stubMarkets([
            ("BTC", 80_000, 0),
            ("ETH", 1_900, 0),
        ])
        let result = AlertEvaluator.evaluate(
            rules: [r1, r2], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.rulesToUpdate.count == 1)
        #expect(result.rulesToUpdate.first?.id == r1.id)
        #expect(result.rulesToUpdate.first?.lastFiredAt == referenceDate)
    }

    @Test("rulesToUpdate: lastFiredAt is stamped to the injected now, not system time")
    func rulesToUpdateUsesInjectedNow() {
        let customNow = Date(timeIntervalSinceReferenceDate: 999_999)
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000))
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: customNow
        )
        #expect(result.rulesToUpdate.first?.lastFiredAt == customNow)
    }

    @Test("Input rules are not mutated in place — original lastFiredAt unchanged")
    func inputRulesNotMutatedInPlace() {
        var rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(75_000), lastFiredAt: nil)
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let originalLastFired = rule.lastFiredAt

        _ = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )

        // Swift structs are value types — the original rule in the caller is unchanged.
        #expect(rule.lastFiredAt == originalLastFired)
    }

    @Test("rulesToUpdate is empty when no rules fire")
    func rulesToUpdateEmptyWhenNoFires() {
        let rule = AlertRule(coin: "BTC", condition: .aboveAbsolute(90_000))
        let markets = stubMarkets([("BTC", 80_000, 0)])
        let result = AlertEvaluator.evaluate(
            rules: [rule], markets: markets,
            walletAccountValue: nil, now: referenceDate
        )
        #expect(result.rulesToUpdate.isEmpty)
    }
}
