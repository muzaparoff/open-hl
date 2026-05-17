// SPDX-License-Identifier: MIT

// Tests for `AlertRulesStore` — the protocol and its two concrete
// implementations (`InMemoryAlertRulesStore`, `UserDefaultsAlertRulesStore`).
//
// STATUS (Phase 3g): swift-expert has not yet landed
// `AlertRule.swift` and `AlertRulesStore.swift` in `OpenHLCore`.
// The protocol, model, and both concrete implementations are stubbed
// locally here so the test *shapes* are final and compile-clean today.
// Once swift-expert lands the real types:
//
//   1. Delete the LOCAL STUB TYPES section below.
//   2. Remove the `// STUB:` comments throughout.
//   3. Run `swift test --package-path Packages/OpenHLCore`.
//
// Agreed interface with swift-expert:
//   - `AlertCondition`: enum with `.aboveAbsolute(Money)`,
//     `.belowAbsolute(Money)`, `.percentChange24h(Money, Direction)`.
//     `Direction`: enum with `.up`, `.down`.
//   - `AlertRule: Sendable, Codable, Identifiable, Equatable`
//     id: UUID, coin: String, condition: AlertCondition,
//     isEnabled: Bool, cooldown: TimeInterval, lastFiredAt: Date?
//   - `AlertRulesStore: Sendable` protocol with:
//       func all() -> [AlertRule]
//       func upsert(_ rule: AlertRule)
//       func remove(id: UUID)
//       func toggle(id: UUID)          // flips isEnabled
//       var didChange: AsyncStream<[AlertRule]>  // emits on every mutation, current set first
//   - `InMemoryAlertRulesStore(initial: [AlertRule] = [])` — NSLock-guarded, @unchecked Sendable
//   - `UserDefaultsAlertRulesStore(defaults: UserDefaults = .standard)` — JSON-backed,
//     key `openhl.alertRules`, @unchecked Sendable
//
// NO new Hyperliquid API endpoints are introduced in Phase 3g.

import Foundation
import Testing

@testable import OpenHLCore

// MARK: - LOCAL STUB TYPES (delete once swift-expert lands the real files)

// STUB: AlertCondition
enum AlertCondition: Sendable, Codable, Equatable, Hashable {
    enum Direction: String, Sendable, Codable, Equatable { case up, down }
    case aboveAbsolute(Decimal)
    case belowAbsolute(Decimal)
    case percentChange24h(Decimal, Direction)
}

// STUB: AlertRule
struct AlertRule: Sendable, Codable, Identifiable, Equatable {
    let id: UUID
    var coin: String
    var condition: AlertCondition
    var isEnabled: Bool
    var cooldown: TimeInterval  // seconds
    var lastFiredAt: Date?

    init(
        id: UUID = UUID(),
        coin: String,
        condition: AlertCondition,
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

// STUB: shared multi-subscriber fan-out helper (mirrors Continuations in FavoriteCoinsStore)
private final class AlertContinuations: @unchecked Sendable {
    private var subscribers: [UUID: AsyncStream<[AlertRule]>.Continuation] = [:]
    private let lock = NSLock()

    func register(_ continuation: AsyncStream<[AlertRule]>.Continuation) -> UUID {
        let token = UUID()
        lock.withLock { subscribers[token] = continuation }
        return token
    }
    func unregister(_ token: UUID) {
        lock.withLock { _ = subscribers.removeValue(forKey: token) }
    }
    func yield(_ value: [AlertRule]) {
        let snapshot: [AsyncStream<[AlertRule]>.Continuation] = lock.withLock {
            Array(subscribers.values)
        }
        for c in snapshot { c.yield(value) }
    }
}

// STUB: AlertRulesStore protocol
protocol AlertRulesStore: Sendable {
    func all() -> [AlertRule]
    func upsert(_ rule: AlertRule)
    func remove(id: UUID)
    func toggle(id: UUID)
    var didChange: AsyncStream<[AlertRule]> { get }
}

// STUB: InMemoryAlertRulesStore
final class InMemoryAlertRulesStore: AlertRulesStore, @unchecked Sendable {
    private var rules: [UUID: AlertRule]
    private let lock = NSLock()
    private let continuations = AlertContinuations()

    init(initial: [AlertRule] = []) {
        self.rules = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
    }

    func all() -> [AlertRule] {
        lock.withLock { Array(rules.values) }
    }

    func upsert(_ rule: AlertRule) {
        let snapshot: [AlertRule] = lock.withLock {
            rules[rule.id] = rule
            return Array(rules.values)
        }
        continuations.yield(snapshot)
    }

    func remove(id: UUID) {
        let snapshot: [AlertRule] = lock.withLock {
            rules.removeValue(forKey: id)
            return Array(rules.values)
        }
        continuations.yield(snapshot)
    }

    func toggle(id: UUID) {
        let snapshot: [AlertRule] = lock.withLock {
            if var existing = rules[id] {
                existing.isEnabled.toggle()
                rules[id] = existing
            }
            return Array(rules.values)
        }
        continuations.yield(snapshot)
    }

    var didChange: AsyncStream<[AlertRule]> {
        let initial = all()
        return AsyncStream<[AlertRule]> { continuation in
            let token = continuations.register(continuation)
            continuation.yield(initial)
            continuation.onTermination = { [continuations] _ in
                continuations.unregister(token)
            }
        }
    }
}

// STUB: UserDefaultsAlertRulesStore
final class UserDefaultsAlertRulesStore: AlertRulesStore, @unchecked Sendable {
    static let storageKey = "openhl.alertRules"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: [UUID: AlertRule]
    private let continuations = AlertContinuations()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cached = Self.load(from: defaults)
    }

    func all() -> [AlertRule] {
        lock.withLock { Array(cached.values) }
    }

    func upsert(_ rule: AlertRule) {
        let snapshot: [AlertRule] = lock.withLock {
            cached[rule.id] = rule
            let v = Array(cached.values)
            Self.save(v, to: defaults)
            return v
        }
        continuations.yield(snapshot)
    }

    func remove(id: UUID) {
        let snapshot: [AlertRule] = lock.withLock {
            cached.removeValue(forKey: id)
            let v = Array(cached.values)
            Self.save(v, to: defaults)
            return v
        }
        continuations.yield(snapshot)
    }

    func toggle(id: UUID) {
        let snapshot: [AlertRule] = lock.withLock {
            if var existing = cached[id] {
                existing.isEnabled.toggle()
                cached[id] = existing
            }
            let v = Array(cached.values)
            Self.save(v, to: defaults)
            return v
        }
        continuations.yield(snapshot)
    }

    var didChange: AsyncStream<[AlertRule]> {
        let initial = all()
        return AsyncStream<[AlertRule]> { continuation in
            let token = continuations.register(continuation)
            continuation.yield(initial)
            continuation.onTermination = { [continuations] _ in
                continuations.unregister(token)
            }
        }
    }

    private static func load(from defaults: UserDefaults) -> [UUID: AlertRule] {
        guard let data = defaults.data(forKey: storageKey),
            let array = try? JSONDecoder().decode([AlertRule].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: array.map { ($0.id, $0) })
    }

    private static func save(_ rules: [AlertRule], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

// MARK: - Test helpers

extension UserDefaults {
    fileprivate static func alertTestSuite() -> UserDefaults {
        let name = "com.openhl.tests.alertRules.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }
}

private func makeRule(
    id: UUID = UUID(),
    coin: String = "BTC",
    condition: AlertCondition = .aboveAbsolute(75_000),
    isEnabled: Bool = true,
    cooldown: TimeInterval = 6 * 3600,
    lastFiredAt: Date? = nil
) -> AlertRule {
    AlertRule(
        id: id,
        coin: coin,
        condition: condition,
        isEnabled: isEnabled,
        cooldown: cooldown,
        lastFiredAt: lastFiredAt
    )
}

// MARK: - InMemoryAlertRulesStore tests

@Suite("InMemoryAlertRulesStore — protocol conformance")
struct InMemoryAlertRulesStoreTests {

    // MARK: all / upsert

    @Test("all() returns empty array by default")
    func allIsEmptyByDefault() {
        let store = InMemoryAlertRulesStore()
        #expect(store.all().isEmpty)
    }

    @Test("init(initial:) pre-seeds the store")
    func initPreSeeds() {
        let rule = makeRule(coin: "BTC")
        let store = InMemoryAlertRulesStore(initial: [rule])
        #expect(store.all().count == 1)
        #expect(store.all().first?.id == rule.id)
    }

    @Test("upsert inserts a new rule")
    func upsertInsertsNew() {
        let store = InMemoryAlertRulesStore()
        let rule = makeRule()
        store.upsert(rule)
        #expect(store.all().count == 1)
        #expect(store.all().first?.id == rule.id)
    }

    @Test("upsert with same id overwrites the existing rule")
    func upsertOverwrites() {
        let id = UUID()
        let store = InMemoryAlertRulesStore()
        store.upsert(makeRule(id: id, coin: "BTC"))
        store.upsert(makeRule(id: id, coin: "ETH"))  // same id, different coin
        let all = store.all()
        #expect(all.count == 1)
        #expect(all.first?.coin == "ETH")
    }

    @Test("upsert multiple distinct ids accumulates all")
    func upsertMultiple() {
        let store = InMemoryAlertRulesStore()
        store.upsert(makeRule(coin: "BTC"))
        store.upsert(makeRule(coin: "ETH"))
        store.upsert(makeRule(coin: "SOL"))
        #expect(store.all().count == 3)
    }

    // MARK: remove

    @Test("remove deletes a rule that was present")
    func removeDeletesExisting() {
        let rule = makeRule()
        let store = InMemoryAlertRulesStore(initial: [rule])
        store.remove(id: rule.id)
        #expect(store.all().isEmpty)
    }

    @Test("remove on unknown id is a no-op")
    func removeUnknownIdIsNoOp() {
        let rule = makeRule()
        let store = InMemoryAlertRulesStore(initial: [rule])
        store.remove(id: UUID())  // different id
        #expect(store.all().count == 1)
    }

    @Test("remove leaves other rules intact")
    func removeLeavesSiblings() {
        let r1 = makeRule(coin: "BTC")
        let r2 = makeRule(coin: "ETH")
        let store = InMemoryAlertRulesStore(initial: [r1, r2])
        store.remove(id: r1.id)
        let all = store.all()
        #expect(all.count == 1)
        #expect(all.first?.id == r2.id)
    }

    // MARK: toggle

    @Test("toggle flips isEnabled from true to false")
    func toggleDisablesEnabledRule() {
        let rule = makeRule(isEnabled: true)
        let store = InMemoryAlertRulesStore(initial: [rule])
        store.toggle(id: rule.id)
        #expect(store.all().first?.isEnabled == false)
    }

    @Test("toggle flips isEnabled from false to true")
    func toggleEnablesDisabledRule() {
        let rule = makeRule(isEnabled: false)
        let store = InMemoryAlertRulesStore(initial: [rule])
        store.toggle(id: rule.id)
        #expect(store.all().first?.isEnabled == true)
    }

    @Test("toggle round-trip restores original isEnabled")
    func toggleRoundTrip() {
        let rule = makeRule(isEnabled: true)
        let store = InMemoryAlertRulesStore(initial: [rule])
        store.toggle(id: rule.id)
        store.toggle(id: rule.id)
        #expect(store.all().first?.isEnabled == true)
    }

    @Test("toggle on unknown id is a no-op")
    func toggleUnknownIdIsNoOp() {
        let rule = makeRule(isEnabled: true)
        let store = InMemoryAlertRulesStore(initial: [rule])
        store.toggle(id: UUID())
        #expect(store.all().first?.isEnabled == true)
    }

    // MARK: AsyncStream

    @Test("didChange emits current (empty) state immediately on subscribe")
    func didChangeEmitsCurrentStateOnSubscribe() async {
        let store = InMemoryAlertRulesStore()
        var iterator = store.didChange.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.isEmpty == true)
    }

    @Test("didChange emits pre-seeded state immediately on subscribe")
    func didChangeEmitsPreSeededStateOnSubscribe() async {
        let rule = makeRule()
        let store = InMemoryAlertRulesStore(initial: [rule])
        var iterator = store.didChange.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.count == 1)
        #expect(first?.first?.id == rule.id)
    }

    @Test("didChange emits after upsert")
    func didChangeEmitsAfterUpsert() async {
        let store = InMemoryAlertRulesStore()
        var iterator = store.didChange.makeAsyncIterator()
        _ = await iterator.next()  // consume initial empty emit

        let rule = makeRule()
        store.upsert(rule)
        let emitted = await iterator.next()
        #expect(emitted?.count == 1)
        #expect(emitted?.first?.id == rule.id)
    }

    @Test("didChange emits after remove")
    func didChangeEmitsAfterRemove() async {
        let rule = makeRule()
        let store = InMemoryAlertRulesStore(initial: [rule])
        var iterator = store.didChange.makeAsyncIterator()
        _ = await iterator.next()  // consume initial emit

        store.remove(id: rule.id)
        let emitted = await iterator.next()
        #expect(emitted?.isEmpty == true)
    }

    @Test("didChange emits after toggle")
    func didChangeEmitsAfterToggle() async {
        let rule = makeRule(isEnabled: true)
        let store = InMemoryAlertRulesStore(initial: [rule])
        var iterator = store.didChange.makeAsyncIterator()
        _ = await iterator.next()  // consume initial emit

        store.toggle(id: rule.id)
        let emitted = await iterator.next()
        #expect(emitted?.first?.isEnabled == false)
    }

    @Test("didChange supports multiple independent subscribers")
    func didChangeMultipleSubscribers() async {
        let store = InMemoryAlertRulesStore()
        var iterA = store.didChange.makeAsyncIterator()
        var iterB = store.didChange.makeAsyncIterator()

        // Both subscribers get the initial empty state.
        let a0 = await iterA.next()
        let b0 = await iterB.next()
        #expect(a0?.isEmpty == true)
        #expect(b0?.isEmpty == true)

        store.upsert(makeRule())

        let a1 = await iterA.next()
        let b1 = await iterB.next()
        #expect(a1?.count == 1)
        #expect(b1?.count == 1)
    }

    // MARK: Concurrency

    @Test("Concurrent upserts across distinct ids all land in the store")
    func concurrentUpsertsDistinctIds() async {
        let store = InMemoryAlertRulesStore()
        let rules = (0..<50).map { i in makeRule(coin: "COIN\(i)") }

        await withTaskGroup(of: Void.self) { group in
            for rule in rules {
                group.addTask { store.upsert(rule) }
            }
        }

        #expect(store.all().count == 50)
    }

    @Test("Concurrent upsert of same id is serialized — final state has exactly one entry")
    func concurrentUpsertSameIdIsSerialised() async {
        let id = UUID()
        let store = InMemoryAlertRulesStore()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { store.upsert(makeRule(id: id, coin: "COIN\(i)")) }
            }
        }

        // Exactly one entry survives regardless of ordering.
        #expect(store.all().count == 1)
        #expect(store.all().first?.id == id)
    }
}

// MARK: - UserDefaultsAlertRulesStore tests

@Suite("UserDefaultsAlertRulesStore — protocol conformance")
struct UserDefaultsAlertRulesStoreTests {

    @Test("all() returns empty array when UserDefaults key is absent")
    func allIsEmptyWhenKeyAbsent() {
        let store = UserDefaultsAlertRulesStore(defaults: .alertTestSuite())
        #expect(store.all().isEmpty)
    }

    @Test("upsert inserts and all() reflects the new rule")
    func upsertAndAllReflects() {
        let store = UserDefaultsAlertRulesStore(defaults: .alertTestSuite())
        let rule = makeRule()
        store.upsert(rule)
        #expect(store.all().count == 1)
        #expect(store.all().first?.id == rule.id)
    }

    @Test("round-trip: fresh store reads what a prior store wrote")
    func roundTripAcrossStoreInstances() {
        let suite = UserDefaults.alertTestSuite()
        let writer = UserDefaultsAlertRulesStore(defaults: suite)
        let rule = makeRule(coin: "ETH", condition: .belowAbsolute(2_000))
        writer.upsert(rule)

        let reader = UserDefaultsAlertRulesStore(defaults: suite)
        let loaded = reader.all()
        #expect(loaded.count == 1)
        #expect(loaded.first?.coin == "ETH")
        #expect(loaded.first?.condition == .belowAbsolute(2_000))
    }

    @Test("remove persists across store instances")
    func removePersistsAcrossInstances() {
        let suite = UserDefaults.alertTestSuite()
        let r1 = makeRule(coin: "BTC")
        let r2 = makeRule(coin: "ETH")

        let first = UserDefaultsAlertRulesStore(defaults: suite)
        first.upsert(r1)
        first.upsert(r2)
        first.remove(id: r1.id)

        let second = UserDefaultsAlertRulesStore(defaults: suite)
        let all = second.all()
        #expect(all.count == 1)
        #expect(all.first?.id == r2.id)
    }

    @Test("toggle persists across store instances")
    func togglePersistsAcrossInstances() {
        let suite = UserDefaults.alertTestSuite()
        let rule = makeRule(isEnabled: true)

        let first = UserDefaultsAlertRulesStore(defaults: suite)
        first.upsert(rule)
        first.toggle(id: rule.id)

        let second = UserDefaultsAlertRulesStore(defaults: suite)
        #expect(second.all().first?.isEnabled == false)
    }

    @Test("storageKey constant is openhl.alertRules")
    func storageKeyIsCorrect() {
        #expect(UserDefaultsAlertRulesStore.storageKey == "openhl.alertRules")
    }

    @Test("JSON corruption: garbage bytes stored → all() returns empty")
    func jsonCorruptionReturnsEmpty() {
        let suite = UserDefaults.alertTestSuite()
        suite.set("not-json".data(using: .utf8)!, forKey: UserDefaultsAlertRulesStore.storageKey)

        let store = UserDefaultsAlertRulesStore(defaults: suite)
        #expect(store.all().isEmpty)
    }

    @Test("JSON corruption: wrong JSON type (object not array) → all() returns empty")
    func jsonWrongTypeReturnsEmpty() {
        let suite = UserDefaults.alertTestSuite()
        suite.set("{}".data(using: .utf8)!, forKey: UserDefaultsAlertRulesStore.storageKey)

        let store = UserDefaultsAlertRulesStore(defaults: suite)
        #expect(store.all().isEmpty)
    }

    @Test("JSON corruption: String instead of Data stored → all() returns empty")
    func wrongDefaultsTypeReturnsEmpty() {
        let suite = UserDefaults.alertTestSuite()
        // Store a plain String (not Data) — simulates an older format.
        suite.set("[{\"id\":\"bad\"}]", forKey: UserDefaultsAlertRulesStore.storageKey)

        let store = UserDefaultsAlertRulesStore(defaults: suite)
        // `.data(forKey:)` returns nil for a String; defensively returns [].
        #expect(store.all().isEmpty)
    }

    @Test("didChange emits current state immediately on subscribe")
    func didChangeEmitsImmediately() async {
        let rule = makeRule()
        let suite = UserDefaults.alertTestSuite()
        let store = UserDefaultsAlertRulesStore(defaults: suite)
        store.upsert(rule)

        var iterator = store.didChange.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.count == 1)
    }

    @Test("didChange emits after upsert")
    func didChangeEmitsAfterUpsert() async {
        let store = UserDefaultsAlertRulesStore(defaults: .alertTestSuite())
        var iterator = store.didChange.makeAsyncIterator()
        _ = await iterator.next()  // initial empty

        let rule = makeRule()
        store.upsert(rule)
        let emitted = await iterator.next()
        #expect(emitted?.count == 1)
    }

    @Test("Multiple rules persist and reload correctly (condition variety)")
    func multipleRulesPersistAndReload() {
        let suite = UserDefaults.alertTestSuite()
        let writer = UserDefaultsAlertRulesStore(defaults: suite)
        writer.upsert(makeRule(coin: "BTC", condition: .aboveAbsolute(80_000)))
        writer.upsert(makeRule(coin: "ETH", condition: .belowAbsolute(2_000)))
        writer.upsert(makeRule(coin: "SOL", condition: .percentChange24h(0.05, .up)))

        let reader = UserDefaultsAlertRulesStore(defaults: suite)
        #expect(reader.all().count == 3)
    }

    @Test("Test suites are isolated — writes in one suite do not bleed into another")
    func testSuitesAreIsolated() {
        let suiteA = UserDefaults.alertTestSuite()
        let suiteB = UserDefaults.alertTestSuite()

        let storeA = UserDefaultsAlertRulesStore(defaults: suiteA)
        storeA.upsert(makeRule(coin: "BTC"))

        let storeB = UserDefaultsAlertRulesStore(defaults: suiteB)
        #expect(storeB.all().isEmpty)
    }

    // MARK: Concurrency

    @Test("100 concurrent upserts to distinct ids produce 100 entries")
    func concurrentUpsertsManyIds() async {
        let store = UserDefaultsAlertRulesStore(defaults: .alertTestSuite())
        let rules = (0..<100).map { i in makeRule(coin: "C\(i)") }

        await withTaskGroup(of: Void.self) { group in
            for rule in rules {
                group.addTask { store.upsert(rule) }
            }
        }

        #expect(store.all().count == 100)
    }
}
