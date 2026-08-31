import Foundation

package struct FileBlobStoreSegmentedStablePrefixAutomaticSnapshot: Sendable {
    package let inFlight: Bool
    package let attemptCount: Int
    package let preparedCount: Int
    package let adoptedCount: Int
    package let nilCount: Int
    package let errorCount: Int
    package let hardCapCancellationCount: Int
    package let plannerNoCandidateCount: Int
    package let frozenDescriptorFloorCount: Int
    package let frozenByteExpansionCount: Int
    package let suffixBeforeMaterializationCount: Int
    package let suffixAfterMaterializationCount: Int
    package let staleOrCancelledCount: Int
    package let nextRetryRunCount: Int?
    package let lastRejection: FileBlobStoreSegmentedRunPrefixPreparationRejection?
    package let lastTriggerGeneration: UInt64?
    package let lastTriggerRunCount: Int?
    package let lastPreparedSuffixRunCount: Int?
    package let maximumPreparedSuffixRunCount: Int
}

extension FileBlobStore {
    /// Launch one package-only stable-prefix attempt after a V4 checkpoint reaches its configured
    /// trigger count. The outer task is not stored by the actor, avoiding a self-retain cycle; the
    /// task itself retains the store until the bounded attempt exits, which deliberately keeps the
    /// single-writer lease alive while detached filesystem work may still touch this generation.
    ///
    /// A completed candidate is adopted immediately. Holding an unreferenced prepared topology
    /// until the hard boundary would increase physical debt and leave avoidable suffix depth.
    func scheduleAutomaticSegmentedRunPrefixPreparationIfNeeded() {
        guard !requiresReopenBeforeFurtherAccess,
            let triggerRunCount = segmentedManifestRunCapacityPolicy.automaticV4StablePrefixRunCount,
            (2...62).contains(triggerRunCount),
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.generation == manifest.generation
        else { return }
        let currentRunCount = currentRoot.runs.count
        let retryEligible = segmentedManifestAutomaticStablePrefixNextRetryRunCount.map {
            currentRunCount >= $0
        } ?? false
        guard currentRunCount < SegmentedManifestPrototypeV1.maximumRunDescriptors,
            currentRunCount == triggerRunCount || retryEligible,
            !segmentedManifestAutomaticStablePrefixInFlight,
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestCheckpointPresealCandidate == nil,
            segmentedManifestCompoundPresealCandidate == nil,
            segmentedManifestRunPrefixCollapseCandidate == nil,
            segmentedManifestRunPrefixPreparationTask == nil,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            segmentedManifestRunPrefixMaterializationTask == nil
        else { return }

        segmentedManifestAutomaticStablePrefixInFlight = true
        segmentedManifestAutomaticStablePrefixAttemptCount += 1
        segmentedManifestAutomaticStablePrefixNextRetryRunCount = nil
        segmentedManifestAutomaticStablePrefixLastRejection = nil
        segmentedManifestAutomaticStablePrefixLastTriggerGeneration = currentRoot.generation
        segmentedManifestAutomaticStablePrefixLastTriggerRunCount = currentRoot.runs.count
        let attemptPrefixRunCount = currentRoot.runs.count
        let preparationObserver = segmentedManifestAutomaticStablePrefixPreparationObserver
        let materializationObserver = segmentedManifestAutomaticStablePrefixMaterializationObserver

        Task { [self] in
            do {
                guard let prepared = try await resourceProbePrepareSegmentedRunPrefixCollapseV4(
                    prefixRunCount: attemptPrefixRunCount,
                    admission: .speculativeAutomatic,
                    preparationObserver: preparationObserver,
                    materializationObserver: materializationObserver,
                    rejectionObserver: { rejection in
                        await self.recordAutomaticSegmentedRunPrefixRejection(rejection)
                    }
                ) else {
                    completeAutomaticSegmentedRunPrefixAttempt(
                        prepared: false,
                        adopted: false,
                        preparedSuffixRunCount: nil
                    )
                    return
                }
                let adopted = try resourceProbeAdoptSegmentedRunPrefixCollapseV4() != nil
                completeAutomaticSegmentedRunPrefixAttempt(
                    prepared: true,
                    adopted: adopted,
                    preparedSuffixRunCount: prepared.suffixRunCount
                )
            } catch {
                segmentedManifestAutomaticStablePrefixErrorCount += 1
                segmentedManifestAutomaticStablePrefixInFlight = false
                segmentedManifestAutomaticStablePrefixNextRetryRunCount = nil
            }
        }
    }

    func recordAutomaticSegmentedRunPrefixHardCapCancellationIfNeeded() {
        guard segmentedManifestAutomaticStablePrefixInFlight,
            segmentedManifestRunPrefixPreparationTask != nil
                || segmentedManifestRunPrefixMaterializationTask != nil
        else { return }
        segmentedManifestAutomaticStablePrefixHardCapCancellationCount += 1
    }

    private func completeAutomaticSegmentedRunPrefixAttempt(
        prepared: Bool,
        adopted: Bool,
        preparedSuffixRunCount: Int?
    ) {
        if prepared {
            segmentedManifestAutomaticStablePrefixPreparedCount += 1
            if let preparedSuffixRunCount {
                segmentedManifestAutomaticStablePrefixLastPreparedSuffixRunCount =
                    preparedSuffixRunCount
                segmentedManifestAutomaticStablePrefixMaximumPreparedSuffixRunCount = max(
                    segmentedManifestAutomaticStablePrefixMaximumPreparedSuffixRunCount,
                    preparedSuffixRunCount
                )
            }
        } else {
            segmentedManifestAutomaticStablePrefixNilCount += 1
        }
        if adopted { segmentedManifestAutomaticStablePrefixAdoptedCount += 1 }
        if prepared || adopted {
            segmentedManifestAutomaticStablePrefixNextRetryRunCount = nil
            segmentedManifestAutomaticStablePrefixLastRejection = nil
        }
        segmentedManifestAutomaticStablePrefixInFlight = false
        // A descriptor-floor hint may have become eligible while the rejected detached attempt was
        // still running. Re-enter through the same scheduler instead of waiting for an unrelated
        // future checkpoint. Never re-enter merely because the old exact trigger still matches:
        // planner/byte/suffix nil outcomes without a retry hint are intentionally one-shot.
        if let retryRunCount = segmentedManifestAutomaticStablePrefixNextRetryRunCount,
            let currentRoot = segmentedManifestRoot,
            currentRoot.runs.count >= retryRunCount,
            currentRoot.runs.count < SegmentedManifestPrototypeV1.maximumRunDescriptors
        {
            scheduleAutomaticSegmentedRunPrefixPreparationIfNeeded()
        }
    }

    private func recordAutomaticSegmentedRunPrefixRejection(
        _ rejection: FileBlobStoreSegmentedRunPrefixPreparationRejection
    ) {
        segmentedManifestAutomaticStablePrefixLastRejection = rejection
        segmentedManifestAutomaticStablePrefixNextRetryRunCount = nil
        switch rejection {
        case .plannerNoCandidate:
            segmentedManifestAutomaticStablePrefixPlannerNoCandidateCount += 1
        case let .frozenDescriptorFloor(nextEligibleRunCount):
            segmentedManifestAutomaticStablePrefixFrozenDescriptorFloorCount += 1
            if nextEligibleRunCount < SegmentedManifestPrototypeV1.maximumRunDescriptors {
                segmentedManifestAutomaticStablePrefixNextRetryRunCount = nextEligibleRunCount
            }
        case .frozenByteExpansion:
            segmentedManifestAutomaticStablePrefixFrozenByteExpansionCount += 1
        case .suffixRecurrenceBeforeMaterialization:
            segmentedManifestAutomaticStablePrefixSuffixBeforeMaterializationCount += 1
        case .suffixRecurrenceAfterMaterialization:
            segmentedManifestAutomaticStablePrefixSuffixAfterMaterializationCount += 1
        case .staleOrCancelled:
            segmentedManifestAutomaticStablePrefixStaleOrCancelledCount += 1
        }
    }

    package func resourceProbeSegmentedStablePrefixAutomaticSnapshot()
        -> FileBlobStoreSegmentedStablePrefixAutomaticSnapshot
    {
        .init(
            inFlight: segmentedManifestAutomaticStablePrefixInFlight,
            attemptCount: segmentedManifestAutomaticStablePrefixAttemptCount,
            preparedCount: segmentedManifestAutomaticStablePrefixPreparedCount,
            adoptedCount: segmentedManifestAutomaticStablePrefixAdoptedCount,
            nilCount: segmentedManifestAutomaticStablePrefixNilCount,
            errorCount: segmentedManifestAutomaticStablePrefixErrorCount,
            hardCapCancellationCount:
                segmentedManifestAutomaticStablePrefixHardCapCancellationCount,
            plannerNoCandidateCount:
                segmentedManifestAutomaticStablePrefixPlannerNoCandidateCount,
            frozenDescriptorFloorCount:
                segmentedManifestAutomaticStablePrefixFrozenDescriptorFloorCount,
            frozenByteExpansionCount:
                segmentedManifestAutomaticStablePrefixFrozenByteExpansionCount,
            suffixBeforeMaterializationCount:
                segmentedManifestAutomaticStablePrefixSuffixBeforeMaterializationCount,
            suffixAfterMaterializationCount:
                segmentedManifestAutomaticStablePrefixSuffixAfterMaterializationCount,
            staleOrCancelledCount:
                segmentedManifestAutomaticStablePrefixStaleOrCancelledCount,
            nextRetryRunCount: segmentedManifestAutomaticStablePrefixNextRetryRunCount,
            lastRejection: segmentedManifestAutomaticStablePrefixLastRejection,
            lastTriggerGeneration: segmentedManifestAutomaticStablePrefixLastTriggerGeneration,
            lastTriggerRunCount: segmentedManifestAutomaticStablePrefixLastTriggerRunCount,
            lastPreparedSuffixRunCount:
                segmentedManifestAutomaticStablePrefixLastPreparedSuffixRunCount,
            maximumPreparedSuffixRunCount:
                segmentedManifestAutomaticStablePrefixMaximumPreparedSuffixRunCount
        )
    }

    package func resourceProbeSetSegmentedStablePrefixAutomaticObservers(
        preparation: FileBlobStoreSegmentedCompactionPreparationObserver? = nil,
        materialization: FileBlobStoreSegmentedCompactionPreparationObserver? = nil
    ) {
        segmentedManifestAutomaticStablePrefixPreparationObserver = preparation
        segmentedManifestAutomaticStablePrefixMaterializationObserver = materialization
    }
}
