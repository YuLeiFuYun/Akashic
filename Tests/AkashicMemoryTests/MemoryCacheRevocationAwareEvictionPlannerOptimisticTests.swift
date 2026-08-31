import AkashicMemory
import Foundation
import Testing

extension MemoryCacheRevocationAwareEvictionPlannerTests {
    @Test("Package one-pass planner matches restart oracle over complete N=8 ternary states")
    func exhaustiveUnitCostRestartDifferential() {
        let residentCount = 8
        let stateCount = intPow(3, residentCount)
        var checked = 0
        var mutationStrictlyLessCount = 0

        for encoded in 0..<stateCount {
            let ternary = decodeTernary(encoded, digits: residentCount)
            let provisional = Set(ternary.indices.filter { ternary[$0] == 2 })
            for incomingCost in 1...(residentCount / 2) {
                let oracleCache = makeCache(
                    costs: [Int](repeating: 1, count: residentCount),
                    ternary: ternary
                )
                let oracle = restartOracle(
                    cache: oracleCache,
                    provisionalVisitedKeys: provisional,
                    incomingCost: incomingCost
                )
                let candidateCache = makeCache(
                    costs: [Int](repeating: 1, count: residentCount),
                    ternary: ternary
                )
                let candidate = candidateCache.resourceProbeRevocationAwareEvictionPlan(
                    provisionalVisitedKeys: provisional,
                    incomingCost: incomingCost
                )

                #expect(candidate.victims.map(\.key) == oracle.victims)
                #expect(candidate.victims.map(\.cost) == oracle.victimCosts)
                #expect(candidate.provisionalRevocations == oracle.revocations)
                #expect(candidate.fullVisitedEpochResetCount == oracle.finalEpochResetCount)
                #expect(candidate.releasedCost == oracle.victimCosts.reduce(0, +))
                #expect(candidate.inspectedSlotCount <= residentCount * 2)
                let mutation = productionMutationModel(
                    costs: [Int](repeating: 1, count: residentCount),
                    ternary: ternary,
                    provisionalRevocations: candidate.provisionalRevocations,
                    incomingCost: incomingCost
                )
                #expect(mutation.victims == candidate.victims.map(\.key))
                #expect(mutation.inspectedSlotCount <= candidate.inspectedSlotCount)
                if mutation.inspectedSlotCount < candidate.inspectedSlotCount {
                    mutationStrictlyLessCount += 1
                }
                checked += 1
            }
        }

        #expect(checked == 26_244)
        #expect(mutationStrictlyLessCount > 0)
    }

    @Test("Package one-pass planner matches restart oracle over variable-cost N=5 states")
    func exhaustiveVariableCostRestartDifferential() {
        let residentCount = 5
        let ternaryStateCount = intPow(3, residentCount)
        let costStateCount = 1 << residentCount
        var checked = 0
        var actualMutationChecks = 0
        var mutationStrictlyLessCount = 0

        for costMask in 0..<costStateCount {
            let costs = (0..<residentCount).map { index in
                (costMask & (1 << index)) == 0 ? 1 : 2
            }
            let totalCost = costs.reduce(0, +)
            for encoded in 0..<ternaryStateCount {
                let ternary = decodeTernary(encoded, digits: residentCount)
                let provisional = Set(ternary.indices.filter { ternary[$0] == 2 })
                for incomingCost in 1...5 {
                    let oracleCache = makeCache(costs: costs, ternary: ternary)
                    let oracle = restartOracle(
                        cache: oracleCache,
                        provisionalVisitedKeys: provisional,
                        incomingCost: incomingCost
                    )
                    let candidateCache = makeCache(costs: costs, ternary: ternary)
                    let candidate = candidateCache.resourceProbeRevocationAwareEvictionPlan(
                        provisionalVisitedKeys: provisional,
                        incomingCost: incomingCost
                    )

                    #expect(candidate.victims.map(\.key) == oracle.victims)
                    #expect(candidate.victims.map(\.cost) == oracle.victimCosts)
                    #expect(candidate.provisionalRevocations == oracle.revocations)
                    #expect(candidate.fullVisitedEpochResetCount == oracle.finalEpochResetCount)
                    #expect(candidate.releasedCost == oracle.victimCosts.reduce(0, +))
                    #expect(candidate.releasedCost >= min(incomingCost, totalCost))
                    #expect(candidate.inspectedSlotCount <= residentCount * 2)

                    let mutation = productionMutationModel(
                        costs: costs,
                        ternary: ternary,
                        provisionalRevocations: candidate.provisionalRevocations,
                        incomingCost: incomingCost
                    )
                    #expect(mutation.victims == candidate.victims.map(\.key))
                    #expect(mutation.inspectedSlotCount <= candidate.inspectedSlotCount)
                    if mutation.inspectedSlotCount < candidate.inspectedSlotCount {
                        mutationStrictlyLessCount += 1
                    }

                    if (costMask * ternaryStateCount * 5 + encoded * 5 + incomingCost)
                        .isMultiple(of: 121)
                    {
                        for key in candidate.provisionalRevocations {
                            #expect(candidateCache.resourceProbeClearVisited(for: key))
                        }
                        let finalTrace = candidateCache.resourceProbeEvictionTrace(
                            incomingCost: incomingCost
                        )
                        #expect(finalTrace.victims.map(\.key) == candidate.victims.map(\.key))
                        #expect(finalTrace.victims.map(\.cost) == candidate.victims.map(\.cost))
                        #expect(
                            finalTrace.fullVisitedEpochResetCount
                                == candidate.fullVisitedEpochResetCount
                        )

                        candidateCache.insert(99, for: 99, cost: incomingCost)
                        let victimSet = Set(candidate.victims.map(\.key))
                        for key in 0..<residentCount {
                            #expect(
                                (candidateCache.resourceProbeValueWithoutVisit(for: key) == nil)
                                    == victimSet.contains(key)
                            )
                        }
                        #expect(candidateCache.resourceProbeValueWithoutVisit(for: 99) == 99)
                        #expect(candidateCache.currentCost <= totalCost)
                        #expect(candidateCache.count == residentCount - victimSet.count + 1)
                        actualMutationChecks += 1
                    }
                    checked += 1
                }
            }
        }

        #expect(checked == 38_880)
        #expect(actualMutationChecks >= 300)
        #expect(mutationStrictlyLessCount > 0)
    }

    @Test("Moved real hand preserves restart victims and post-insert state")
    func movedHandRealMutationDifferential() {
        let oracle = movedHandFixture()
        let candidate = movedHandFixture()
        let provisional: Set<Int> = [4]

        let expected = restartOracle(
            cache: oracle,
            provisionalVisitedKeys: provisional,
            incomingCost: 2
        )
        let plan = candidate.resourceProbeRevocationAwareEvictionPlan(
            provisionalVisitedKeys: provisional,
            incomingCost: 2
        )

        #expect(plan.victims.map(\.key) == expected.victims)
        #expect(plan.victims.map(\.cost) == expected.victimCosts)
        #expect(plan.provisionalRevocations == expected.revocations)
        for key in plan.provisionalRevocations {
            #expect(candidate.resourceProbeClearVisited(for: key))
        }
        let finalTrace = candidate.resourceProbeEvictionTrace(incomingCost: 2)
        #expect(finalTrace.victims.map(\.key) == plan.victims.map(\.key))
        #expect(finalTrace.victims.map(\.cost) == plan.victims.map(\.cost))
        #expect(finalTrace.fullVisitedEpochResetCount == plan.fullVisitedEpochResetCount)

        candidate.insert(99, for: 99, cost: 2)
        let predictedVictims = Set(plan.victims.map(\.key))
        for key in [0, 2, 3, 4] {
            #expect(
                (candidate.resourceProbeValueWithoutVisit(for: key) == nil)
                    == predictedVictims.contains(key)
            )
        }
        #expect(candidate.resourceProbeValueWithoutVisit(for: 99) == 99)
    }

    @Test("Nonmutating plan is snapshot-only across an intervening hit")
    func interveningHitInvalidatesExecutableVictimPlan() {
        let cache = MemoryCache<Int, Int>(costLimit: 2)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)

        let snapshot = cache.resourceProbeRevocationAwareEvictionPlan(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(snapshot.victims.map(\.key) == [0])

        // This is a legal concurrent interleaving between a diagnostic snapshot and a later
        // mutation. It changes the SIEVE state without changing resident cardinality or cost.
        #expect(cache.value(for: 0) == 0)
        cache.insert(2, for: 2, cost: 1)

        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == 0)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == 2)
    }

    @Test("Optimistic commit rejects stale victim plan without mutating cache")
    func optimisticCommitRejectsInterveningHit() {
        let cache = MemoryCache<Int, Int>(costLimit: 2)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(snapshot.plan.victims.map(\.key) == [0])

        #expect(cache.value(for: 0) == 0)
        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            2,
            for: 2,
            cost: 1,
            expectedSnapshot: snapshot
        )
        #expect(!result.accepted)
        #expect(result.validationMode == .exactStreaming)
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == 0)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == nil)
        #expect(cache.currentCost == 2)
        #expect(cache.count == 2)
    }

    @Test("Optimistic validation tolerates an intervening hit outside the decision trace")
    func optimisticCommitAcceptsStructurallyIrrelevantHit() {
        let cache = MemoryCache<Int, Int>(costLimit: 3)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        cache.insert(2, for: 2, cost: 1)
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(snapshot.plan.victims.map(\.key) == [0])

        // A global state version would invalidate this snapshot even though the hit is beyond the
        // first victim and cannot change the decision-relevant eviction trace for this insertion.
        #expect(cache.value(for: 2) == 2)
        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            3,
            for: 3,
            cost: 1,
            expectedSnapshot: snapshot
        )
        #expect(result.accepted)
        #expect(result.validationMode == .exactStreaming)
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == 2)
        #expect(cache.resourceProbeValueWithoutVisit(for: 3) == 3)
        #expect(cache.resourceProbeVisitState().visitedCount == 1)
    }

    @Test("Eviction-state token changes only when SIEVE decision state changes")
    func evictionStateTokenAvoidsNoopInvalidation() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        let baseline = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(baseline.evictionStateVersion != nil)

        _ = cache.resourceProbeValueWithoutVisit(for: 0)
        cache.insert(9, for: 9, cost: 5)
        cache.remove(99)
        _ = cache.updateCostLimit(4)
        let afterNoops = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(afterNoops.evictionStateVersion == baseline.evictionStateVersion)

        #expect(cache.value(for: 0) == 0)
        let afterFirstHit = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(afterFirstHit.evictionStateVersion != afterNoops.evictionStateVersion)

        #expect(cache.value(for: 0) == 0)
        let afterRepeatedHit = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(afterRepeatedHit.evictionStateVersion == afterFirstHit.evictionStateVersion)
    }

    @Test("Optimistic snapshot binds incoming cost even when both plans need no eviction")
    func optimisticSnapshotRejectsDifferentIncomingCost() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(snapshot.plan.victims.isEmpty)

        // A 2-cost insertion also fits without eviction, so plan equality alone cannot detect that
        // this is a different observation input. The typed snapshot must reject it before mutation.
        #expect(
            !cache.resourceProbeInsertIfRevocationAwarePlanMatches(
                2,
                for: 2,
                cost: 2,
                expectedSnapshot: snapshot
            )
        )
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == nil)
        #expect(cache.currentCost == 2)
        #expect(cache.count == 2)
    }

    @Test("Provisional lease does not ABA onto a same-key replacement")
    func provisionalLeaseRejectsSameKeyReplacementABA() {
        let cache = MemoryCache<Int, Int>(costLimit: 2)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        #expect(cache.resourceProbeMarkVisited(for: 0))
        #expect(cache.resourceProbeMarkVisited(for: 1))

        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [0],
            incomingCost: 1
        )
        #expect(snapshot.plan.provisionalRevocations == [0])
        #expect(snapshot.plan.victims.map(\.key) == [0])

        // Replacement reuses the same Node object but increments its incarnation. Marking the new
        // resident visited recreates the exact key-level shape that would fool a Set<Key>-only lease.
        cache.insert(100, for: 0, cost: 1)
        #expect(cache.value(for: 0) == 100)

        #expect(
            !cache.resourceProbeInsertIfRevocationAwarePlanMatches(
                2,
                for: 2,
                cost: 1,
                expectedSnapshot: snapshot
            )
        )
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == 100)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == nil)
        #expect(cache.currentCost == 2)
        #expect(cache.count == 2)
    }

    @Test("Provisional lease does not ABA onto a remove-reinserted key")
    func provisionalLeaseRejectsRemoveReinsertABA() {
        let cache = MemoryCache<Int, Int>(costLimit: 2)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        #expect(cache.resourceProbeMarkVisited(for: 0))
        #expect(cache.resourceProbeMarkVisited(for: 1))
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [0],
            incomingCost: 1
        )
        #expect(snapshot.plan.provisionalRevocations == [0])

        cache.remove(0)
        cache.insert(100, for: 0, cost: 1)
        #expect(cache.value(for: 0) == 100)

        #expect(
            !cache.resourceProbeInsertIfRevocationAwarePlanMatches(
                2,
                for: 2,
                cost: 1,
                expectedSnapshot: snapshot
            )
        )
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == 100)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == nil)
        #expect(cache.currentCost == 2)
        #expect(cache.count == 2)
    }

    @Test("Optimistic commit linearizes revocation and insertion when plan still matches")
    func optimisticCommitAppliesMatchingPlanAtomically() {
        let cache = makeCache(costs: [1, 1, 1, 1], ternary: [1, 1, 2, 1])
        let provisional: Set<Int> = [2]
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: provisional,
            incomingCost: 1
        )

        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            99,
            for: 99,
            cost: 1,
            expectedSnapshot: snapshot
        )
        #expect(result.accepted)
        #expect(result.validationMode == .versionFastPath)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) == 99)
        #expect(cache.resourceProbeVisitState().visitedCount == 1)
    }

    @Test("Competing commits from one snapshot allow exactly one structural winner")
    func competingOptimisticCommitsLinearize() async {
        let cache = MemoryCache<Int, Int>(costLimit: 2)
        cache.insert(0, for: 0, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(snapshot.plan.victims.map(\.key) == [0])

        let results = await withTaskGroup(
            of: MemoryCacheRevocationAwareCommitResult.self,
            returning: [MemoryCacheRevocationAwareCommitResult].self
        ) { group in
            for key in [2, 3] {
                group.addTask {
                    cache.resourceProbeCommitRevocationAwareSnapshot(
                        key,
                        for: key,
                        cost: 1,
                        expectedSnapshot: snapshot
                    )
                }
            }
            var values: [MemoryCacheRevocationAwareCommitResult] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(results.filter(\.accepted).count == 1)
        #expect(results.filter { $0.accepted && $0.validationMode == .versionFastPath }.count == 1)
        #expect(results.filter { !$0.accepted && $0.validationMode == .exactStreaming }.count == 1)
        #expect(cache.count == 2)
        #expect(cache.currentCost == 2)
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == 1)
        let newResidentCount = [2, 3].reduce(into: 0) { count, key in
            if cache.resourceProbeValueWithoutVisit(for: key) != nil { count += 1 }
        }
        #expect(newResidentCount == 1)
    }
}
