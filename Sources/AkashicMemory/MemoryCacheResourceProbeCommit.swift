import Foundation

extension MemoryCache {
    /// Package-only optimistic transaction seam for admission research. An unchanged monotonic
    /// eviction-state token skips duplicate structural validation; if any decision state changed,
    /// commit falls back to allocation-free exact streaming comparison so irrelevant interleavings
    /// may still be accepted. Revocation and insertion share the same mutation lock boundary.
    ///
    /// This seam intentionally accepts only a new key. Same-key replacement detaches the old node
    /// before production eviction and therefore requires a separate admission contract.
    @discardableResult
    package func resourceProbeInsertIfRevocationAwarePlanMatches(
        _ value: Value,
        for key: Key,
        cost: Int,
        expectedSnapshot: MemoryCacheRevocationAwareEvictionSnapshot<Key>
    ) -> Bool {
        resourceProbeCommitRevocationAwareSnapshot(
            value,
            for: key,
            cost: cost,
            expectedSnapshot: expectedSnapshot
        ).accepted
    }

    package func resourceProbeCommitRevocationAwareSnapshot(
        _ value: Value,
        for key: Key,
        cost: Int,
        expectedSnapshot: MemoryCacheRevocationAwareEvictionSnapshot<Key>
    ) -> MemoryCacheRevocationAwareCommitResult {
        atomic {
            let normalizedCost = max(1, cost)
            guard entries[key] == nil,
                normalizedCost <= costLimit,
                normalizedCost == expectedSnapshot.normalizedIncomingCost
            else {
                return .init(accepted: false, validationMode: .inputRejected)
            }

            let currentVersion = currentEvictionStateVersionLocked()
            let versionFastPath = expectedSnapshot.evictionStateVersion != nil
                && expectedSnapshot.evictionStateVersion == currentVersion
            var validationInspectedSlotCount = 0
            if !versionFastPath {
                var validationLimitExceeded = false
                let validationMatches = resourceProbeRevocationAwareEvictionPlanMatchesLocked(
                    expectedSnapshot,
                    incomingCost: normalizedCost,
                    inspectedSlotCount: &validationInspectedSlotCount,
                    maximumInspectedSlotCount:
                        expectedSnapshot.maximumValidationInspectedSlotCount,
                    limitExceeded: &validationLimitExceeded
                )
                if validationLimitExceeded {
                    return .init(
                        accepted: false,
                        validationMode: .validationLimited,
                        validationInspectedSlotCount: validationInspectedSlotCount
                    )
                }
                guard validationMatches else {
                    return .init(
                        accepted: false,
                        validationMode: .exactStreaming,
                        validationInspectedSlotCount: validationInspectedSlotCount
                    )
                }
            }

            for provisionalKey in expectedSnapshot.plan.provisionalRevocations {
                guard let node = entries[provisionalKey],
                    node.visitedEpoch == visitEpoch,
                    expectedSnapshot.provisionalResidentLeases[provisionalKey]?.matches(
                        identity: node,
                        incarnation: node.incarnation
                    ) == true
                else {
                    preconditionFailure("validated provisional revocation must still be resident")
                }
                node.visitedEpoch = 0
                visitedCount -= 1
                precondition(visitedCount >= 0)
            }
            precondition(insertLocked(value, for: key, cost: normalizedCost))
            markEvictionStateChangedLocked()
            return .init(
                accepted: true,
                validationMode: versionFastPath ? .versionFastPath : .exactStreaming,
                validationInspectedSlotCount: validationInspectedSlotCount
            )
        }
    }
}
