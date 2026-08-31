import Foundation

private enum ShardedPlannerChallengerKind: String, Codable, CaseIterable {
    case current = "current-equal-best-under-successor-tie"
    case allUnderSameShardExact = "all-under-one-successor-exact"
    case anyTwoLegalExact = "any-two-legal-exact"
}

private struct ShardedPlannerChallengerPlan: Equatable {
    let removedCost: Int
    let removedItems: Int
    let prefixLengths: [Int]
}

private struct ShardedPlannerChallengerResult: Codable {
    let challenger: String
    let suboptimalCaseCount: Int
    let suboptimalCaseRatio: Double
    let currentSuboptimalCasesFixed: Int
    let currentSuboptimalCasesFixedRatio: Double
    let regressionCaseCountVersusCurrent: Int
    let maximumAvoidableReleasedBytes: Int
    let maximumOvershoot: Int
}

private struct ShardedPlannerChallengerCorpus: Codable {
    let name: String
    let shardCount: Int
    let victimDepthPerShard: Int
    let costAlphabet: [Int]
    let deficitRange: [Int]
    let caseCount: Int
    let currentSuboptimalCaseCount: Int
    let challengers: [ShardedPlannerChallengerResult]
}

private struct ShardedPlannerChallengerReport: Codable {
    struct Claims: Codable {
        let deterministicPlannerModelsEvaluated: Bool
        let actualCacheReplayEvaluated: Bool
        let concurrentContentionEvaluated: Bool
        let formalPerformance: Bool
        let productionPlannerRecommendation: Bool
        let diskSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let corpora: [ShardedPlannerChallengerCorpus]
    let allChallengersNonRegressingInReleasedBytes: Bool
    let boundedChallengersLeaveResidualOracleGap: Bool
    let claims: Claims
}

enum MemoryShardedVictimPlannerChallengerProbe {
    static func run() throws {
        let corpora = [
            evaluateCorpus(
                name: "two-shards-depth2-cost1to8",
                shardCount: 2,
                depth: 2,
                costs: Array(1...8),
                deficits: Array(1...16)
            ),
            evaluateCorpus(
                name: "three-shards-depth2-powers-and-neighbors",
                shardCount: 3,
                depth: 2,
                costs: [1, 2, 3, 4, 6, 8],
                deficits: Array(1...16)
            ),
        ]
        let allChallengersNonRegressingInReleasedBytes = corpora.allSatisfy { corpus in
            corpus.challengers.allSatisfy { $0.regressionCaseCountVersusCurrent == 0 }
        }
        let boundedChallengersLeaveResidualOracleGap = corpora.allSatisfy { corpus in
            corpus.challengers
                .filter { $0.challenger != ShardedPlannerChallengerKind.current.rawValue }
                .allSatisfy { $0.suboptimalCaseCount > 0 }
        }
        let report = ShardedPlannerChallengerReport(
            schemaVersion: 1,
            corpora: corpora,
            allChallengersNonRegressingInReleasedBytes:
                allChallengersNonRegressingInReleasedBytes,
            boundedChallengersLeaveResidualOracleGap:
                boundedChallengersLeaveResidualOracleGap,
            claims: .init(
                deterministicPlannerModelsEvaluated: true,
                actualCacheReplayEvaluated: false,
                concurrentContentionEvaluated: false,
                formalPerformance: false,
                productionPlannerRecommendation: false,
                diskSemantics: false,
                foveaBusinessSemantics: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allChallengersNonRegressingInReleasedBytes,
              boundedChallengersLeaveResidualOracleGap
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func evaluateCorpus(
        name: String,
        shardCount: Int,
        depth: Int,
        costs: [Int],
        deficits: [Int]
    ) -> ShardedPlannerChallengerCorpus {
        let perShard = cartesianSequences(alphabet: costs, length: depth)
        var caseCount = 0
        var currentSuboptimalCaseCount = 0
        let stats = Dictionary(
            uniqueKeysWithValues: ShardedPlannerChallengerKind.allCases.map {
                ($0, MutableStats())
            }
        )

        func visit(_ chosen: inout [[Int]], shard: Int) {
            if shard == shardCount {
                let totalAvailable = chosen.flatMap { $0 }.reduce(0, +)
                for deficit in deficits where deficit <= totalAvailable {
                    caseCount += 1
                    let oracle = exactPrefixOraclePlan(
                        deficit: deficit,
                        shardVictimPrefixes: chosen
                    )
                    let current = plan(
                        .current,
                        deficit: deficit,
                        shardVictimPrefixes: chosen
                    )
                    let currentGap = current.removedCost - oracle.removedCost
                    if currentGap > 0 { currentSuboptimalCaseCount += 1 }

                    for kind in ShardedPlannerChallengerKind.allCases {
                        let candidate = kind == .current
                            ? current
                            : plan(kind, deficit: deficit, shardVictimPrefixes: chosen)
                        let gap = candidate.removedCost - oracle.removedCost
                        precondition(gap >= 0)
                        stats[kind]!.observe(
                            gap: gap,
                            overshoot: candidate.removedCost - deficit,
                            currentGap: currentGap,
                            currentReleased: current.removedCost,
                            candidateReleased: candidate.removedCost
                        )
                    }
                }
                return
            }
            for sequence in perShard {
                chosen.append(sequence)
                visit(&chosen, shard: shard + 1)
                chosen.removeLast()
            }
        }

        var chosen: [[Int]] = []
        visit(&chosen, shard: 0)
        let challengerResults = ShardedPlannerChallengerKind.allCases.map { kind in
            let value = stats[kind]!
            return ShardedPlannerChallengerResult(
                challenger: kind.rawValue,
                suboptimalCaseCount: value.suboptimalCaseCount,
                suboptimalCaseRatio: Double(value.suboptimalCaseCount) / Double(caseCount),
                currentSuboptimalCasesFixed: value.currentSuboptimalCasesFixed,
                currentSuboptimalCasesFixedRatio: currentSuboptimalCaseCount > 0
                    ? Double(value.currentSuboptimalCasesFixed)
                        / Double(currentSuboptimalCaseCount)
                    : 0,
                regressionCaseCountVersusCurrent: value.regressionCaseCountVersusCurrent,
                maximumAvoidableReleasedBytes: value.maximumAvoidableReleasedBytes,
                maximumOvershoot: value.maximumOvershoot
            )
        }
        return ShardedPlannerChallengerCorpus(
            name: name,
            shardCount: shardCount,
            victimDepthPerShard: depth,
            costAlphabet: costs,
            deficitRange: deficits,
            caseCount: caseCount,
            currentSuboptimalCaseCount: currentSuboptimalCaseCount,
            challengers: challengerResults
        )
    }

    private final class MutableStats {
        var suboptimalCaseCount = 0
        var currentSuboptimalCasesFixed = 0
        var regressionCaseCountVersusCurrent = 0
        var maximumAvoidableReleasedBytes = 0
        var maximumOvershoot = 0

        func observe(
            gap: Int,
            overshoot: Int,
            currentGap: Int,
            currentReleased: Int,
            candidateReleased: Int
        ) {
            if gap > 0 { suboptimalCaseCount += 1 }
            if currentGap > 0, gap == 0 { currentSuboptimalCasesFixed += 1 }
            if candidateReleased > currentReleased { regressionCaseCountVersusCurrent += 1 }
            maximumAvoidableReleasedBytes = max(maximumAvoidableReleasedBytes, gap)
            maximumOvershoot = max(maximumOvershoot, overshoot)
        }
    }

    private static func plan(
        _ kind: ShardedPlannerChallengerKind,
        deficit: Int,
        shardVictimPrefixes: [[Int]]
    ) -> ShardedPlannerChallengerPlan {
        var indices = [Int](repeating: 0, count: shardVictimPrefixes.count)
        var remaining = deficit
        var removedCost = 0
        var removedItems = 0

        while remaining > 0 {
            let immediate: [(index: Int, cost: Int)] = shardVictimPrefixes.indices.compactMap {
                shard in
                let offset = indices[shard]
                guard offset < shardVictimPrefixes[shard].count else { return nil }
                return (shard, shardVictimPrefixes[shard][offset])
            }
            precondition(!immediate.isEmpty)
            if let exact = immediate.first(where: { $0.cost == remaining }) {
                remove(exact.index)
                continue
            }

            if kind != .current,
               let sameShardExact = immediate.first(where: { candidate in
                   guard candidate.cost < remaining else { return false }
                   let next = indices[candidate.index] + 1
                   guard next < shardVictimPrefixes[candidate.index].count else { return false }
                   return candidate.cost + shardVictimPrefixes[candidate.index][next] == remaining
               })
            {
                remove(sameShardExact.index)
                continue
            }

            if kind == .anyTwoLegalExact,
               let crossShardExact = firstCrossShardImmediateExactPair(
                   immediate,
                   remaining: remaining
               )
            {
                // Either member leaves the other immediate victim legal. Prefer the larger first
                // so the remaining deficit decreases at least as quickly as current best-under.
                remove(crossShardExact.firstCost >= crossShardExact.secondCost
                    ? crossShardExact.firstIndex : crossShardExact.secondIndex)
                continue
            }

            let under = immediate.filter { $0.cost < remaining }
            if let bestUnderCost = under.map(\.cost).max() {
                let tied = under.filter { $0.cost == bestUnderCost }
                if kind == .current, tied.count > 1 {
                    let exactSuccessorCost = remaining - bestUnderCost
                    if let tiedExact = tied.first(where: { candidate in
                        let next = indices[candidate.index] + 1
                        return next < shardVictimPrefixes[candidate.index].count
                            && shardVictimPrefixes[candidate.index][next] == exactSuccessorCost
                    }) {
                        remove(tiedExact.index)
                        continue
                    }
                }
                remove(tied[0].index)
            } else {
                let bestOverCost = immediate.map(\.cost).min()!
                remove(immediate.first(where: { $0.cost == bestOverCost })!.index)
            }
        }

        return ShardedPlannerChallengerPlan(
            removedCost: removedCost,
            removedItems: removedItems,
            prefixLengths: indices
        )

        func remove(_ shard: Int) {
            let cost = shardVictimPrefixes[shard][indices[shard]]
            indices[shard] += 1
            removedCost += cost
            removedItems += 1
            remaining = max(0, remaining - cost)
        }
    }

    private static func firstCrossShardImmediateExactPair(
        _ immediate: [(index: Int, cost: Int)],
        remaining: Int
    ) -> (firstIndex: Int, firstCost: Int, secondIndex: Int, secondCost: Int)? {
        guard immediate.count >= 2 else { return nil }
        for firstOffset in 0..<(immediate.count - 1) {
            let first = immediate[firstOffset]
            guard first.cost < remaining else { continue }
            for secondOffset in (firstOffset + 1)..<immediate.count {
                let second = immediate[secondOffset]
                if first.cost + second.cost == remaining {
                    return (first.index, first.cost, second.index, second.cost)
                }
            }
        }
        return nil
    }

    private static func exactPrefixOraclePlan(
        deficit: Int,
        shardVictimPrefixes: [[Int]]
    ) -> ShardedPlannerChallengerPlan {
        let prefixSums = shardVictimPrefixes.map { sequence -> [Int] in
            var sums = [0]
            for cost in sequence { sums.append(sums.last! + cost) }
            return sums
        }
        var prefix = [Int](repeating: 0, count: shardVictimPrefixes.count)
        var best: ShardedPlannerChallengerPlan?
        func visit(_ shard: Int, cost: Int, items: Int) {
            if shard == shardVictimPrefixes.count {
                guard cost >= deficit else { return }
                let candidate = ShardedPlannerChallengerPlan(
                    removedCost: cost,
                    removedItems: items,
                    prefixLengths: prefix
                )
                if best == nil
                    || candidate.removedCost < best!.removedCost
                    || (candidate.removedCost == best!.removedCost
                        && candidate.removedItems < best!.removedItems)
                {
                    best = candidate
                }
                return
            }
            for length in 0...shardVictimPrefixes[shard].count {
                prefix[shard] = length
                visit(
                    shard + 1,
                    cost: cost + prefixSums[shard][length],
                    items: items + length
                )
            }
        }
        visit(0, cost: 0, items: 0)
        return best!
    }

    private static func cartesianSequences(alphabet: [Int], length: Int) -> [[Int]] {
        if length == 0 { return [[]] }
        let suffixes = cartesianSequences(alphabet: alphabet, length: length - 1)
        return alphabet.flatMap { value in suffixes.map { [value] + $0 } }
    }
}
