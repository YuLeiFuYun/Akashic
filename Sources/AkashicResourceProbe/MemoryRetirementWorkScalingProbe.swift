import AkashicMemory
import Foundation

private final class RetirementWorkCounter: @unchecked Sendable {
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

private final class RetirementWorkValue: @unchecked Sendable {
    private let counter: RetirementWorkCounter?

    init(counter: RetirementWorkCounter?) { self.counter = counter }
    deinit { counter?.increment() }
}

private struct RetirementWorkScalingRow: Codable {
    let residentCount: Int
    let incomingCost: Int
    let survivorCount: Int
    let survivorInspectedSlotCount: Int
    let retiredVictimCount: Int
    let deinitCountWhileSwapLockHeld: Int
    let deinitCountBeforeReturn: Int
    let finalCacheCount: Int
    let finalCacheCost: Int
}

private struct RetirementWorkFullCostRow: Codable {
    let residentCount: Int
    let deinitCountWhileSwapLockHeld: Int
    let deinitCountBeforeReturn: Int
    let finalCacheCount: Int
    let finalCacheCost: Int
}

private struct RetirementWorkQueuedRow: Codable {
    let residentCount: Int
    let incomingCost: Int
    let survivorCount: Int
    let survivorInspectedSlotCount: Int
    let deinitCountBeforeReturn: Int
    let queuedGenerationCountBeforeDrain: Int
    let queuedItemCountBeforeDrain: Int
    let queuedCostBeforeDrain: Int
    let drainedItemCount: Int
    let drainedCost: Int
    let deinitCountAfterDrain: Int
    let debtGenerationCountAfterDrain: Int
    let debtItemCountAfterDrain: Int
    let finalCacheCount: Int
    let finalCacheCost: Int
}

private struct RetirementWorkQueuedFullCostRow: Codable {
    let residentCount: Int
    let deinitCountBeforeReturn: Int
    let queuedItemCountBeforeDrain: Int
    let queuedCostBeforeDrain: Int
    let deinitCountAfterDrain: Int
    let debtGenerationCountAfterDrain: Int
    let finalCacheCount: Int
    let finalCacheCost: Int
}

private struct RetirementWorkScalingReport: Codable {
    let schemaVersion: Int
    let residualCostBudget: Int
    let survivorRows: [RetirementWorkScalingRow]
    let fullCostRows: [RetirementWorkFullCostRow]
    let queuedSurvivorRows: [RetirementWorkQueuedRow]
    let queuedFullCostRows: [RetirementWorkQueuedFullCostRow]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum MemoryRetirementWorkScalingProbe {
    private static let residentCounts = [32, 128, 512, 2_048]
    private static let residualCostBudget = 8

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let survivorRows = try residentCounts.map(runSurvivorCase)
        let fullCostRows = residentCounts.map(runFullCostCase)
        let queuedSurvivorRows = try residentCounts.map(runQueuedSurvivorCase)
        let queuedFullCostRows = residentCounts.map(runQueuedFullCostCase)
        let checks: [String: Bool] = [
            "survivor-proof-work-is-constant-at-residual-budget": survivorRows.allSatisfy {
                $0.survivorCount == residualCostBudget
                    && $0.survivorInspectedSlotCount == residualCostBudget
            },
            "survivor-victim-destruction-is-zero-under-cache-lock": survivorRows.allSatisfy {
                $0.deinitCountWhileSwapLockHeld == 0
            },
            "survivor-victim-destruction-completes-before-call-returns": survivorRows.allSatisfy {
                $0.deinitCountBeforeReturn == $0.retiredVictimCount
                    && $0.retiredVictimCount == $0.residentCount - residualCostBudget
            },
            "full-cost-destruction-is-zero-under-cache-lock": fullCostRows.allSatisfy {
                $0.deinitCountWhileSwapLockHeld == 0
            },
            "full-cost-destroys-all-old-residents-before-call-returns": fullCostRows.allSatisfy {
                $0.deinitCountBeforeReturn == $0.residentCount
            },
            "all-logical-cost-bounds-preserved":
                survivorRows.allSatisfy { $0.finalCacheCost == $0.residentCount }
                    && fullCostRows.allSatisfy { $0.finalCacheCost == $0.residentCount }
                    && queuedSurvivorRows.allSatisfy { $0.finalCacheCost == $0.residentCount }
                    && queuedFullCostRows.allSatisfy { $0.finalCacheCost == $0.residentCount },
            "queued-survivor-returns-before-victim-destruction": queuedSurvivorRows.allSatisfy {
                $0.deinitCountBeforeReturn == 0
                    && $0.queuedGenerationCountBeforeDrain == 1
                    && $0.queuedItemCountBeforeDrain
                        == $0.residentCount - residualCostBudget
                    && $0.queuedCostBeforeDrain
                        == $0.residentCount - residualCostBudget
            },
            "queued-survivor-drain-repays-exact-debt": queuedSurvivorRows.allSatisfy {
                $0.drainedItemCount == $0.residentCount - residualCostBudget
                    && $0.drainedCost == $0.residentCount - residualCostBudget
                    && $0.deinitCountAfterDrain == $0.residentCount - residualCostBudget
                    && $0.debtGenerationCountAfterDrain == 0
                    && $0.debtItemCountAfterDrain == 0
            },
            "queued-full-cost-returns-before-destruction-and-drains-all": queuedFullCostRows
                .allSatisfy {
                    $0.deinitCountBeforeReturn == 0
                        && $0.queuedItemCountBeforeDrain == $0.residentCount
                        && $0.queuedCostBeforeDrain == $0.residentCount
                        && $0.deinitCountAfterDrain == $0.residentCount
                        && $0.debtGenerationCountAfterDrain == 0
                },
        ]
        let observations: [String: Bool] = [
            "bounded-survivor-selection-does-not-bound-synchronous-retirement-work":
                survivorRows.first!.survivorInspectedSlotCount
                    == survivorRows.last!.survivorInspectedSlotCount
                    && survivorRows.last!.deinitCountBeforeReturn
                        > survivorRows.first!.deinitCountBeforeReturn,
            "generation-count-bound-does-not-bound-items-in-one-retired-generation":
                survivorRows.last!.retiredVictimCount > 1_000,
            "exact-full-o1-logical-swap-still-has-linear-post-unlock-retirement":
                fullCostRows.map(\.deinitCountBeforeReturn) == residentCounts,
            "explicit-queue-moves-victim-destruction-from-admission-return-to-drain":
                queuedSurvivorRows.allSatisfy { $0.deinitCountBeforeReturn == 0 }
                    && queuedSurvivorRows.last!.deinitCountAfterDrain > 1_000,
            "queued-debt-scales-even-when-survivor-proof-work-is-fixed":
                queuedSurvivorRows.first!.survivorInspectedSlotCount
                    == queuedSurvivorRows.last!.survivorInspectedSlotCount
                    && queuedSurvivorRows.last!.queuedItemCountBeforeDrain
                        > queuedSurvivorRows.first!.queuedItemCountBeforeDrain,
        ]

        let report = RetirementWorkScalingReport(
            schemaVersion: 2,
            residualCostBudget: residualCostBudget,
            survivorRows: survivorRows,
            fullCostRows: fullCostRows,
            queuedSurvivorRows: queuedSurvivorRows,
            queuedFullCostRows: queuedFullCostRows,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "wallTimeLatency": false,
                "physicalRSSBytes": false,
                "criticalSectionRetirementDestruction": false,
                "callerSynchronousRetirementWorkScalesWithVictims": true,
                "retiredGenerationCountBoundsRetiredItemCount": false,
                "queuedRetirementRemovesVictimDestructionFromAdmissionReturn": true,
                "queuedRetirementEliminatesPhysicalLifetimeDebt": false,
                "explicitDrainRequired": true,
                "productionPolicyRecommendation": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    private static func runSurvivorCase(_ residentCount: Int) throws -> RetirementWorkScalingRow {
        let counter = RetirementWorkCounter()
        let cache = MemoryCache<Int, RetirementWorkValue>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(RetirementWorkValue(counter: counter), for: key, cost: 1)
        }
        for key in 0..<residentCount { precondition(cache.value(for: key) != nil) }
        let candidate = RetirementWorkValue(counter: nil)
        var underLock = -1
        let incomingCost = residentCount - residualCostBudget
        let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            candidate,
            for: residentCount,
            cost: incomingCost,
            maximumSurvivorCount: residualCostBudget,
            maximumInspectedSlotCount: residualCostBudget,
            maximumConcurrentRetirements: 1,
            afterLogicalSwapBeforeRetirement: { underLock = counter.value }
        )
        guard attempt.disposition == .replaced,
            let summary = attempt.summary
        else { throw ProbeError.resourceSampleFailed }
        return .init(
            residentCount: residentCount,
            incomingCost: incomingCost,
            survivorCount: attempt.survivorCount,
            survivorInspectedSlotCount: attempt.inspectedSlotCount,
            retiredVictimCount: summary.itemCount,
            deinitCountWhileSwapLockHeld: underLock,
            deinitCountBeforeReturn: counter.value,
            finalCacheCount: cache.count,
            finalCacheCost: cache.currentCost
        )
    }

    private static func runFullCostCase(_ residentCount: Int) -> RetirementWorkFullCostRow {
        let counter = RetirementWorkCounter()
        let cache = MemoryCache<Int, RetirementWorkValue>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(RetirementWorkValue(counter: counter), for: key, cost: 1)
        }
        let candidate = RetirementWorkValue(counter: nil)
        var underLock = -1
        let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            candidate,
            for: residentCount,
            cost: residentCount,
            maximumConcurrentRetirements: 1,
            afterLogicalSwapBeforeRetirement: { underLock = counter.value }
        )
        precondition(attempt.disposition == .replaced)
        return .init(
            residentCount: residentCount,
            deinitCountWhileSwapLockHeld: underLock,
            deinitCountBeforeReturn: counter.value,
            finalCacheCount: cache.count,
            finalCacheCost: cache.currentCost
        )
    }

    private static func runQueuedSurvivorCase(_ residentCount: Int) throws
        -> RetirementWorkQueuedRow
    {
        let counter = RetirementWorkCounter()
        let cache = MemoryCache<Int, RetirementWorkValue>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(RetirementWorkValue(counter: counter), for: key, cost: 1)
        }
        for key in 0..<residentCount { precondition(cache.value(for: key) != nil) }
        let candidate = RetirementWorkValue(counter: nil)
        let incomingCost = residentCount - residualCostBudget
        let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
            candidate,
            for: residentCount,
            cost: incomingCost,
            maximumSurvivorCount: residualCostBudget,
            maximumInspectedSlotCount: residualCostBudget,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        guard attempt.disposition == .replaced else { throw ProbeError.resourceSampleFailed }
        let beforeDrain = cache.resourceProbeRetirementDebtSnapshot()
        let deinitBeforeReturn = counter.value
        let drained = cache.resourceProbeDrainQueuedRetirement()
        let afterDrain = cache.resourceProbeRetirementDebtSnapshot()
        return .init(
            residentCount: residentCount,
            incomingCost: incomingCost,
            survivorCount: attempt.survivorCount,
            survivorInspectedSlotCount: attempt.inspectedSlotCount,
            deinitCountBeforeReturn: deinitBeforeReturn,
            queuedGenerationCountBeforeDrain: beforeDrain.queuedGenerationCount,
            queuedItemCountBeforeDrain: beforeDrain.itemCount,
            queuedCostBeforeDrain: beforeDrain.costBytes,
            drainedItemCount: drained.itemCount,
            drainedCost: drained.costBytes,
            deinitCountAfterDrain: counter.value,
            debtGenerationCountAfterDrain: afterDrain.generationCount,
            debtItemCountAfterDrain: afterDrain.itemCount,
            finalCacheCount: cache.count,
            finalCacheCost: cache.currentCost
        )
    }

    private static func runQueuedFullCostCase(_ residentCount: Int)
        -> RetirementWorkQueuedFullCostRow
    {
        let counter = RetirementWorkCounter()
        let cache = MemoryCache<Int, RetirementWorkValue>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(RetirementWorkValue(counter: counter), for: key, cost: 1)
        }
        let candidate = RetirementWorkValue(counter: nil)
        let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
            candidate,
            for: residentCount,
            cost: residentCount,
            maximumConcurrentRetirements: 1,
            retirementMode: .queueForExplicitDrain
        )
        precondition(attempt.disposition == .replaced)
        let beforeDrain = cache.resourceProbeRetirementDebtSnapshot()
        let deinitBeforeReturn = counter.value
        _ = cache.resourceProbeDrainQueuedRetirement()
        let afterDrain = cache.resourceProbeRetirementDebtSnapshot()
        return .init(
            residentCount: residentCount,
            deinitCountBeforeReturn: deinitBeforeReturn,
            queuedItemCountBeforeDrain: beforeDrain.itemCount,
            queuedCostBeforeDrain: beforeDrain.costBytes,
            deinitCountAfterDrain: counter.value,
            debtGenerationCountAfterDrain: afterDrain.generationCount,
            finalCacheCount: cache.count,
            finalCacheCost: cache.currentCost
        )
    }
}
