import AkashicMemory
import Foundation

private struct ShardedPlannerReplayKey: Hashable, Sendable {
    let id: Int
}

private struct ShardedPlannerReplaySnapshot: Codable {
    let totalCostLimit: Int
    let currentCost: Int
    let globalUnassignedCost: Int
    let shardCurrentCosts: [Int]
    let shardResidentCounts: [Int]
    let exactBudgetAccounting: Bool
}

private struct ShardedPlannerReplayCase: Codable {
    let name: String
    let donorVictimPrefixes: [[Int]]
    let deficit: Int
    let expectedHeuristicReleasedCost: Int
    let exactPrefixOracleReleasedCost: Int
    let snapshots: [ShardedPlannerReplaySnapshot]
    let survivingKeysByDonor: [[Int]]
    let incomingResident: Bool
    let observedReleasedCost: Int
    let observedAvoidableReleasedCost: Int
    let allChecksPass: Bool
}

private struct ShardedPlannerReplayReport: Codable {
    struct Claims: Codable {
        let actualShardedCacheReplayEvaluated: Bool
        let localSIEVEPrefixOrderEvaluated: Bool
        let crossShardSelectorEvaluated: Bool
        let exactPrefixOracleImplementedInCache: Bool
        let concurrentContentionEvaluated: Bool
        let formalPerformance: Bool
        let productionPlannerRecommendation: Bool
        let admissionPolicyEvaluated: Bool
        let diskSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let cases: [ShardedPlannerReplayCase]
    let allCasesPass: Bool
    let uniqueBestUnderCounterexampleReplayed: Bool
    let equalCostTieSuccessorControlReplayed: Bool
    let claims: Claims
}

enum MemoryShardedVictimPlannerReplayProbe {
    static func run() throws {
        let counterexample = replay(
            name: "unique-best-under-real-cache-counterexample",
            donorVictimPrefixes: [
                [7, 7],
                [6, 4],
            ],
            incomingCost: 10,
            expectedHeuristicReleasedCost: 13,
            exactPrefixOracleReleasedCost: 10,
            expectedSurvivorCosts: [
                [7],
                [4],
            ]
        )
        let tieControl = replay(
            name: "equal-cost-successor-lookahead-real-cache-control",
            donorVictimPrefixes: [
                [6, 6],
                [6, 4],
            ],
            incomingCost: 10,
            expectedHeuristicReleasedCost: 10,
            exactPrefixOracleReleasedCost: 10,
            expectedSurvivorCosts: [
                [6, 6],
                [],
            ]
        )
        let cases = [counterexample, tieControl]
        let allCasesPass = cases.allSatisfy(\.allChecksPass)
        let report = ShardedPlannerReplayReport(
            schemaVersion: 1,
            cases: cases,
            allCasesPass: allCasesPass,
            uniqueBestUnderCounterexampleReplayed:
                counterexample.observedReleasedCost == 13
                && counterexample.observedAvoidableReleasedCost == 3,
            equalCostTieSuccessorControlReplayed:
                tieControl.observedReleasedCost == 10
                && tieControl.observedAvoidableReleasedCost == 0,
            claims: .init(
                actualShardedCacheReplayEvaluated: true,
                localSIEVEPrefixOrderEvaluated: true,
                crossShardSelectorEvaluated: true,
                exactPrefixOracleImplementedInCache: false,
                concurrentContentionEvaluated: false,
                formalPerformance: false,
                productionPlannerRecommendation: false,
                admissionPolicyEvaluated: false,
                diskSemantics: false,
                foveaBusinessSemantics: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allCasesPass,
              report.uniqueBestUnderCounterexampleReplayed,
              report.equalCostTieSuccessorControlReplayed
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func replay(
        name: String,
        donorVictimPrefixes: [[Int]],
        incomingCost: Int,
        expectedHeuristicReleasedCost: Int,
        exactPrefixOracleReleasedCost: Int,
        expectedSurvivorCosts: [[Int]]
    ) -> ShardedPlannerReplayCase {
        precondition(donorVictimPrefixes.count == 2)
        precondition(expectedSurvivorCosts.count == 2)
        let totalCostLimit = donorVictimPrefixes.flatMap { $0 }.reduce(0, +)
        let cache = ShardedMemoryCache<ShardedPlannerReplayKey, Int>(
            costLimit: totalCostLimit,
            shardCount: 4
        )
        var cursor = 10_000_000 + totalCostLimit * 1_000
        var donorKeys: [[ShardedPlannerReplayKey]] = []
        for (offset, prefix) in donorVictimPrefixes.enumerated() {
            let shard = offset + 1
            let keys = keys(forShard: shard, count: prefix.count, startingAt: cursor)
            cursor = keys.last!.id + 1
            donorKeys.append(keys)
            for (index, key) in keys.enumerated() {
                cache.insert(prefix[index], for: key, cost: prefix[index])
            }
        }
        let before = snapshot(cache)
        precondition(before.currentCost == totalCostLimit)
        precondition(before.globalUnassignedCost == 0)
        let incoming = keys(forShard: 0, count: 1, startingAt: cursor).first!
        cache.insert(incomingCost, for: incoming, cost: incomingCost)
        let after = snapshot(cache)

        let survivingKeysByDonor = donorKeys.map { keys in
            keys.filter { cache.value(for: $0) != nil }.map(\.id)
        }
        let observedSurvivorCosts = donorKeys.enumerated().map { donor, keys in
            keys.enumerated().compactMap { index, key in
                cache.value(for: key) == nil ? nil : donorVictimPrefixes[donor][index]
            }
        }
        let observedReleasedCost = totalCostLimit + incomingCost - after.currentCost
        let observedAvoidable = observedReleasedCost - exactPrefixOracleReleasedCost
        let checks = [
            before.exactBudgetAccounting,
            after.exactBudgetAccounting,
            after.currentCost == totalCostLimit - expectedHeuristicReleasedCost + incomingCost,
            after.globalUnassignedCost == expectedHeuristicReleasedCost - incomingCost,
            cache.value(for: incoming) != nil,
            observedReleasedCost == expectedHeuristicReleasedCost,
            observedSurvivorCosts == expectedSurvivorCosts,
            observedAvoidable == expectedHeuristicReleasedCost - exactPrefixOracleReleasedCost,
        ]
        return ShardedPlannerReplayCase(
            name: name,
            donorVictimPrefixes: donorVictimPrefixes,
            deficit: incomingCost,
            expectedHeuristicReleasedCost: expectedHeuristicReleasedCost,
            exactPrefixOracleReleasedCost: exactPrefixOracleReleasedCost,
            snapshots: [before, after],
            survivingKeysByDonor: survivingKeysByDonor,
            incomingResident: cache.value(for: incoming) != nil,
            observedReleasedCost: observedReleasedCost,
            observedAvoidableReleasedCost: observedAvoidable,
            allChecksPass: checks.allSatisfy { $0 }
        )
    }

    private static func snapshot(
        _ cache: ShardedMemoryCache<ShardedPlannerReplayKey, Int>
    ) -> ShardedPlannerReplaySnapshot {
        let raw = cache.resourceProbeBudgetSnapshot()
        return ShardedPlannerReplaySnapshot(
            totalCostLimit: raw.totalCostLimit,
            currentCost: raw.currentCost,
            globalUnassignedCost: raw.globalUnassignedCost,
            shardCurrentCosts: raw.shardCurrentCosts,
            shardResidentCounts: raw.shardResidentCounts,
            exactBudgetAccounting:
                raw.currentCost + raw.globalUnassignedCost == raw.totalCostLimit
                && raw.shardCurrentCosts.reduce(0, +) == raw.currentCost
        )
    }

    private static func keys(
        forShard desiredShard: Int,
        count: Int,
        startingAt start: Int
    ) -> [ShardedPlannerReplayKey] {
        var result: [ShardedPlannerReplayKey] = []
        var candidateID = start
        while result.count < count {
            let key = ShardedPlannerReplayKey(id: candidateID)
            if shardIndex(for: key) == desiredShard { result.append(key) }
            candidateID += 1
        }
        return result
    }

    private static func shardIndex(for key: ShardedPlannerReplayKey) -> Int {
        let bits = UInt(bitPattern: key.hashValue)
        return Int(bits & 3)
    }
}
