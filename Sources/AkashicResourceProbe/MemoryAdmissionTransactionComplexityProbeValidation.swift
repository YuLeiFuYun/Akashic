import AkashicMemory
import Foundation

extension MemoryAdmissionTransactionComplexityProbe {
    static func runValidationCases() -> [AdmissionTransactionValidationCase] {
        var rows: [AdmissionTransactionValidationCase] = []

        do {
            let cache = seededColdCache(limit: 3)
            let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            let current = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            let result = cache.resourceProbeCommitRevocationAwareSnapshot(
                3,
                for: 3,
                cost: 1,
                expectedSnapshot: snapshot
            )
            rows.append(
                validationRow(
                    workload: "unchanged",
                    snapshot: snapshot,
                    current: current,
                    result: result,
                    cache: cache
                )
            )
        }

        do {
            let cache = seededColdCache(limit: 3)
            let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            _ = cache.resourceProbeValueWithoutVisit(for: 2)
            cache.remove(99)
            _ = cache.updateCostLimit(3)
            let current = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            let result = cache.resourceProbeCommitRevocationAwareSnapshot(
                3,
                for: 3,
                cost: 1,
                expectedSnapshot: snapshot
            )
            rows.append(
                validationRow(
                    workload: "noop-interleaving",
                    snapshot: snapshot,
                    current: current,
                    result: result,
                    cache: cache
                )
            )
        }

        do {
            let cache = seededColdCache(limit: 2)
            let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            _ = cache.value(for: 0)
            let current = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            let result = cache.resourceProbeCommitRevocationAwareSnapshot(
                2,
                for: 2,
                cost: 1,
                expectedSnapshot: snapshot
            )
            rows.append(
                validationRow(
                    workload: "relevant-hit",
                    snapshot: snapshot,
                    current: current,
                    result: result,
                    cache: cache
                )
            )
        }

        do {
            let cache = seededColdCache(limit: 3)
            let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            _ = cache.value(for: 2)
            let current = cache.resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: 1
            )
            let result = cache.resourceProbeCommitRevocationAwareSnapshot(
                3,
                for: 3,
                cost: 1,
                expectedSnapshot: snapshot
            )
            rows.append(
                validationRow(
                    workload: "irrelevant-hit",
                    snapshot: snapshot,
                    current: current,
                    result: result,
                    cache: cache
                )
            )
        }

        return rows
    }

    static func runValidationScanCase(
        size: Int,
        interleaving: String
    ) throws -> AdmissionTransactionValidationScanCase {
        guard size >= 3 else { throw ProbeError.resourceSampleFailed }
        let cache = MemoryCache<Int, Int>(costLimit: size)
        for key in 0..<size { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: size).victims.map(\.key)
        guard handOrder.count == size else { throw ProbeError.resourceSampleFailed }

        // Leave the penultimate hand resident cold as the one-cost victim. Every earlier resident is
        // visited, so finding that victim requires a long prefix scan. The final resident is outside
        // the decision trace and is the deliberately irrelevant interleaving target.
        for position in 0..<(size - 2) {
            guard cache.resourceProbeMarkVisited(for: handOrder[position]) else {
                throw ProbeError.resourceSampleFailed
            }
        }
        let snapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        guard snapshot.plan.victims.map(\.key) == [handOrder[size - 2]],
            snapshot.plan.inspectedSlotCount == size - 1
        else { throw ProbeError.resourceSampleFailed }

        switch interleaving {
        case "stable":
            break
        case "irrelevant-tail-hit":
            guard cache.value(for: handOrder[size - 1]) == handOrder[size - 1] else {
                throw ProbeError.resourceSampleFailed
            }
        default:
            throw ProbeError.resourceSampleFailed
        }

        let current = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        let victimSequenceStable = current.plan.victims.map(\.key)
            == snapshot.plan.victims.map(\.key)
        let mutationTrace = cache.resourceProbeEvictionTrace(incomingCost: 1)
        guard mutationTrace.fullVisitedEpochResetCount == 0,
            mutationTrace.victims.map(\.key) == snapshot.plan.victims.map(\.key)
        else { throw ProbeError.resourceSampleFailed }
        let mutationCandidateInspections = mutationTrace.clearedVisitedKeys.count
            + mutationTrace.victims.count

        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            size,
            for: size,
            cost: 1,
            expectedSnapshot: snapshot
        )
        return .init(
            residentCount: size,
            interleaving: interleaving,
            evictionStateVersionChanged:
                snapshot.evictionStateVersion != current.evictionStateVersion,
            accepted: result.accepted,
            validationMode: result.validationMode.rawValue,
            victimSequenceStable: victimSequenceStable,
            snapshotInspectedSlotCount: snapshot.plan.inspectedSlotCount,
            currentPlanInspectedSlotCount: current.plan.inspectedSlotCount,
            validationInspectedSlotCount: result.validationInspectedSlotCount,
            mutationClearedVisitedCount: mutationTrace.clearedVisitedKeys.count,
            mutationVictimCount: mutationTrace.victims.count,
            mutationEpochResetCount: mutationTrace.fullVisitedEpochResetCount,
            mutationCandidateInspectionCount: mutationCandidateInspections,
            totalStructuralInspectionCount:
                snapshot.plan.inspectedSlotCount
                    + result.validationInspectedSlotCount
                    + mutationCandidateInspections
        )
    }

    static func runValidationBudgetCase(
        size: Int,
        interleaving: String
    ) throws -> AdmissionTransactionValidationBudgetCase {
        guard size >= 2 else { throw ProbeError.resourceSampleFailed }
        let cache = MemoryCache<Int, Int>(costLimit: size)
        for key in 0..<size { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: size).victims.map(\.key)
        guard handOrder.count == size else { throw ProbeError.resourceSampleFailed }

        let bounded = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: 1,
            maximumInspectedSlotCount: 1
        )
        guard let snapshot = bounded.snapshot,
            snapshot.plan.victims.map(\.key) == [handOrder[0]],
            snapshot.maximumValidationInspectedSlotCount == 1
        else { throw ProbeError.resourceSampleFailed }

        switch interleaving {
        case "irrelevant-tail-hit":
            guard cache.value(for: handOrder[size - 1]) == handOrder[size - 1] else {
                throw ProbeError.resourceSampleFailed
            }
        case "relevant-victim-hit":
            guard cache.value(for: handOrder[0]) == handOrder[0] else {
                throw ProbeError.resourceSampleFailed
            }
        default:
            throw ProbeError.resourceSampleFailed
        }

        let result = cache.resourceProbeCommitRevocationAwareSnapshot(
            size,
            for: size,
            cost: 1,
            expectedSnapshot: snapshot
        )
        return AdmissionTransactionValidationBudgetCase(
            residentCount: size,
            interleaving: interleaving,
            maximumValidationInspectedSlotCount:
                snapshot.maximumValidationInspectedSlotCount ?? -1,
            snapshotVictimCount: snapshot.plan.victims.count,
            snapshotInspectedSlotCount: snapshot.plan.inspectedSlotCount,
            accepted: result.accepted,
            validationMode: result.validationMode.rawValue,
            validationInspectedSlotCount: result.validationInspectedSlotCount,
            originalVictimStillResident:
                cache.resourceProbeValueWithoutVisit(for: handOrder[0]) != nil,
            incomingResident: cache.resourceProbeValueWithoutVisit(for: size) != nil,
            finalResidentCount: cache.count,
            finalResidentCost: cache.currentCost
        )
    }

    static func seededColdCache(limit: Int) -> MemoryCache<Int, Int> {
        let cache = MemoryCache<Int, Int>(costLimit: limit)
        for key in 0..<limit { cache.insert(key, for: key, cost: 1) }
        return cache
    }

    static func validationRow(
        workload: String,
        snapshot: MemoryCacheRevocationAwareEvictionSnapshot<Int>,
        current: MemoryCacheRevocationAwareEvictionSnapshot<Int>,
        result: MemoryCacheRevocationAwareCommitResult,
        cache: MemoryCache<Int, Int>
    ) -> AdmissionTransactionValidationCase {
        .init(
            workload: workload,
            evictionStateVersionChanged:
                snapshot.evictionStateVersion != current.evictionStateVersion,
            accepted: result.accepted,
            validationMode: result.validationMode.rawValue,
            snapshotVictimCount: snapshot.plan.victims.count,
            finalResidentCount: cache.count,
            finalResidentCost: cache.currentCost
        )
    }

    static func runCase(
        size: Int,
        workload: String
    ) throws -> AdmissionTransactionComplexityCase {
        let cache = MemoryCache<Int, Int>(costLimit: size)
        for key in 0..<size { cache.insert(key, for: key, cost: 1) }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: size).victims.map(\.key)
        guard handOrder.count == size else { throw ProbeError.resourceSampleFailed }

        let visitedPositions: Set<Int>
        let provisionalPositions: Set<Int>
        let incomingCost: Int
        switch workload {
        case "all-hot":
            visitedPositions = Set(0..<size)
            provisionalPositions = []
            incomingCost = 1
        case "cold-prefix-hot-suffix":
            let prefix = max(1, size / 4)
            visitedPositions = Set(prefix..<size)
            provisionalPositions = []
            incomingCost = prefix + 1
        case "alternating":
            visitedPositions = Set((0..<size).filter { $0.isMultiple(of: 2) })
            provisionalPositions = []
            incomingCost = size / 2 + 1
        case "provisional-prefix":
            let prefix = max(1, size / 4)
            visitedPositions = Set(0..<size)
            provisionalPositions = Set(0..<prefix)
            incomingCost = prefix + 1
        case "tail-provisional":
            visitedPositions = Set(0..<size)
            provisionalPositions = [size - 1]
            incomingCost = 2
        case "near-two-pass-adversary":
            // Keep one ordinary second chance immediately before the final cold resident. The hand
            // must inspect the whole first revolution, then nearly the whole ring again before that
            // survivor becomes the final victim.
            visitedPositions = [size - 2]
            provisionalPositions = []
            incomingCost = size
        default:
            throw ProbeError.resourceSampleFailed
        }

        for position in visitedPositions {
            guard cache.resourceProbeMarkVisited(for: handOrder[position]) else {
                throw ProbeError.resourceSampleFailed
            }
        }
        let provisionalKeys = Set(provisionalPositions.map { handOrder[$0] })
        let plan = cache.resourceProbeRevocationAwareEvictionPlan(
            provisionalVisitedKeys: provisionalKeys,
            incomingCost: incomingCost
        )
        return AdmissionTransactionComplexityCase(
            residentCount: size,
            workload: workload,
            incomingCost: incomingCost,
            visitedCount: visitedPositions.count,
            provisionalCount: provisionalPositions.count,
            victimCount: plan.victims.count,
            revocationCount: plan.provisionalRevocations.count,
            releasedCost: plan.releasedCost,
            epochResetCount: plan.fullVisitedEpochResetCount,
            inspectedSlotCount: plan.inspectedSlotCount,
            inspectedSlotsPerResident: Double(plan.inspectedSlotCount) / Double(size)
        )
    }
}
