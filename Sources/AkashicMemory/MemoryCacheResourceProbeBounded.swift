import Foundation

extension MemoryCache {
    package func resourceProbeBoundedRevocationAwareEvictionSnapshot(
        provisionalVisitedKeys: Set<Key>,
        incomingCost: Int,
        maximumProvisionalLeaseCount: Int,
        maximumVictimCount: Int,
        maximumInspectedSlotCount: Int
    ) -> MemoryCacheRevocationAwareBoundedSnapshotResult<Key> {
        let maximumProvisionalLeaseCount = max(0, maximumProvisionalLeaseCount)
        let maximumVictimCount = max(0, maximumVictimCount)
        let maximumInspectedSlotCount = max(0, maximumInspectedSlotCount)
        guard provisionalVisitedKeys.count <= maximumProvisionalLeaseCount else {
            return .init(
                snapshot: nil,
                limitReason: .provisionalLeaseCount,
                provisionalInputCount: provisionalVisitedKeys.count,
                provisionalLeaseCount: 0,
                victimCount: 0,
                inspectedSlotCount: 0
            )
        }

        return atomic {
            let normalizedCost = max(1, incomingCost)
            var provisionalResidentLeases: [
                Key: MemoryCacheRevocationAwareResidentLease<Key>
            ] = [:]
            provisionalResidentLeases.reserveCapacity(provisionalVisitedKeys.count)
            for provisionalKey in provisionalVisitedKeys {
                guard let node = entries[provisionalKey], node.visitedEpoch == visitEpoch else {
                    continue
                }
                provisionalResidentLeases[provisionalKey] = .init(
                    key: provisionalKey,
                    identity: node,
                    incarnation: node.incarnation
                )
            }

            let build = resourceProbeRevocationAwareEvictionPlanBuildLocked(
                provisionalResidentLeases: provisionalResidentLeases,
                incomingCost: normalizedCost,
                maximumVictimCount: maximumVictimCount,
                maximumInspectedSlotCount: maximumInspectedSlotCount
            )
            guard let plan = build.plan else {
                return .init(
                    snapshot: nil,
                    limitReason: build.limitReason,
                    provisionalInputCount: provisionalVisitedKeys.count,
                    provisionalLeaseCount: provisionalResidentLeases.count,
                    victimCount: build.victimCount,
                    inspectedSlotCount: build.inspectedSlotCount
                )
            }
            return .init(
                snapshot: .init(
                    normalizedIncomingCost: normalizedCost,
                    evictionStateVersion: currentEvictionStateVersionLocked(),
                    maximumValidationInspectedSlotCount: maximumInspectedSlotCount,
                    provisionalResidentLeases: provisionalResidentLeases,
                    plan: plan
                ),
                limitReason: nil,
                provisionalInputCount: provisionalVisitedKeys.count,
                provisionalLeaseCount: provisionalResidentLeases.count,
                victimCount: plan.victims.count,
                inspectedSlotCount: plan.inspectedSlotCount
            )
        }
    }

    /// Package-only structural candidate for the exact full-cost case. For a new key whose
    /// normalized cost equals the complete cache limit, classic SIEVE must retire every current
    /// resident regardless of victim order. This seam swaps to the one-entry logical state under the
    /// mutex and keeps the old Dictionary buffer alive until after unlock, so value/node destruction
    /// is not charged to the cache critical section. It does not apply to near-full objects or
    /// same-key replacement, where exact survivor selection still matters.
    package func resourceProbeInsertFullCostUsingDeferredRetirement(
        _ value: Value,
        for key: Key,
        cost: Int,
        afterLogicalSwapBeforeRetirement: () -> Void = {}
    ) -> MemoryCacheRemovalSummary? {
        let attempt = resourceProbeTryInsertFullCostUsingDeferredRetirement(
            value,
            for: key,
            cost: cost,
            maximumConcurrentRetirements: .max,
            afterLogicalSwapBeforeRetirement: afterLogicalSwapBeforeRetirement
        )
        switch attempt.disposition {
        case .replaced:
            return attempt.summary
        case .ineligible, .backpressured:
            return nil
        }
    }

    /// Resource-bounded variant of the exact-full-cost replacement seam. The reservation is made
    /// under the same cache mutex as the logical swap, so concurrent callers cannot all pass an
    /// out-of-lock capacity check. Retired dictionaries are still released after the cache mutex is
    /// dropped, but no more than `maximumConcurrentRetirements` generations may be in that lifetime
    /// at once. A saturated reservation reports explicit backpressure without mutating cache state.
    package func resourceProbeTryInsertFullCostUsingDeferredRetirement(
        _ value: Value,
        for key: Key,
        cost: Int,
        maximumConcurrentRetirements: Int,
        retirementMode: MemoryCacheDeferredRetirementMode = .releaseBeforeReturn,
        afterLogicalSwapBeforeRetirement: () -> Void = {}
    ) -> MemoryCacheDeferredRetirementAttempt {
        let retirementLimit = max(0, maximumConcurrentRetirements)
        var retiredEntries: [Key: Node]? = nil
        var reservedRetirement = false
        var queuedRetirement = false
        let attempt = atomic { () -> MemoryCacheDeferredRetirementAttempt in
            let normalizedCost = max(1, cost)
            guard normalizedCost == costLimit, entries[key] == nil else {
                return .init(disposition: .ineligible, summary: nil)
            }
            guard retirementGenerationCountLocked() < retirementLimit,
                retirementMode != .queueForExplicitDrain || queuedRetirementEntries == nil
            else {
                return .init(disposition: .backpressured, summary: nil)
            }

            let result = MemoryCacheRemovalSummary(
                itemCount: entries.count,
                costBytes: totalCost
            )
            retiredEntries = entries
            let node = Node(key: key, value: value, cost: normalizedCost, previous: nil)
            entries = [key: node]
            leastRecent = node
            mostRecent = node
            sieveHand = nil
            totalCost = normalizedCost
            residentCount = 1
            visitedCount = 0
            visitEpoch = 1
            switch retirementMode {
            case .releaseBeforeReturn:
                beginRetirementInFlightLocked(result)
                reservedRetirement = true
            case .queueForExplicitDrain:
                queuedRetirementEntries = retiredEntries
                queuedRetirementItemCount = result.itemCount
                queuedRetirementCost = result.costBytes
                queuedRetirement = true
            }
            markEvictionStateChangedLocked()
            afterLogicalSwapBeforeRetirement()
            return .init(disposition: .replaced, summary: result)
        }
        if queuedRetirement {
            retiredEntries = nil
            return attempt
        }
        guard reservedRetirement else { return attempt }

        // Force destruction of the detached generation before returning its reservation. A value's
        // deinit may itself block or re-enter this cache; both happen outside the cache mutex. A
        // re-entrant bounded replacement therefore observes the in-flight reservation and receives
        // backpressure instead of deadlocking on a separate retirement gate.
        withExtendedLifetime(retiredEntries) {}
        retiredEntries = nil
        atomic { finishRetirementInFlightLocked(attempt.summary!) }
        return attempt
    }

    /// All-visited near-full complement of the exact-full dictionary swap. Once every resident is
    /// visited, production SIEVE first advances the visit epoch O(1), then removes one contiguous
    /// circular prefix from the effective hand. The exact survivors are therefore the longest
    /// circular suffix immediately before the hand whose total cost fits `costLimit - incoming`.
    ///
    /// This package-only candidate discovers that suffix by walking backward, bounded by explicit
    /// survivor/output and inspection ceilings. On success it rebuilds only the bounded survivor
    /// dictionary/list plus the incoming node and retires the old dictionary generation outside the
    /// cache mutex using the same concurrent-retirement reservation as the exact-full candidate.
    /// Mixed visited state, same-key replacement, no-eviction insertion and visit-epoch saturation
    /// deliberately remain outside this seam.
}
