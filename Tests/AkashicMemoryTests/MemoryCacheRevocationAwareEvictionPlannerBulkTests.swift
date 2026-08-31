import AkashicMemory
import Foundation
import Testing

extension MemoryCacheRevocationAwareEvictionPlannerTests {
    @Test("All-visited survivor bulk path matches classic SIEVE across fragmentation family")
    func allVisitedSurvivorBulkMatchesClassicFragmentationFamily() {
        let layouts = [
            [Int](repeating: 30, count: 3),
            [Int](repeating: 15, count: 6),
            [Int](repeating: 10, count: 9),
            [Int](repeating: 5, count: 18),
            [Int](repeating: 2, count: 45),
            [Int](repeating: 1, count: 90),
        ]
        let expectedSurvivorCounts = [0, 0, 1, 2, 5, 10]
        let expectedInspectionCounts = [1, 1, 1, 2, 5, 10]

        for (layoutIndex, costs) in layouts.enumerated() {
            let classic = MemoryCache<Int, Int>(costLimit: 90)
            let candidate = MemoryCache<Int, Int>(costLimit: 90)
            for (key, cost) in costs.enumerated() {
                classic.insert(key, for: key, cost: cost)
                candidate.insert(key, for: key, cost: cost)
            }
            for key in costs.indices {
                #expect(classic.value(for: key) == key)
                #expect(candidate.value(for: key) == key)
            }

            classic.insert(999, for: 999, cost: 80)
            let attempt = candidate.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
                999,
                for: 999,
                cost: 80,
                maximumSurvivorCount: 10,
                maximumInspectedSlotCount: 10,
                maximumConcurrentRetirements: 1
            )

            #expect(attempt.disposition == .replaced)
            #expect(attempt.survivorCount == expectedSurvivorCounts[layoutIndex])
            #expect(attempt.inspectedSlotCount == expectedInspectionCounts[layoutIndex])
            #expect(candidate.count == classic.count)
            #expect(candidate.currentCost == classic.currentCost)
            for key in costs.indices {
                #expect(
                    candidate.resourceProbeValueWithoutVisit(for: key)
                        == classic.resourceProbeValueWithoutVisit(for: key)
                )
            }
            #expect(candidate.resourceProbeValueWithoutVisit(for: 999) == 999)

            let classicNext = classic.resourceProbeEvictionTrace(incomingCost: 90)
            let candidateNext = candidate.resourceProbeEvictionTrace(incomingCost: 90)
            #expect(candidateNext.victims.map(\.key) == classicNext.victims.map(\.key))
            #expect(candidateNext.victims.map(\.cost) == classicNext.victims.map(\.cost))
            #expect(
                candidateNext.fullVisitedEpochResetCount
                    == classicNext.fullVisitedEpochResetCount
            )
        }
    }

    @Test("All-visited survivor bulk path preserves moved-hand wrap and split FIFO survivors")
    func allVisitedSurvivorBulkMatchesClassicMovedHand() {
        for incomingCost in [3, 6] {
            let classic = movedAllVisitedUniformFixture()
            let candidate = movedAllVisitedUniformFixture()

            classic.insert(999, for: 999, cost: incomingCost)
            let attempt = candidate.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
                999,
                for: 999,
                cost: incomingCost,
                maximumSurvivorCount: 8 - incomingCost,
                maximumInspectedSlotCount: 8 - incomingCost + 1,
                maximumConcurrentRetirements: 1
            )

            #expect(attempt.disposition == .replaced)
            #expect(candidate.count == classic.count)
            #expect(candidate.currentCost == classic.currentCost)
            for key in 0...8 {
                #expect(
                    candidate.resourceProbeValueWithoutVisit(for: key)
                        == classic.resourceProbeValueWithoutVisit(for: key)
                )
            }
            #expect(candidate.resourceProbeValueWithoutVisit(for: 999) == 999)

            let classicTopology = classic.resourceProbeHandTopologyState()
            let candidateTopology = candidate.resourceProbeHandTopologyState()
            #expect(candidateTopology == classicTopology)
            let classicNext = classic.resourceProbeEvictionTrace(incomingCost: 8)
            let candidateNext = candidate.resourceProbeEvictionTrace(incomingCost: 8)
            #expect(candidateNext.victims.map(\.key) == classicNext.victims.map(\.key))
            #expect(candidateNext.victims.map(\.cost) == classicNext.victims.map(\.cost))
        }
    }

    @Test("All-visited survivor bulk resource limits reject without mutation")
    func allVisitedSurvivorBulkLimitsAreFailClosed() {
        func hotCache() -> MemoryCache<Int, Int> {
            let cache = MemoryCache<Int, Int>(costLimit: 8)
            for key in 0..<8 { cache.insert(key, for: key, cost: 1) }
            for key in 0..<8 { #expect(cache.value(for: key) == key) }
            return cache
        }

        for (survivorLimit, inspectionLimit, retirementLimit, expected) in [
            (1, 8, 1, MemoryCacheAllVisitedSurvivorDisposition.survivorLimit),
            (2, 1, 1, MemoryCacheAllVisitedSurvivorDisposition.inspectionLimit),
            (2, 8, 0, MemoryCacheAllVisitedSurvivorDisposition.retirementBackpressured),
        ] {
            let cache = hotCache()
            let beforeVersion = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            ).evictionStateVersion
            let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
                999,
                for: 999,
                cost: 6,
                maximumSurvivorCount: survivorLimit,
                maximumInspectedSlotCount: inspectionLimit,
                maximumConcurrentRetirements: retirementLimit
            )
            #expect(attempt.disposition == expected)
            #expect(attempt.summary == nil)
            #expect(cache.count == 8)
            #expect(cache.currentCost == 8)
            #expect(cache.resourceProbeValueWithoutVisit(for: 999) == nil)
            #expect(
                cache.resourceProbeRevocationAwareEvictionSnapshot(
                    provisionalVisitedKeys: [],
                    incomingCost: 1
                ).evictionStateVersion == beforeVersion
            )
        }
    }

    @Test("All-visited survivor bulk remains narrow on mixed visit state and no-eviction input")
    func allVisitedSurvivorBulkEligibilityRemainsNarrow() {
        let mixed = MemoryCache<Int, Int>(costLimit: 8)
        for key in 0..<8 { mixed.insert(key, for: key, cost: 1) }
        #expect(mixed.value(for: 0) == 0)
        let mixedAttempt = mixed.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            999,
            for: 999,
            cost: 6,
            maximumSurvivorCount: 2,
            maximumInspectedSlotCount: 3,
            maximumConcurrentRetirements: 1
        )
        #expect(mixedAttempt.disposition == .ineligible)
        #expect(mixed.count == 8)
        #expect(mixed.currentCost == 8)

        let sparse = MemoryCache<Int, Int>(costLimit: 8)
        for key in 0..<2 { sparse.insert(key, for: key, cost: 1) }
        for key in 0..<2 { #expect(sparse.value(for: key) == key) }
        let sparseAttempt = sparse.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            999,
            for: 999,
            cost: 6,
            maximumSurvivorCount: 2,
            maximumInspectedSlotCount: 3,
            maximumConcurrentRetirements: 1
        )
        #expect(sparseAttempt.disposition == .ineligible)
        #expect(sparse.resourceProbeValueWithoutVisit(for: 999) == nil)
    }

    @Test("All-visited survivor bulk destroys only retired victims after logical swap unlock")
    func allVisitedSurvivorBulkDefersVictimDestruction() {
        let counter = RetirementDeinitCounter()
        let cache = MemoryCache<Int, RetirementObservedValue>(costLimit: 4)
        for key in 0..<4 {
            cache.insert(RetirementObservedValue(counter: counter), for: key, cost: 1)
        }
        for key in 0..<4 { #expect(cache.value(for: key) != nil) }
        let candidate = RetirementObservedValue(counter: counter)
        var deinitCountWhileSwapLockHeld = -1

        let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            candidate,
            for: 99,
            cost: 3,
            maximumSurvivorCount: 1,
            maximumInspectedSlotCount: 1,
            maximumConcurrentRetirements: 1,
            afterLogicalSwapBeforeRetirement: {
                deinitCountWhileSwapLockHeld = counter.value
            }
        )

        #expect(attempt.disposition == .replaced)
        #expect(attempt.survivorCount == 1)
        #expect(attempt.summary?.itemCount == 3)
        #expect(attempt.summary?.costBytes == 3)
        #expect(deinitCountWhileSwapLockHeld == 0)
        #expect(counter.value == 3)
        #expect(cache.count == 2)
        #expect(cache.currentCost == 4)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) === candidate)
    }

    @Test("Queued survivor retirement returns before victim destruction and drains exact debt")
    func queuedSurvivorRetirementHasExplicitDebtAndDrain() {
        let counter = RetirementDeinitCounter()
        let cache = MemoryCache<Int, RetirementObservedValue>(costLimit: 8)
        for key in 0..<8 {
            cache.insert(RetirementObservedValue(counter: counter), for: key, cost: 1)
        }
        for key in 0..<8 { #expect(cache.value(for: key) != nil) }
        let candidate = RetirementObservedValue(counter: counter)
        var underLock = -1

        let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            candidate,
            for: 99,
            cost: 6,
            maximumSurvivorCount: 2,
            maximumInspectedSlotCount: 2,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain,
            afterLogicalSwapBeforeRetirement: { underLock = counter.value }
        )

        #expect(attempt.disposition == .replaced)
        #expect(attempt.summary?.itemCount == 6)
        #expect(attempt.summary?.costBytes == 6)
        #expect(underLock == 0)
        #expect(counter.value == 0)
        #expect(cache.count == 3)
        #expect(cache.currentCost == 8)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) === candidate)
        #expect(
            cache.resourceProbeRetirementDebtSnapshot()
                == .init(
                    queuedGenerationCount: 1,
                    inFlightGenerationCount: 0,
                    itemCount: 6,
                    costBytes: 6
                )
        )

        let drained = cache.resourceProbeDrainQueuedRetirement()
        #expect(drained.itemCount == 6)
        #expect(drained.costBytes == 6)
        #expect(counter.value == 6)
        #expect(
            cache.resourceProbeRetirementDebtSnapshot()
                == .init(
                    queuedGenerationCount: 0,
                    inFlightGenerationCount: 0,
                    itemCount: 0,
                    costBytes: 0
                )
        )
    }

    @Test("Queued retirement backpressures a second bulk generation until explicit drain")
    func queuedRetirementBackpressuresUntilDrain() {
        let cache = MemoryCache<Int, Int>(costLimit: 8)
        for key in 0..<8 { cache.insert(key, for: key, cost: 1) }
        for key in 0..<8 { #expect(cache.value(for: key) == key) }

        let first = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            99,
            for: 99,
            cost: 6,
            maximumSurvivorCount: 2,
            maximumInspectedSlotCount: 2,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        #expect(first.disposition == .replaced)
        for key in 0..<8 { _ = cache.value(for: key) }
        #expect(cache.value(for: 99) == 99)

        let blocked = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            100,
            for: 100,
            cost: 6,
            maximumSurvivorCount: 2,
            maximumInspectedSlotCount: 3,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        #expect(blocked.disposition == .retirementBackpressured)
        #expect(cache.resourceProbeValueWithoutVisit(for: 100) == nil)

        let fullCostBlocked = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            101,
            for: 101,
            cost: 8,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        #expect(fullCostBlocked.disposition == .backpressured)
        #expect(cache.resourceProbeValueWithoutVisit(for: 101) == nil)

        _ = cache.resourceProbeDrainQueuedRetirement()
        let retry = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            100,
            for: 100,
            cost: 6,
            maximumSurvivorCount: 2,
            maximumInspectedSlotCount: 3,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        #expect(retry.disposition == .replaced)
        #expect(cache.resourceProbeValueWithoutVisit(for: 100) == 100)
        _ = cache.resourceProbeDrainQueuedRetirement()
    }

    @Test("Queued retirement drain is reentrant-safe and exposes in-flight debt")
    func queuedRetirementDrainReentryBackpressuresInsteadOfDeadlocking() {
        let observer = RetirementReentrantObserver()
        let cache = MemoryCache<Int, RetirementReentrantValue>(costLimit: 4)
        observer.cache = cache
        for key in 0..<4 {
            cache.insert(RetirementReentrantValue(observer: observer), for: key, cost: 1)
        }
        for key in 0..<4 { #expect(cache.value(for: key) != nil) }

        let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            RetirementReentrantValue(observer: nil),
            for: 99,
            cost: 3,
            maximumSurvivorCount: 1,
            maximumInspectedSlotCount: 1,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        #expect(attempt.disposition == .replaced)
        #expect(observer.backpressuredAttempts == 0)

        let drained = cache.resourceProbeDrainQueuedRetirement()
        #expect(drained.itemCount == 3)
        #expect(observer.backpressuredAttempts == 3)
        #expect(observer.observedInFlightGenerations == [1, 1, 1])
        #expect(cache.count == 2)
        #expect(cache.currentCost == 4)
        #expect(cache.resourceProbeValueWithoutVisit(for: 99) != nil)
        #expect(cache.resourceProbeRetirementDebtSnapshot().generationCount == 0)
    }
}
