import AkashicMemory
import Foundation
import Testing

extension MemoryCacheRevocationAwareEvictionPlannerTests {
    func restartOracle(
        cache: MemoryCache<Int, Int>,
        provisionalVisitedKeys: Set<Int>,
        incomingCost: Int
    ) -> RestartResult {
        var provisional = provisionalVisitedKeys
        var revocations: [Int] = []
        while true {
            let trace = cache.resourceProbeEvictionTrace(incomingCost: incomingCost)
            if let key = trace.clearedVisitedKeys.first(where: provisional.contains) {
                precondition(cache.resourceProbeClearVisited(for: key))
                provisional.remove(key)
                revocations.append(key)
                continue
            }
            return RestartResult(
                victims: trace.victims.map(\.key),
                victimCosts: trace.victims.map(\.cost),
                revocations: revocations,
                finalEpochResetCount: trace.fullVisitedEpochResetCount
            )
        }
    }

    /// Exact control-flow model of production `insertLocked` after package admission has applied
    /// the plan's provisional revocations. A full-visited epoch reset is O(1) in production and
    /// therefore clears the model's visited set without charging ring-slot inspections. Every
    /// candidate actually examined by `nextSieveVictimLocked` charges one slot.
    func productionMutationModel(
        costs: [Int],
        ternary: [Int],
        provisionalRevocations: [Int],
        incomingCost: Int
    ) -> ProductionMutationModelResult {
        precondition(costs.count == ternary.count)
        var ring = Array(costs.indices)
        var visited = Set(ternary.indices.filter { ternary[$0] != 0 })
        for key in provisionalRevocations { visited.remove(key) }

        let totalCost = costs.reduce(0, +)
        let normalizedIncomingCost = max(1, incomingCost)
        precondition(normalizedIncomingCost <= totalCost)
        let maximumExistingCost = totalCost - normalizedIncomingCost
        var currentCost = totalCost
        var cursor = 0
        var victims: [Int] = []
        var inspectedSlotCount = 0

        while currentCost > maximumExistingCost, !ring.isEmpty {
            if ring.allSatisfy({ visited.contains($0) }) {
                // Mirrors `advanceVisitEpochLocked`: no resident walk is charged to the production
                // mutation path when every current resident is visited.
                visited.removeAll(keepingCapacity: true)
            }

            while !ring.isEmpty {
                if cursor >= ring.count { cursor = 0 }
                let key = ring[cursor]
                inspectedSlotCount += 1
                if visited.remove(key) != nil {
                    cursor += 1
                    if cursor >= ring.count { cursor = 0 }
                    continue
                }

                victims.append(key)
                currentCost -= costs[key]
                ring.remove(at: cursor)
                if ring.isEmpty {
                    cursor = 0
                } else if cursor >= ring.count {
                    cursor = 0
                }
                break
            }
        }

        return .init(victims: victims, inspectedSlotCount: inspectedSlotCount)
    }

    func makeCache(costs: [Int], ternary: [Int]) -> MemoryCache<Int, Int> {
        precondition(costs.count == ternary.count)
        let cache = MemoryCache<Int, Int>(costLimit: costs.reduce(0, +))
        for (key, cost) in costs.enumerated() {
            cache.insert(key, for: key, cost: cost)
        }
        for key in ternary.indices where ternary[key] != 0 {
            precondition(cache.resourceProbeMarkVisited(for: key))
        }
        return cache
    }

    func movedHandFixture() -> MemoryCache<Int, Int> {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        precondition(cache.resourceProbeMarkVisited(for: 0))
        cache.insert(4, for: 4, cost: 1)
        precondition(cache.resourceProbeValueWithoutVisit(for: 1) == nil)
        for key in [0, 2, 3, 4] {
            precondition(cache.resourceProbeMarkVisited(for: key))
        }
        return cache
    }

    func movedAllVisitedUniformFixture() -> MemoryCache<Int, Int> {
        let cache = MemoryCache<Int, Int>(costLimit: 8)
        for key in 0..<8 { cache.insert(key, for: key, cost: 1) }
        for key in 0..<3 { precondition(cache.value(for: key) == key) }
        cache.insert(8, for: 8, cost: 1)
        precondition(cache.resourceProbeValueWithoutVisit(for: 3) == nil)
        for key in [0, 1, 2, 4, 5, 6, 7, 8] {
            precondition(cache.value(for: key) == key)
        }
        return cache
    }

    func decodeTernary(_ value: Int, digits: Int) -> [Int] {
        var value = value
        var result = [Int](repeating: 0, count: digits)
        for index in 0..<digits {
            result[index] = value % 3
            value /= 3
        }
        return result
    }

    func intPow(_ base: Int, _ exponent: Int) -> Int {
        var result = 1
        for _ in 0..<exponent { result *= base }
        return result
    }
}
