import AkashicMemory
import Foundation
import Testing

final class RetirementDeinitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
}

final class RetirementObservedValue: @unchecked Sendable {
    private let counter: RetirementDeinitCounter

    init(counter: RetirementDeinitCounter) {
        self.counter = counter
    }

    deinit { counter.increment() }
}

final class RetirementReentrantObserver: @unchecked Sendable {
    private let lock = NSLock()
    weak var cache: MemoryCache<Int, RetirementReentrantValue>?
    private var observedInFlightGenerationsStorage: [Int] = []
    private var backpressuredAttemptsStorage = 0

    var observedInFlightGenerations: [Int] {
        lock.lock(); defer { lock.unlock() }
        return observedInFlightGenerationsStorage
    }

    var backpressuredAttempts: Int {
        lock.lock(); defer { lock.unlock() }
        return backpressuredAttemptsStorage
    }

    func observeRetirement() {
        guard let cache else { return }
        let debt = cache.resourceProbeRetirementDebtSnapshot()
        let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            RetirementReentrantValue(observer: nil),
            for: 10_000 + debt.itemCount,
            cost: 4,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        lock.lock()
        observedInFlightGenerationsStorage.append(debt.inFlightGenerationCount)
        if attempt.disposition == .backpressured { backpressuredAttemptsStorage += 1 }
        lock.unlock()
    }
}

final class RetirementReentrantValue: @unchecked Sendable {
    private let observer: RetirementReentrantObserver?

    init(observer: RetirementReentrantObserver?) { self.observer = observer }
    deinit { observer?.observeRetirement() }
}

@Suite("MemoryCache revocation-aware one-pass planner")
struct MemoryCacheRevocationAwareEvictionPlannerTests {
    struct RestartResult {
        let victims: [Int]
        let victimCosts: [Int]
        let revocations: [Int]
        let finalEpochResetCount: Int
    }

    struct ProductionMutationModelResult {
        let victims: [Int]
        let inspectedSlotCount: Int
    }

    @Test("All-visited provisional protection is revoked before epoch reset")
    func allVisitedProvisionalPreventsPrematureEpochReset() {
        let cache = makeCache(costs: [1, 1, 1, 1], ternary: [1, 1, 2, 1])

        let plan = cache.resourceProbeRevocationAwareEvictionPlan(
            provisionalVisitedKeys: [2],
            incomingCost: 1
        )

        #expect(plan.provisionalRevocations == [2])
        #expect(plan.victims.map(\.key) == [2])
        #expect(plan.fullVisitedEpochResetCount == 0)

        for key in plan.provisionalRevocations {
            #expect(cache.resourceProbeClearVisited(for: key))
        }
        let finalTrace = cache.resourceProbeEvictionTrace(incomingCost: 1)
        #expect(finalTrace.victims.map(\.key) == [2])
        #expect(finalTrace.fullVisitedEpochResetCount == 0)

        cache.insert(99, for: 99, cost: 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == nil)
        // Keys 0 and 1 were consumed while the real hand searched for key 2. Key 3 must retain its
        // second chance; a premature global epoch reset would incorrectly clear it as well.
        #expect(cache.resourceProbeVisitState().visitedCount == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: 3) == 3)
    }

    @Test("Cold hand prefix can expose a later all-visited epoch reset")
    func coldPrefixThenVisitedSuffixResetsEpoch() {
        let cache = makeCache(costs: [1, 1, 1], ternary: [0, 1, 1])
        let plan = cache.resourceProbeRevocationAwareEvictionPlan(
            provisionalVisitedKeys: [],
            incomingCost: 2
        )

        #expect(plan.victims.map(\.key) == [0, 1])
        #expect(plan.fullVisitedEpochResetCount == 1)
        #expect(plan.inspectedSlotCount == 2)

        let trace = cache.resourceProbeEvictionTrace(incomingCost: 2)
        #expect(trace.victims.map(\.key) == [0, 1])
        #expect(trace.fullVisitedEpochResetCount == 1)
    }

    @Test("Provisional cold prefix can revoke then enter epoch fast path without suffix scan")
    func provisionalPrefixThenVisitedSuffixUsesFastReset() {
        let cache = makeCache(costs: [1, 1, 1], ternary: [2, 1, 1])
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [0],
            incomingCost: 2
        )

        #expect(snapshot.plan.provisionalRevocations == [0])
        #expect(snapshot.plan.victims.map(\.key) == [0, 1])
        #expect(snapshot.plan.fullVisitedEpochResetCount == 1)
        #expect(snapshot.plan.inspectedSlotCount == 2)
        #expect(
            cache.resourceProbeInsertIfRevocationAwarePlanMatches(
                99,
                for: 99,
                cost: 2,
                expectedSnapshot: snapshot
            )
        )
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: 1) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: 2) == 2)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) == 99)
        #expect(cache.currentCost == 3)
    }

    @Test("All-visited nonprovisional snapshot uses the O(victim) epoch fast path")
    func allVisitedSnapshotAvoidsResidentScan() {
        let cache = MemoryCache<Int, Int>(costLimit: 8)
        for key in 0..<8 {
            cache.insert(key, for: key, cost: 1)
            #expect(cache.resourceProbeMarkVisited(for: key))
        }

        let plan = cache.resourceProbeRevocationAwareEvictionPlan(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        #expect(plan.victims.map(\.key) == [0])
        #expect(plan.fullVisitedEpochResetCount == 1)
        #expect(plan.inspectedSlotCount == 1)
    }

    @Test("Bounded all-hot snapshot succeeds with one-victim one-slot budget")
    func boundedAllHotSnapshotUsesTinyBudget() {
        let residentCount = 512
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(key, for: key, cost: 1)
            #expect(cache.resourceProbeMarkVisited(for: key))
        }

        let result = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: 1,
            maximumInspectedSlotCount: 1
        )
        #expect(result.limitReason == nil)
        #expect(result.snapshot?.plan.victims.count == 1)
        #expect(result.snapshot?.plan.inspectedSlotCount == 1)
        #expect(result.victimCount == 1)
        #expect(result.inspectedSlotCount == 1)
    }

    @Test("Bounded tail provisional fails on inspection budget without mutation")
    func boundedTailProvisionalCapsLockWork() {
        let residentCount = 512
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        #expect(handOrder.count == residentCount)
        for key in handOrder { #expect(cache.resourceProbeMarkVisited(for: key)) }
        let provisional = Set([handOrder[residentCount - 1]])
        let beforeVersion = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        ).evictionStateVersion

        let result = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: provisional,
            incomingCost: 2,
            maximumProvisionalLeaseCount: 1,
            maximumVictimCount: 2,
            maximumInspectedSlotCount: 64
        )
        #expect(result.snapshot == nil)
        #expect(result.limitReason == .inspectedSlotCount)
        #expect(result.victimCount == 0)
        #expect(result.inspectedSlotCount == 64)
        #expect(cache.count == residentCount)
        #expect(cache.currentCost == residentCount)
        let afterVersion = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        ).evictionStateVersion
        #expect(afterVersion == beforeVersion)
    }

    @Test("Bounded giant snapshot stops before allocating victim K plus one")
    func boundedGiantSnapshotCapsVictimOutput() {
        let residentCount = 512
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        #expect(handOrder.count == residentCount)
        #expect(cache.resourceProbeMarkVisited(for: handOrder[residentCount - 2]))

        let result = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: residentCount,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: 256,
            maximumInspectedSlotCount: residentCount * 2
        )
        #expect(result.snapshot == nil)
        #expect(result.limitReason == .victimCount)
        #expect(result.victimCount == 256)
        #expect(result.inspectedSlotCount == 257)
        #expect(cache.count == residentCount)
        #expect(cache.currentCost == residentCount)
    }

    @Test("Bounded snapshot rejects oversized provisional input before cache observation")
    func boundedSnapshotCapsProvisionalInput() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        let before = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        ).evictionStateVersion

        let result = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [100, 101],
            incomingCost: 1,
            maximumProvisionalLeaseCount: 1,
            maximumVictimCount: 4,
            maximumInspectedSlotCount: 8
        )
        #expect(result.snapshot == nil)
        #expect(result.limitReason == .provisionalLeaseCount)
        #expect(result.provisionalInputCount == 2)
        #expect(result.provisionalLeaseCount == 0)
        #expect(result.victimCount == 0)
        #expect(result.inspectedSlotCount == 0)
        #expect(
            cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            ).evictionStateVersion == before
        )
    }

    @Test("Sufficient bounded budget reproduces unbounded moved-hand snapshot exactly")
    func boundedSnapshotMatchesUnboundedMovedHandPlan() {
        let cache = movedHandFixture()
        let provisional: Set<Int> = [4]
        let expected = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: provisional,
            incomingCost: 2
        )
        let result = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: provisional,
            incomingCost: 2,
            maximumProvisionalLeaseCount: 1,
            maximumVictimCount: expected.plan.victims.count,
            maximumInspectedSlotCount: expected.plan.inspectedSlotCount
        )
        let bounded = result.snapshot
        #expect(result.limitReason == nil)
        #expect(bounded?.plan.victims.map(\.key) == expected.plan.victims.map(\.key))
        #expect(bounded?.plan.victims.map(\.cost) == expected.plan.victims.map(\.cost))
        #expect(bounded?.plan.provisionalRevocations == expected.plan.provisionalRevocations)
        #expect(bounded?.plan.releasedCost == expected.plan.releasedCost)
        #expect(
            bounded?.plan.fullVisitedEpochResetCount
                == expected.plan.fullVisitedEpochResetCount
        )
        #expect(bounded?.plan.inspectedSlotCount == expected.plan.inspectedSlotCount)
        #expect(bounded?.evictionStateVersion == expected.evictionStateVersion)
    }

    @Test("Bounded snapshot carries its inspection budget through irrelevant stale validation")
    func boundedCommitAcceptsIrrelevantTailHitWithinInspectionBudget() {
        let residentCount = 8
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        #expect(handOrder.count == residentCount)

        let bounded = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: 1,
            maximumInspectedSlotCount: 1
        )
        let snapshot = bounded.snapshot
        #expect(snapshot?.plan.victims.map(\.key) == [handOrder[0]])
        #expect(snapshot?.maximumValidationInspectedSlotCount == 1)
        #expect(cache.value(for: handOrder[residentCount - 1]) == handOrder[residentCount - 1])

        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            residentCount,
            for: residentCount,
            cost: 1,
            expectedSnapshot: snapshot!
        )
        #expect(result.accepted)
        #expect(result.validationMode == .exactStreaming)
        #expect(result.validationInspectedSlotCount == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: handOrder[0]) == nil)
        #expect(cache.resourceProbeValueWithoutVisit(for: residentCount) == residentCount)
        #expect(cache.count == residentCount)
        #expect(cache.currentCost == residentCount)
    }

    @Test("Bounded stale validation stops at the snapshot inspection budget before mutation")
    func boundedCommitRejectsWhenStaleValidationNeedsMoreInspection() {
        let residentCount = 8
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        #expect(handOrder.count == residentCount)

        let bounded = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: 1,
            maximumInspectedSlotCount: 1
        )
        let snapshot = bounded.snapshot
        #expect(snapshot?.plan.victims.map(\.key) == [handOrder[0]])
        #expect(cache.value(for: handOrder[0]) == handOrder[0])

        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            residentCount,
            for: residentCount,
            cost: 1,
            expectedSnapshot: snapshot!
        )
        #expect(!result.accepted)
        #expect(result.validationMode == .validationLimited)
        #expect(result.validationInspectedSlotCount == 1)
        #expect(cache.resourceProbeValueWithoutVisit(for: handOrder[0]) == handOrder[0])
        #expect(cache.resourceProbeValueWithoutVisit(for: residentCount) == nil)
        #expect(cache.count == residentCount)
        #expect(cache.currentCost == residentCount)
    }

    @Test("Deferred full-cost replacement matches classic SIEVE across complete N=8 visit states")
    func deferredFullCostReplacementDifferential() {
        let residentCount = 8
        let stateCount = intPow(3, residentCount)
        var checked = 0
        for encoded in 0..<stateCount {
            let ternary = decodeTernary(encoded, digits: residentCount)
            let classic = makeCache(
                costs: [Int](repeating: 1, count: residentCount),
                ternary: ternary
            )
            let deferred = makeCache(
                costs: [Int](repeating: 1, count: residentCount),
                ternary: ternary
            )

            classic.insert(99, for: 99, cost: residentCount)
            let retired = deferred.resourceProbeInsertFullCostUsingDeferredRetirement(
                99,
                for: 99,
                cost: residentCount
            )

            #expect(retired?.itemCount == residentCount)
            #expect(retired?.costBytes == residentCount)
            #expect(classic.count == 1)
            #expect(deferred.count == 1)
            #expect(classic.currentCost == residentCount)
            #expect(deferred.currentCost == residentCount)
            #expect(classic.resourceProbeValueWithoutVisit(for: 99) == 99)
            #expect(deferred.resourceProbeValueWithoutVisit(for: 99) == 99)
            for key in 0..<residentCount {
                #expect(classic.resourceProbeValueWithoutVisit(for: key) == nil)
                #expect(deferred.resourceProbeValueWithoutVisit(for: key) == nil)
            }
            #expect(classic.resourceProbeVisitState().visitedCount == 0)
            #expect(deferred.resourceProbeVisitState().visitedCount == 0)
            #expect(
                classic.resourceProbeEvictionTrace(incomingCost: 1).victims.map(\.key)
                    == deferred.resourceProbeEvictionTrace(incomingCost: 1).victims.map(\.key)
            )
            checked += 1
        }
        #expect(checked == 6_561)
    }

    @Test("Deferred full-cost replacement refuses near-full and same-key cases without mutation")
    func deferredFullCostReplacementEligibilityIsNarrow() {
        let cache = MemoryCache<Int, Int>(costLimit: 8)
        for key in 0..<8 { cache.insert(key, for: key, cost: 1) }
        let beforeVersion = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        ).evictionStateVersion

        #expect(
            cache.resourceProbeInsertFullCostUsingDeferredRetirement(
                100,
                for: 100,
                cost: 7
            ) == nil
        )
        #expect(
            cache.resourceProbeInsertFullCostUsingDeferredRetirement(
                0,
                for: 0,
                cost: 8
            ) == nil
        )
        #expect(cache.count == 8)
        #expect(cache.currentCost == 8)
        #expect(
            cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            ).evictionStateVersion == beforeVersion
        )
    }

    @Test("Deferred full-cost replacement destroys retired values only after logical swap unlock")
    func deferredFullCostReplacementMovesDestructionOutsideCriticalSection() {
        let counter = RetirementDeinitCounter()
        let cache = MemoryCache<Int, RetirementObservedValue>(costLimit: 4)
        for key in 0..<4 {
            cache.insert(RetirementObservedValue(counter: counter), for: key, cost: 1)
        }
        let candidate = RetirementObservedValue(counter: counter)
        var deinitCountWhileSwapLockHeld = -1

        let retired = cache.resourceProbeInsertFullCostUsingDeferredRetirement(
            candidate,
            for: 99,
            cost: 4,
            afterLogicalSwapBeforeRetirement: {
                deinitCountWhileSwapLockHeld = counter.value
            }
        )

        #expect(retired?.itemCount == 4)
        #expect(retired?.costBytes == 4)
        #expect(deinitCountWhileSwapLockHeld == 0)
        #expect(counter.value == 4)
        #expect(cache.count == 1)
        #expect(cache.currentCost == 4)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) === candidate)
    }

    @Test("Bounded deferred retirement reports backpressure before logical mutation")
    func boundedDeferredRetirementBackpressuresWithoutMutation() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        let beforeVersion = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        ).evictionStateVersion

        let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            99,
            for: 99,
            cost: 4,
            maximumConcurrentRetirements: 0
        )

        #expect(attempt.disposition == .backpressured)
        #expect(attempt.summary == nil)
        #expect(cache.count == 4)
        #expect(cache.currentCost == 4)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) == nil)
        #expect(
            cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            ).evictionStateVersion == beforeVersion
        )
    }

    @Test("Bounded deferred retirement succeeds within one in-flight slot")
    func boundedDeferredRetirementUsesAvailableSlot() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }

        let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            99,
            for: 99,
            cost: 4,
            maximumConcurrentRetirements: 1
        )

        #expect(attempt.disposition == .replaced)
        #expect(attempt.summary?.itemCount == 4)
        #expect(attempt.summary?.costBytes == 4)
        #expect(cache.count == 1)
        #expect(cache.currentCost == 4)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) == 99)
    }

    @Test("Bounded deferred retirement distinguishes ineligible from backpressured")
    func boundedDeferredRetirementEligibilityRemainsNarrow() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }

        let nearFull = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            99,
            for: 99,
            cost: 3,
            maximumConcurrentRetirements: 0
        )
        let sameKey = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            100,
            for: 0,
            cost: 4,
            maximumConcurrentRetirements: 0
        )

        #expect(nearFull.disposition == .ineligible)
        #expect(sameKey.disposition == .ineligible)
        #expect(cache.count == 4)
        #expect(cache.currentCost == 4)
        #expect(cache.resourceProbeValueWithoutVisit(for: 0) == 0)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) == nil)
    }
}
