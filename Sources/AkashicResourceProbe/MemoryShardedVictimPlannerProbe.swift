import Foundation

private struct ShardedVictimPlannerPlan: Codable, Equatable {
    let removedCost: Int
    let removedItems: Int
    let prefixLengths: [Int]

    var overshoot: Int
}

private struct ShardedVictimPlannerWitness: Codable {
    let name: String
    let deficit: Int
    let shardVictimPrefixes: [[Int]]
    let currentHeuristic: ShardedVictimPlannerPlan
    let exactPrefixOracle: ShardedVictimPlannerPlan
    let avoidableReleasedBytes: Int
    let currentHeuristicIsByteOptimal: Bool
}

private struct ShardedVictimPlannerCorpus: Codable {
    let name: String
    let shardCount: Int
    let victimDepthPerShard: Int
    let costAlphabet: [Int]
    let deficitRange: [Int]
    let caseCount: Int
    let suboptimalCaseCount: Int
    let maximumAvoidableReleasedBytes: Int
    let maximumCurrentOvershoot: Int
    let maximumOracleOvershoot: Int
    let worstWitness: ShardedVictimPlannerWitness?
}

private struct ShardedVictimPlannerReport: Codable {
    struct Claims: Codable {
        let currentSelectorSemanticsModeled: Bool
        let exactLocalPrefixOracleEvaluated: Bool
        let actualShardedCacheReplayEvaluated: Bool
        let concurrentContentionEvaluated: Bool
        let formalPerformance: Bool
        let productionPlannerRecommendation: Bool
        let admissionPolicyEvaluated: Bool
        let diskSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let curatedWitnesses: [ShardedVictimPlannerWitness]
    let corpora: [ShardedVictimPlannerCorpus]
    let allCurrentPlansCoverDeficit: Bool
    let allOraclePlansCoverDeficit: Bool
    let allOraclePlansNoWorseThanCurrent: Bool
    let uniqueBestUnderCounterexampleObserved: Bool
    let equalCostSuccessorTieControlIsOptimal: Bool
    let claims: Claims
}

/// Pure deterministic model of the cross-shard victim selector currently used by
/// `ShardedMemoryCache`.
///
/// Each shard contributes only a legal local SIEVE victim prefix. Removing N victims from one
/// shard must consume the first N costs in that prefix; the oracle is not allowed to skip a local
/// victim or reorder one shard's SIEVE sequence. The model deliberately says nothing about locks,
/// hashing, concurrency or the cost of obtaining these forecasts.
enum MemoryShardedVictimPlannerProbe {
    static func run() throws {
        let uniqueBestUnder = witness(
            name: "unique-best-under-can-block-smaller-exact-prefix",
            deficit: 10,
            shardVictimPrefixes: [
                [7, 7],
                [6, 4],
            ]
        )
        let equalTieControl = witness(
            name: "equal-under-successor-lookahead-finds-exact-prefix",
            deficit: 10,
            shardVictimPrefixes: [
                [6, 6],
                [6, 4],
            ]
        )
        let immediateExactControl = witness(
            name: "immediate-exact-victim-is-byte-optimal",
            deficit: 10,
            shardVictimPrefixes: [
                [10, 64],
                [9, 1],
            ]
        )
        let unavoidableOvershootControl = witness(
            name: "local-prefix-order-can-make-overshoot-unavoidable",
            deficit: 9,
            shardVictimPrefixes: [
                [8, 8],
                [8, 8],
            ]
        )

        let corpora = [
            exhaustiveCorpus(
                name: "two-shards-depth2-cost1to8",
                shardCount: 2,
                depth: 2,
                costs: Array(1...8),
                deficits: Array(1...16)
            ),
            exhaustiveCorpus(
                name: "three-shards-depth2-powers-and-neighbors",
                shardCount: 3,
                depth: 2,
                costs: [1, 2, 3, 4, 6, 8],
                deficits: Array(1...16)
            ),
        ]

        let curated = [
            uniqueBestUnder,
            equalTieControl,
            immediateExactControl,
            unavoidableOvershootControl,
        ]
        let allWitnesses = curated + corpora.compactMap(\.worstWitness)
        let allCurrentPlansCoverDeficit = allWitnesses.allSatisfy {
            $0.currentHeuristic.removedCost >= $0.deficit
        }
        let allOraclePlansCoverDeficit = allWitnesses.allSatisfy {
            $0.exactPrefixOracle.removedCost >= $0.deficit
        }
        let allOraclePlansNoWorseThanCurrent = allWitnesses.allSatisfy {
            $0.exactPrefixOracle.removedCost <= $0.currentHeuristic.removedCost
        }
        let uniqueBestUnderCounterexampleObserved =
            uniqueBestUnder.currentHeuristic.removedCost == 13
                && uniqueBestUnder.exactPrefixOracle.removedCost == 10
                && uniqueBestUnder.currentHeuristic.prefixLengths == [1, 1]
                && uniqueBestUnder.exactPrefixOracle.prefixLengths == [0, 2]
        let equalCostSuccessorTieControlIsOptimal =
            equalTieControl.currentHeuristic.removedCost == 10
                && equalTieControl.currentHeuristic.removedCost
                    == equalTieControl.exactPrefixOracle.removedCost

        let report = ShardedVictimPlannerReport(
            schemaVersion: 1,
            curatedWitnesses: curated,
            corpora: corpora,
            allCurrentPlansCoverDeficit: allCurrentPlansCoverDeficit,
            allOraclePlansCoverDeficit: allOraclePlansCoverDeficit,
            allOraclePlansNoWorseThanCurrent: allOraclePlansNoWorseThanCurrent,
            uniqueBestUnderCounterexampleObserved: uniqueBestUnderCounterexampleObserved,
            equalCostSuccessorTieControlIsOptimal: equalCostSuccessorTieControlIsOptimal,
            claims: .init(
                currentSelectorSemanticsModeled: true,
                exactLocalPrefixOracleEvaluated: true,
                actualShardedCacheReplayEvaluated: false,
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
        guard allCurrentPlansCoverDeficit,
              allOraclePlansCoverDeficit,
              allOraclePlansNoWorseThanCurrent,
              uniqueBestUnderCounterexampleObserved,
              equalCostSuccessorTieControlIsOptimal,
              corpora.allSatisfy({ $0.suboptimalCaseCount > 0 })
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func witness(
        name: String,
        deficit: Int,
        shardVictimPrefixes: [[Int]]
    ) -> ShardedVictimPlannerWitness {
        let current = currentHeuristicPlan(
            deficit: deficit,
            shardVictimPrefixes: shardVictimPrefixes
        )
        let oracle = exactPrefixOraclePlan(
            deficit: deficit,
            shardVictimPrefixes: shardVictimPrefixes
        )
        return ShardedVictimPlannerWitness(
            name: name,
            deficit: deficit,
            shardVictimPrefixes: shardVictimPrefixes,
            currentHeuristic: current,
            exactPrefixOracle: oracle,
            avoidableReleasedBytes: current.removedCost - oracle.removedCost,
            currentHeuristicIsByteOptimal: current.removedCost == oracle.removedCost
        )
    }

    private static func exhaustiveCorpus(
        name: String,
        shardCount: Int,
        depth: Int,
        costs: [Int],
        deficits: [Int]
    ) -> ShardedVictimPlannerCorpus {
        precondition(shardCount >= 2)
        precondition(depth >= 1)
        precondition(costs.allSatisfy { $0 > 0 })
        precondition(deficits.allSatisfy { $0 > 0 })

        let perShardSequences = cartesianSequences(alphabet: costs, length: depth)
        var caseCount = 0
        var suboptimalCaseCount = 0
        var maximumAvoidableReleasedBytes = 0
        var maximumCurrentOvershoot = 0
        var maximumOracleOvershoot = 0
        var worstWitness: ShardedVictimPlannerWitness?

        func visit(_ chosen: inout [[Int]], shard: Int) {
            if shard == shardCount {
                let totalAvailable = chosen.flatMap { $0 }.reduce(0, +)
                for deficit in deficits where deficit <= totalAvailable {
                    caseCount += 1
                    let current = currentHeuristicPlan(
                        deficit: deficit,
                        shardVictimPrefixes: chosen
                    )
                    let oracle = exactPrefixOraclePlan(
                        deficit: deficit,
                        shardVictimPrefixes: chosen
                    )
                    precondition(current.removedCost >= deficit)
                    precondition(oracle.removedCost >= deficit)
                    precondition(oracle.removedCost <= current.removedCost)
                    let avoidable = current.removedCost - oracle.removedCost
                    maximumCurrentOvershoot = max(
                        maximumCurrentOvershoot,
                        current.removedCost - deficit
                    )
                    maximumOracleOvershoot = max(
                        maximumOracleOvershoot,
                        oracle.removedCost - deficit
                    )
                    if avoidable > 0 {
                        suboptimalCaseCount += 1
                        if avoidable > maximumAvoidableReleasedBytes {
                            maximumAvoidableReleasedBytes = avoidable
                            worstWitness = ShardedVictimPlannerWitness(
                                name: "\(name)-worst",
                                deficit: deficit,
                                shardVictimPrefixes: chosen,
                                currentHeuristic: current,
                                exactPrefixOracle: oracle,
                                avoidableReleasedBytes: avoidable,
                                currentHeuristicIsByteOptimal: false
                            )
                        }
                    }
                }
                return
            }
            for sequence in perShardSequences {
                chosen.append(sequence)
                visit(&chosen, shard: shard + 1)
                chosen.removeLast()
            }
        }

        var chosen: [[Int]] = []
        chosen.reserveCapacity(shardCount)
        visit(&chosen, shard: 0)
        return ShardedVictimPlannerCorpus(
            name: name,
            shardCount: shardCount,
            victimDepthPerShard: depth,
            costAlphabet: costs,
            deficitRange: deficits,
            caseCount: caseCount,
            suboptimalCaseCount: suboptimalCaseCount,
            maximumAvoidableReleasedBytes: maximumAvoidableReleasedBytes,
            maximumCurrentOvershoot: maximumCurrentOvershoot,
            maximumOracleOvershoot: maximumOracleOvershoot,
            worstWitness: worstWitness
        )
    }

    /// Mirrors `bestFitVictimShardIndexLocked`: exact immediate victim, otherwise greatest
    /// immediate victim below the remaining deficit, otherwise the smallest overshoot. The only
    /// look-ahead is an equal-cost best-under tie where a tied shard's single successor can exactly
    /// fill the post-first-victim deficit.
    private static func currentHeuristicPlan(
        deficit: Int,
        shardVictimPrefixes: [[Int]]
    ) -> ShardedVictimPlannerPlan {
        precondition(deficit > 0)
        precondition(shardVictimPrefixes.allSatisfy { $0.allSatisfy { $0 > 0 } })
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
            precondition(!immediate.isEmpty, "modeled deficit must be satisfiable")

            if let exact = immediate.first(where: { $0.cost == remaining }) {
                remove(exact.index)
                continue
            }

            let under = immediate.filter { $0.cost < remaining }
            let selectedIndex: Int
            if let bestUnderCost = under.map(\.cost).max() {
                let tied = under.filter { $0.cost == bestUnderCost }
                if tied.count > 1 {
                    let exactSuccessorCost = remaining - bestUnderCost
                    if let tiedExact = tied.first(where: { candidate in
                        let next = indices[candidate.index] + 1
                        guard next < shardVictimPrefixes[candidate.index].count else {
                            return false
                        }
                        return shardVictimPrefixes[candidate.index][next] == exactSuccessorCost
                    }) {
                        selectedIndex = tiedExact.index
                    } else {
                        selectedIndex = tied[0].index
                    }
                } else {
                    selectedIndex = tied[0].index
                }
            } else {
                let bestOverCost = immediate.map(\.cost).min()!
                selectedIndex = immediate.first(where: { $0.cost == bestOverCost })!.index
            }
            remove(selectedIndex)
        }

        return ShardedVictimPlannerPlan(
            removedCost: removedCost,
            removedItems: removedItems,
            prefixLengths: indices,
            overshoot: removedCost - deficit
        )

        func remove(_ shard: Int) {
            let cost = shardVictimPrefixes[shard][indices[shard]]
            indices[shard] += 1
            removedCost += cost
            removedItems += 1
            remaining = max(0, remaining - cost)
        }
    }

    /// Exact byte-release oracle over every legal combination of local SIEVE prefixes. It first
    /// minimizes released bytes, then victim count, then prefix vector for deterministic reporting.
    private static func exactPrefixOraclePlan(
        deficit: Int,
        shardVictimPrefixes: [[Int]]
    ) -> ShardedVictimPlannerPlan {
        let prefixSums = shardVictimPrefixes.map { sequence -> [Int] in
            var sums = [0]
            for cost in sequence { sums.append(sums.last! + cost) }
            return sums
        }
        var best: ShardedVictimPlannerPlan?
        var prefix = [Int](repeating: 0, count: shardVictimPrefixes.count)

        func visit(_ shard: Int, cost: Int, items: Int) {
            if shard == shardVictimPrefixes.count {
                guard cost >= deficit else { return }
                let candidate = ShardedVictimPlannerPlan(
                    removedCost: cost,
                    removedItems: items,
                    prefixLengths: prefix,
                    overshoot: cost - deficit
                )
                if let current = best {
                    if candidate.removedCost < current.removedCost
                        || (candidate.removedCost == current.removedCost
                            && candidate.removedItems < current.removedItems)
                        || (candidate.removedCost == current.removedCost
                            && candidate.removedItems == current.removedItems
                            && lexicographicallyLess(candidate.prefixLengths, current.prefixLengths))
                    {
                        best = candidate
                    }
                } else {
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

    private static func lexicographicallyLess(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            if left != right { return left < right }
        }
        return lhs.count < rhs.count
    }
}
