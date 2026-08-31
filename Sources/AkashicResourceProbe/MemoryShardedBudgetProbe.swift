import AkashicMemory
import Foundation

private struct ShardedBudgetProbeKey: Hashable, Sendable {
    let id: Int
}

private struct ShardedBudgetProbeSnapshot: Codable {
    let totalCostLimit: Int
    let currentCost: Int
    let globalUnassignedCost: Int
    let shardCurrentCosts: [Int]
    let shardAssignedLimits: [Int]
    let shardResidentCounts: [Int]
    let currentPlusUnassignedEqualsLimit: Bool
    let shardCurrentSumExact: Bool
    let stableAssignedLimitsEqualResidents: Bool
}

private struct ShardedBudgetProbeCase: Codable {
    let name: String
    let snapshots: [ShardedBudgetProbeSnapshot]
    let integerMetrics: [String: Int]
    let booleanChecks: [String: Bool]
}

private struct ShardedBudgetProbeReport: Codable {
    struct Claims: Codable {
        let sharedGlobalBudgetEvaluated: Bool
        let victimGranularityEvaluated: Bool
        let concurrentContentionEvaluated: Bool
        let formalPerformance: Bool
        let productionShardCountRecommendation: Bool
        let admissionPolicyEvaluated: Bool
        let diskSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let shardCount: Int
    let costLimit: Int
    let cases: [ShardedBudgetProbeCase]
    let allBudgetSnapshotsExact: Bool
    let allCaseChecksPass: Bool
    let claims: Claims
}

enum MemoryShardedBudgetProbe {
    private static let shardCount = 8
    private static let costLimit = 1_024

    static func run() throws {
        let cases = [
            hashSkewConsumesFullGlobalBudget(),
            crossShardDeficitUsesRealDonorCapacity(),
            oneByteDeficitVictimGranularity(),
            repeatedHashSkewPhaseShift(),
            shrinkExpandReestablishesBudget(),
            oversizedReplacementRemovesOnlyTargetKey(),
        ]
        let allBudgetSnapshotsExact = cases
            .flatMap(\.snapshots)
            .allSatisfy {
                $0.currentPlusUnassignedEqualsLimit
                    && $0.shardCurrentSumExact
                    && $0.stableAssignedLimitsEqualResidents
            }
        let allCaseChecksPass = cases.allSatisfy { $0.booleanChecks.values.allSatisfy { $0 } }
        let report = ShardedBudgetProbeReport(
            schemaVersion: 1,
            shardCount: shardCount,
            costLimit: costLimit,
            cases: cases,
            allBudgetSnapshotsExact: allBudgetSnapshotsExact,
            allCaseChecksPass: allCaseChecksPass,
            claims: .init(
                sharedGlobalBudgetEvaluated: true,
                victimGranularityEvaluated: true,
                concurrentContentionEvaluated: false,
                formalPerformance: false,
                productionShardCountRecommendation: false,
                admissionPolicyEvaluated: false,
                diskSemantics: false,
                foveaBusinessSemantics: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allBudgetSnapshotsExact, allCaseChecksPass else {
            throw ProbeError.resourceSampleFailed
        }
    }

    private static func hashSkewConsumesFullGlobalBudget() -> ShardedBudgetProbeCase {
        let cache = ShardedMemoryCache<ShardedBudgetProbeKey, Int>(
            costLimit: costLimit,
            shardCount: shardCount
        )
        let keys = keys(forShard: 0, count: 256, startingAt: 0)
        for (index, key) in keys.enumerated() {
            cache.insert(index, for: key, cost: 4)
        }
        let snapshot = snapshot(cache)
        return ShardedBudgetProbeCase(
            name: "single-shard-skew-consumes-full-global-budget",
            snapshots: [snapshot],
            integerMetrics: [
                "insertedItems": keys.count,
                "targetShardResidentBytes": snapshot.shardCurrentCosts[0],
                "otherShardResidentBytes": snapshot.shardCurrentCosts.dropFirst().reduce(0, +),
            ],
            booleanChecks: [
                "full-global-budget-usable-by-one-shard": snapshot.currentCost == costLimit,
                "target-shard-owns-full-budget": snapshot.shardCurrentCosts[0] == costLimit,
                "other-shards-empty": snapshot.shardCurrentCosts.dropFirst().allSatisfy { $0 == 0 },
                "no-unassigned-capacity-remains": snapshot.globalUnassignedCost == 0,
                "all-inserted-keys-resident": keys.allSatisfy { cache.value(for: $0) != nil },
            ]
        )
    }

    private static func crossShardDeficitUsesRealDonorCapacity() -> ShardedBudgetProbeCase {
        let cache = ShardedMemoryCache<ShardedBudgetProbeKey, Int>(
            costLimit: costLimit,
            shardCount: shardCount
        )
        var cursor = 100_000
        var seeded: [[ShardedBudgetProbeKey]] = []
        for shard in 0..<shardCount {
            let keys = keys(forShard: shard, count: 32, startingAt: cursor)
            cursor = keys.last!.id + 1
            seeded.append(keys)
            for key in keys { cache.insert(key.id, for: key, cost: 4) }
        }
        let before = snapshot(cache)
        let incoming = keys(forShard: 0, count: 1, startingAt: cursor).first!
        cache.insert(incoming.id, for: incoming, cost: 256)
        let after = snapshot(cache)
        let survivingSeeded = seeded.flatMap { $0 }.count(where: { cache.value(for: $0) != nil })
        return ShardedBudgetProbeCase(
            name: "cross-shard-deficit-releases-real-donor-capacity",
            snapshots: [before, after],
            integerMetrics: [
                "preInsertResidentBytes": before.currentCost,
                "postInsertResidentBytes": after.currentCost,
                "incomingCost": 256,
                "survivingSeededItems": survivingSeeded,
                "evictedSeededItems": 256 - survivingSeeded,
            ],
            booleanChecks: [
                "precondition-full": before.currentCost == costLimit,
                "incoming-resident": cache.value(for: incoming) != nil,
                "target-shard-now-owns-incoming-cost": after.shardCurrentCosts[0] == 256,
                "global-budget-still-full": after.currentCost == costLimit,
                "exact-64-small-items-evicted": survivingSeeded == 192,
            ]
        )
    }

    private static func oneByteDeficitVictimGranularity() -> ShardedBudgetProbeCase {
        let mixed = makeOneByteDeficitCache(allDonorsLarge: false, startingAt: 300_000)
        let allLarge = makeOneByteDeficitCache(allDonorsLarge: true, startingAt: 500_000)
        let mixedBefore = snapshot(mixed.cache)
        let largeBefore = snapshot(allLarge.cache)
        mixed.cache.insert(mixed.incoming.id, for: mixed.incoming, cost: 129)
        allLarge.cache.insert(allLarge.incoming.id, for: allLarge.incoming, cost: 129)
        let mixedAfter = snapshot(mixed.cache)
        let largeAfter = snapshot(allLarge.cache)
        return ShardedBudgetProbeCase(
            name: "one-byte-deficit-exposes-victim-granularity-frontier",
            snapshots: [mixedBefore, mixedAfter, largeBefore, largeAfter],
            integerMetrics: [
                "deficitBytes": 1,
                "mixedSmallDonorFinalResidentBytes": mixedAfter.currentCost,
                "mixedSmallDonorUnassignedBytes": mixedAfter.globalUnassignedCost,
                "allLargeDonorFinalResidentBytes": largeAfter.currentCost,
                "allLargeDonorUnassignedBytes": largeAfter.globalUnassignedCost,
                "avoidableVsUnavoidableResidentByteDelta": mixedAfter.currentCost - largeAfter.currentCost,
            ],
            booleanChecks: [
                "both-start-full": mixedBefore.currentCost == costLimit && largeBefore.currentCost == costLimit,
                "both-incoming-values-resident": mixed.cache.value(for: mixed.incoming) != nil
                    && allLarge.cache.value(for: allLarge.incoming) != nil,
                "mixed-granularity-releases-128-plus-4": mixedAfter.currentCost == 1_021
                    && mixedAfter.globalUnassignedCost == 3,
                "all-large-donors-force-two-128-byte-releases": largeAfter.currentCost == 897
                    && largeAfter.globalUnassignedCost == 127,
                "victim-granularity-explains-124-byte-utilization-gap": mixedAfter.currentCost - largeAfter.currentCost == 124,
            ]
        )
    }

    private static func repeatedHashSkewPhaseShift() -> ShardedBudgetProbeCase {
        let cache = ShardedMemoryCache<ShardedBudgetProbeKey, Int>(
            costLimit: costLimit,
            shardCount: shardCount
        )
        var snapshots: [ShardedBudgetProbeSnapshot] = []
        var cursor = 800_000
        for phase in 0..<64 {
            let shard = phase % shardCount
            let keys = keys(forShard: shard, count: 256, startingAt: cursor)
            cursor = keys.last!.id + 1
            for key in keys { cache.insert(key.id, for: key, cost: 4) }
            snapshots.append(snapshot(cache))
        }
        return ShardedBudgetProbeCase(
            name: "repeated-hash-skew-phase-shift-has-no-budget-drift",
            snapshots: snapshots,
            integerMetrics: [
                "phaseCount": snapshots.count,
                "minimumResidentBytes": snapshots.map(\.currentCost).min() ?? 0,
                "maximumResidentBytes": snapshots.map(\.currentCost).max() ?? 0,
                "maximumUnassignedBytes": snapshots.map(\.globalUnassignedCost).max() ?? 0,
            ],
            booleanChecks: [
                "every-phase-remains-full": snapshots.allSatisfy { $0.currentCost == costLimit },
                "no-stable-boundary-budget-drift": snapshots.allSatisfy { $0.globalUnassignedCost == 0 },
            ]
        )
    }

    private static func shrinkExpandReestablishesBudget() -> ShardedBudgetProbeCase {
        let cache = ShardedMemoryCache<ShardedBudgetProbeKey, Int>(
            costLimit: costLimit,
            shardCount: shardCount
        )
        let initialKeys = keysSpreadAcrossShards(perShard: 32, startingAt: 1_200_000)
        for key in initialKeys { cache.insert(key.id, for: key, cost: 4) }
        let full = snapshot(cache)
        let removal = cache.updateCostLimit(513)
        let shrunk = snapshot(cache)
        let expandRemoval = cache.updateCostLimit(costLimit)
        let expanded = snapshot(cache)
        let refill = keysSpreadAcrossShards(perShard: 16, startingAt: 1_600_000)
        for key in refill { cache.insert(key.id, for: key, cost: 4) }
        let refilled = snapshot(cache)
        return ShardedBudgetProbeCase(
            name: "shrink-expand-reestablishes-explainable-global-budget",
            snapshots: [full, shrunk, expanded, refilled],
            integerMetrics: [
                "shrinkReportedItems": removal.itemCount,
                "shrinkReportedBytes": removal.costBytes,
                "shrunkResidentBytes": shrunk.currentCost,
                "shrunkUnassignedBytes": shrunk.globalUnassignedCost,
                "expandReportedItems": expandRemoval.itemCount,
                "expandReportedBytes": expandRemoval.costBytes,
                "expandedResidentBytes": expanded.currentCost,
                "expandedUnassignedBytes": expanded.globalUnassignedCost,
                "refilledResidentBytes": refilled.currentCost,
            ],
            booleanChecks: [
                "initial-full": full.currentCost == 1_024,
                "shrink-removes-exact-512-bytes": removal.itemCount == 128 && removal.costBytes == 512,
                "four-byte-granularity-leaves-one-byte-spare": shrunk.totalCostLimit == 513
                    && shrunk.currentCost == 512 && shrunk.globalUnassignedCost == 1,
                "expand-does-not-evict": expandRemoval.itemCount == 0 && expandRemoval.costBytes == 0,
                "expand-restores-512-byte-spare": expanded.totalCostLimit == 1_024
                    && expanded.currentCost == 512 && expanded.globalUnassignedCost == 512,
                "refill-uses-all-restored-capacity": refilled.currentCost == 1_024
                    && refilled.globalUnassignedCost == 0,
            ]
        )
    }

    private static func oversizedReplacementRemovesOnlyTargetKey() -> ShardedBudgetProbeCase {
        let cache = ShardedMemoryCache<ShardedBudgetProbeKey, Int>(
            costLimit: costLimit,
            shardCount: shardCount
        )
        let keys = keysSpreadAcrossShards(perShard: 32, startingAt: 2_000_000)
        for key in keys { cache.insert(key.id, for: key, cost: 4) }
        let target = keys[0]
        let before = snapshot(cache)
        cache.insert(-1, for: target, cost: costLimit + 1)
        let after = snapshot(cache)
        let survivingNonTarget = keys.dropFirst().count(where: { cache.value(for: $0) != nil })
        return ShardedBudgetProbeCase(
            name: "oversized-replacement-does-not-evict-unrelated-shards",
            snapshots: [before, after],
            integerMetrics: [
                "residentBytesBefore": before.currentCost,
                "residentBytesAfter": after.currentCost,
                "survivingNonTargetItems": survivingNonTarget,
            ],
            booleanChecks: [
                "precondition-full": before.currentCost == costLimit,
                "oversized-target-is-miss": cache.value(for: target) == nil,
                "only-target-cost-released": after.currentCost == costLimit - 4
                    && after.globalUnassignedCost == 4,
                "all-unrelated-items-survive": survivingNonTarget == keys.count - 1,
            ]
        )
    }

    private static func makeOneByteDeficitCache(
        allDonorsLarge: Bool,
        startingAt start: Int
    ) -> (cache: ShardedMemoryCache<ShardedBudgetProbeKey, Int>, incoming: ShardedBudgetProbeKey) {
        let cache = ShardedMemoryCache<ShardedBudgetProbeKey, Int>(
            costLimit: costLimit,
            shardCount: shardCount
        )
        var cursor = start
        if allDonorsLarge {
            // Keep the target shard empty and fill the other seven shards with exactly 8 x 128B.
            // Shard 1 owns two objects so aggregate resident cost is the full 1,024B.
            for shard in 1..<shardCount {
                let objectCount = shard == 1 ? 2 : 1
                let keys = keys(forShard: shard, count: objectCount, startingAt: cursor)
                cursor = keys.last!.id + 1
                for key in keys { cache.insert(key.id, for: key, cost: 128) }
            }
        } else {
            // Same full global occupancy, but expose one 4B donor granularity. Greedy best-under
            // first releases a 128B victim for the 129B deficit, then the 4B shard can satisfy the
            // remaining 1B without forcing a second 128B release.
            let smallKeys = keys(forShard: 1, count: 32, startingAt: cursor)
            cursor = smallKeys.last!.id + 1
            for key in smallKeys { cache.insert(key.id, for: key, cost: 4) }
            for shard in 2..<shardCount {
                let objectCount = shard == 2 ? 2 : 1
                let keys = keys(forShard: shard, count: objectCount, startingAt: cursor)
                cursor = keys.last!.id + 1
                for key in keys { cache.insert(key.id, for: key, cost: 128) }
            }
        }
        precondition(cache.currentCost == costLimit)
        let incoming = keys(forShard: 0, count: 1, startingAt: cursor).first!
        return (cache, incoming)
    }

    private static func keysSpreadAcrossShards(
        perShard: Int,
        startingAt start: Int
    ) -> [ShardedBudgetProbeKey] {
        var result: [ShardedBudgetProbeKey] = []
        var cursor = start
        for shard in 0..<shardCount {
            let keys = keys(forShard: shard, count: perShard, startingAt: cursor)
            result.append(contentsOf: keys)
            cursor = keys.last!.id + 1
        }
        return result
    }

    private static func keys(
        forShard desiredShard: Int,
        count: Int,
        startingAt start: Int
    ) -> [ShardedBudgetProbeKey] {
        var result: [ShardedBudgetProbeKey] = []
        var candidateID = start
        while result.count < count {
            let key = ShardedBudgetProbeKey(id: candidateID)
            if shardIndex(for: key) == desiredShard { result.append(key) }
            candidateID += 1
        }
        return result
    }

    private static func shardIndex(for key: ShardedBudgetProbeKey) -> Int {
        let bits = UInt(bitPattern: key.hashValue)
        return Int(bits & UInt(shardCount - 1))
    }

    private static func snapshot(
        _ cache: ShardedMemoryCache<ShardedBudgetProbeKey, Int>
    ) -> ShardedBudgetProbeSnapshot {
        let raw = cache.resourceProbeBudgetSnapshot()
        let sum = raw.shardCurrentCosts.reduce(0, +)
        return ShardedBudgetProbeSnapshot(
            totalCostLimit: raw.totalCostLimit,
            currentCost: raw.currentCost,
            globalUnassignedCost: raw.globalUnassignedCost,
            shardCurrentCosts: raw.shardCurrentCosts,
            shardAssignedLimits: raw.shardAssignedLimits,
            shardResidentCounts: raw.shardResidentCounts,
            currentPlusUnassignedEqualsLimit:
                raw.currentCost + raw.globalUnassignedCost == raw.totalCostLimit,
            shardCurrentSumExact: sum == raw.currentCost,
            stableAssignedLimitsEqualResidents:
                raw.shardCurrentCosts == raw.shardAssignedLimits
        )
    }
}
