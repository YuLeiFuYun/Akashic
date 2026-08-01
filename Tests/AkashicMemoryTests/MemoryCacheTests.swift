import AkashicMemory
import Foundation
import Testing

@Suite("AkashicMemory SIEVE cache")
struct MemoryCacheTests {
    @Test("AKASHIC-CT-027 bounded reference behavior")
    func boundedReferenceBehavior() {
        let cache = MemoryCache<String, Int>(costLimit: 3)
        cache.insert(1, for: "a", cost: 1)
        cache.insert(2, for: "b", cost: 1)
        cache.insert(3, for: "c", cost: 1)
        #expect(cache.value(for: "a") == 1)

        cache.insert(4, for: "d", cost: 1)

        #expect(cache.currentCost == 3)
        #expect(cache.count == 3)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "d") == 4)
        #expect(cache.value(for: "b") == nil)
    }

    @Test("AKASHIC-CT-028 purge reports exact count and cost")
    func purgeAccounting() {
        let cache = MemoryCache<Int, String>(costLimit: 100)
        cache.insert("one", for: 1, cost: 10)
        cache.insert("two", for: 2, cost: 20)
        cache.insert("three", for: 3, cost: 30)

        let summary = cache.removeAllAndReport()

        #expect(summary.itemCount == 3)
        #expect(summary.costBytes == 60)
        #expect(cache.count == 0)
        #expect(cache.currentCost == 0)
    }

    @Test("Oversized insertion is rejected and replaces existing key with miss")
    func oversizedInsertion() {
        let cache = MemoryCache<String, Int>(costLimit: 4)
        cache.insert(1, for: "key", cost: 2)
        #expect(cache.value(for: "key") == 1)

        cache.insert(2, for: "key", cost: 5)

        #expect(cache.value(for: "key") == nil)
        #expect(cache.currentCost == 0)
        #expect(cache.count == 0)
    }

    @Test("AKASHIC-CT-028 limit changes report exact removal")
    func limitChangeAccounting() {
        let cache = MemoryCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 4)
        cache.insert(2, for: "b", cost: 3)
        cache.insert(3, for: "c", cost: 2)
        #expect(cache.value(for: "a") == 1)

        let shrink = cache.updateCostLimit(5)
        #expect(shrink == MemoryCacheRemovalSummary(itemCount: 2, costBytes: 5))
        #expect(cache.currentCost == 4)
        #expect(cache.count == 1)
        #expect(cache.value(for: "a") == 1)

        #expect(cache.updateCostLimit(20) == MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0))
        let minimum = cache.updateCostLimit(0)
        #expect(minimum == MemoryCacheRemovalSummary(itemCount: 1, costBytes: 4))
        #expect(cache.currentCost == 0)
        #expect(cache.count == 0)
    }

    @Test("Concurrent operations preserve declared bounds")
    func concurrentOperations() async {
        let cache = MemoryCache<Int, Int>(costLimit: 128)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for offset in 0..<1_000 {
                        let key = (worker * 1_000) + offset
                        cache.insert(key, for: key, cost: 1)
                        _ = cache.value(for: key)
                        if offset.isMultiple(of: 3) {
                            cache.remove(key)
                        }
                    }
                }
            }
        }

        #expect(cache.currentCost <= 128)
        #expect(cache.count <= 128)
    }
}

@Suite("AkashicMemory reference differential")
struct MemoryCacheReferenceDifferentialTests {
    @Test("AKASHIC-CT-027 seeded SIEVE reference-model differential")
    func seededReferenceModelDifferential() {
        let initialCostLimit = 17
        for seed in 1...32 {
            let cache = MemoryCache<Int, String>(costLimit: initialCostLimit)
            var model = ReferenceSIEVE<Int, String>(costLimit: initialCostLimit)
            var generator = DeterministicGenerator(seed: UInt64(seed))
            var currentLimit = initialCostLimit

            for step in 0..<800 {
                let key = generator.nextInt(upperBound: 23)
                let action = generator.nextInt(upperBound: 100)
                if action < 45 {
                    let cost = generator.nextInt(upperBound: 25) + 1
                    let value = "seed-\(seed)-step-\(step)"
                    cache.insert(value, for: key, cost: cost)
                    model.insert(value, for: key, cost: cost)
                } else if action < 75 {
                    #expect(
                        cache.value(for: key) == model.value(for: key),
                        "seed=\(seed) step=\(step) key=\(key)"
                    )
                } else if action < 90 {
                    cache.remove(key)
                    model.remove(key)
                } else if action < 96 {
                    currentLimit = generator.nextInt(upperBound: 24) + 1
                    #expect(
                        cache.updateCostLimit(currentLimit)
                            == model.updateCostLimit(currentLimit),
                        "limit seed=\(seed) step=\(step)"
                    )
                } else {
                    cache.removeAll()
                    model.removeAll()
                }

                if step.isMultiple(of: 40) {
                    for auditKey in 0..<23 {
                        #expect(
                            cache.value(for: auditKey) == model.value(for: auditKey),
                            "audit seed=\(seed) step=\(step) key=\(auditKey)"
                        )
                    }
                }
                #expect(cache.currentCost == model.currentCost)
                #expect(cache.count == model.count)
                #expect(cache.currentCost <= currentLimit)
            }
        }
    }
}


@Suite("AkashicMemory concurrent reference history")
struct MemoryCacheConcurrentReferenceTests {
    @Test("AKASHIC-CT-027 generated commuting concurrent history matches reference")
    func generatedConcurrentReferenceHistory() async {
        let workerCount = 16
        let operationsPerWorker = 400
        let cache = MemoryCache<Int, Int>(
            costLimit: workerCount * operationsPerWorker
        )

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    let base = worker * 10_000
                    for step in 0..<operationsPerWorker {
                        let key = base + step
                        cache.insert(key * 3, for: key, cost: 1)
                        #expect(cache.value(for: key) == key * 3)
                        if step.isMultiple(of: 4) {
                            cache.remove(key)
                        }
                    }
                }
            }
        }

        var expectedCount = 0
        for worker in 0..<workerCount {
            let base = worker * 10_000
            for step in 0..<operationsPerWorker {
                let key = base + step
                let expected = step.isMultiple(of: 4) ? nil : key * 3
                #expect(cache.value(for: key) == expected)
                if expected != nil { expectedCount += 1 }
            }
        }
        #expect(cache.count == expectedCount)
        #expect(cache.currentCost == expectedCount)
    }
}

private struct ReferenceSIEVE<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var visited: Bool
    }

    private var costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var hand: Key?
    private(set) var currentCost = 0

    init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
    }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = entries[key]?.value else { return nil }
        entries[key]?.visited = true
        return value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        remove(key)
        let normalized = max(1, cost)
        guard normalized <= costLimit else { return }
        while currentCost > costLimit - normalized {
            guard let victim = victim() else { break }
            remove(victim)
        }
        entries[key] = Entry(value: value, cost: normalized, visited: false)
        order.append(key)
        currentCost += normalized
    }

    mutating func remove(_ key: Key) {
        guard let entry = entries[key], let index = order.firstIndex(of: key) else { return }
        if hand == key {
            if order.count == 1 {
                hand = nil
            } else {
                hand = index + 1 < order.count
                    ? order[index + 1]
                    : order.first(where: { $0 != key })
            }
        }
        entries.removeValue(forKey: key)
        order.remove(at: index)
        if let hand, entries[hand] == nil { self.hand = order.first }
        currentCost -= entry.cost
    }

    mutating func updateCostLimit(_ newLimit: Int) -> MemoryCacheRemovalSummary {
        costLimit = max(1, newLimit)
        let initialCount = entries.count
        let initialCost = currentCost
        while currentCost > costLimit {
            guard let victim = victim() else { break }
            remove(victim)
        }
        return MemoryCacheRemovalSummary(
            itemCount: initialCount - entries.count,
            costBytes: initialCost - currentCost
        )
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        hand = nil
        currentCost = 0
    }

    private mutating func victim() -> Key? {
        guard !order.isEmpty else { return nil }
        if hand == nil || entries[hand!] == nil { hand = order.first }
        while let candidate = hand,
            var entry = entries[candidate],
            let index = order.firstIndex(of: candidate)
        {
            let next = index + 1 < order.count ? order[index + 1] : order.first
            if entry.visited {
                entry.visited = false
                entries[candidate] = entry
                hand = next
            } else {
                hand = next == candidate ? nil : next
                return candidate
            }
        }
        return order.first
    }
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}
