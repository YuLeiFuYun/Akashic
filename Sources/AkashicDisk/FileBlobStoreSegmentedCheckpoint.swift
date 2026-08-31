import AkashicCore
import Foundation

extension FileBlobStore {
    /// Single-key V3 epoch rollover built only from the bounded directory-head delta set.
    ///
    /// The generic checkpoint path intentionally retains full-manifest validation for arbitrary
    /// multi-key candidates. This path is narrower: the transition has already been checked against
    /// the actor's O(1) PhysicalBlobID ownership index, and the committed directory head contains at
    /// most 511 other latest records. Those records plus the current transition are the complete
    /// logical delta that must become the next immutable run, so copying/scanning/rebuilding the
    /// entire live manifest would add O(live) work without strengthening the publication proof.
    func checkpointSegmentedManifest(
        applying transition: ManifestOwnershipTransition
    ) throws -> Manifest {
        guard loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            var currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV3
                || currentRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.generation == manifest.generation,
            manifestOwnershipIndex != nil,
            transition.oldEntry == manifest.entries[transition.key],
            currentRoot.generation < UInt64.max
        else { throw AkashicError.invalidManifest }

        let previousDirectoryState = try currentDirectoryHeadState()
        guard previousDirectoryState.activeHead.g == manifest.generation,
            Int(previousDirectoryState.activeHead.c) == previousDirectoryState.latest.count
        else { throw AkashicError.invalidManifest }

        var mutationByKey: [String: SegmentedManifestMutation] = [:]
        mutationByKey.reserveCapacity(previousDirectoryState.latest.count + 1)
        for (key, item) in previousDirectoryState.latest {
            guard item.record.generation == manifest.generation else {
                throw AkashicError.invalidManifest
            }
            mutationByKey[key] = try segmentedCheckpointMutation(key: key, item: item)
        }
        mutationByKey[transition.key] = try segmentedCheckpointMutation(transition: transition)

        guard !mutationByKey.isEmpty,
            mutationByKey.count <= SegmentedManifestPrototypeV1.maximumRunRecords
        else { throw AkashicError.limitExceeded }

        if currentRoot.profile == SegmentedManifestPrototypeV1.profileV4 {
            if let presealed = try checkpointSegmentedManifestUsingCompoundPresealIfBeneficial(
                currentRoot: currentRoot,
                previousDirectoryState: previousDirectoryState,
                transition: transition,
                normalMutationCount: mutationByKey.count
            ) {
                scheduleAutomaticSegmentedRunPrefixPreparationIfNeeded()
                return presealed
            }
        } else if currentRoot.profile == SegmentedManifestPrototypeV1.profileV3 {
            if let presealed = try checkpointSegmentedManifestUsingPresealIfBeneficial(
                currentRoot: currentRoot,
                previousDirectoryState: previousDirectoryState,
                transition: transition,
                normalMutationCount: mutationByKey.count
            ) {
                return presealed
            }
        }

        if currentRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors {
            switch currentRoot.profile {
            case SegmentedManifestPrototypeV1.profileV3:
                currentRoot = try relieveSegmentedManifestV3RunCapacitySynchronously(
                    frozenRoot: currentRoot
                )
            case SegmentedManifestPrototypeV1.profileV4:
                currentRoot = try relieveSegmentedManifestV4RunCapacitySynchronously(
                    frozenRoot: currentRoot
                )
            default:
                throw AkashicError.limitExceeded
            }
        }
        guard currentRoot.runs.count < SegmentedManifestPrototypeV1.maximumRunDescriptors else {
            throw AkashicError.limitExceeded
        }

        let mutations = mutationByKey.values.sorted { $0.key < $1.key }
        let runByteCount = SegmentedManifestPrototypeV1.headerBytes
            + mutations.count * SegmentedManifestPrototypeV1.runRecordBytes
        let referencedBytes = currentRoot.base.byteCount
            + currentRoot.runs.reduce(0) { $0 + $1.byteCount }
        guard referencedBytes
            <= SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes - runByteCount
        else { throw AkashicError.limitExceeded }

        let nextGeneration = currentRoot.generation + 1
        try repayDirectoryHeadCleanupDebtBeforeMutation(
            limit: staleDirectoryHeadCleanupQueue.count
        )

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: currentRoot,
            directory: segmentDirectory,
            preserving: segmentedManifestCompactionPreservedNames()
        )
        let reservedEntries = segmentedManifestUnmaterializedReservationCount(
            in: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: 1 + reservedEntries
        )

        let runFileName = "run-g\(nextGeneration)-\(UUID().uuidString.lowercased()).seg"
        let injector = faultInjector
        let nextRoot: SegmentedManifestRootV1
        do {
            nextRoot = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: mutations,
                runFileName: runFileName,
                currentRoot: currentRoot,
                rootURL: manifestURL,
                segmentDirectory: segmentDirectory,
                rootFaultInjector: { point in
                    try Self.forwardManifestFault(point, to: injector)
                }
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        let snapshot = try adoptSegmentedSingleKeyCheckpointPublication(
            nextRoot: nextRoot,
            previousDirectoryState: previousDirectoryState,
            transition: transition
        )
        scheduleAutomaticSegmentedRunPrefixPreparationIfNeeded()
        return snapshot
    }

    func checkpointSegmentedManifest(_ candidate: Manifest) throws -> Manifest {
        guard loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            candidate.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            candidate.deltaCarrierProfile == .directoryHeadV2,
            var currentRoot = segmentedManifestRoot,
            currentRoot.generation == manifest.generation
        else { throw AkashicError.invalidManifest }
        guard isValidManifestEntriesAndOwnership(candidate) else {
            throw AkashicError.storageUnavailable
        }

        let previousDirectoryState = try currentDirectoryHeadState()
        var changedKeys = Set(previousDirectoryState.latest.keys)
        for key in Set(manifest.entries.keys).union(candidate.entries.keys)
        where manifest.entries[key] != candidate.entries[key] {
            changedKeys.insert(key)
        }
        guard !changedKeys.isEmpty else { return manifest }
        guard changedKeys.count <= SegmentedManifestPrototypeV1.maximumRunRecords,
            currentRoot.generation < UInt64.max
        else { throw AkashicError.limitExceeded }

        if currentRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors {
            switch currentRoot.profile {
            case SegmentedManifestPrototypeV1.profileV3:
                currentRoot = try relieveSegmentedManifestV3RunCapacitySynchronously(
                    frozenRoot: currentRoot
                )
            case SegmentedManifestPrototypeV1.profileV4:
                currentRoot = try relieveSegmentedManifestV4RunCapacitySynchronously(
                    frozenRoot: currentRoot
                )
            default:
                throw AkashicError.limitExceeded
            }
        }
        guard currentRoot.runs.count < SegmentedManifestPrototypeV1.maximumRunDescriptors else {
            throw AkashicError.limitExceeded
        }

        let mutations = changedKeys.sorted().map { key -> SegmentedManifestMutation in
            if let entry = candidate.entries[key] {
                return .upsert(
                    SegmentedManifestEntry(
                        key: key,
                        physicalID: entry.physicalID,
                        partition: entry.partition,
                        digest: entry.digest,
                        byteCount: entry.byteCount,
                        lastAccess: entry.lastAccess
                    )
                )
            }
            return .tombstone(key: key)
        }
        let runByteCount = SegmentedManifestPrototypeV1.headerBytes
            + mutations.count * SegmentedManifestPrototypeV1.runRecordBytes
        let referencedBytes = currentRoot.base.byteCount
            + currentRoot.runs.reduce(0) { $0 + $1.byteCount }
        guard referencedBytes <= SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes - runByteCount else {
            throw AkashicError.limitExceeded
        }

        let nextGeneration = currentRoot.generation + 1
        let snapshot = Manifest(
            schemaVersion: Self.directoryHeadManifestSchemaVersion,
            generation: nextGeneration,
            deltaCarrierProfile: .directoryHeadV2,
            entries: candidate.entries
        )
        guard isValidManifestEntriesAndOwnership(snapshot) else {
            throw AkashicError.storageUnavailable
        }
        try repayDirectoryHeadCleanupDebtBeforeMutation(
            limit: staleDirectoryHeadCleanupQueue.count
        )

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: currentRoot,
            directory: segmentDirectory,
            preserving: segmentedManifestCompactionPreservedNames()
        )
        let reservedEntries = segmentedManifestUnmaterializedReservationCount(
            in: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: 1 + reservedEntries
        )
        let runFileName = "run-g\(nextGeneration)-\(UUID().uuidString.lowercased()).seg"
        let injector = faultInjector
        let nextRoot: SegmentedManifestRootV1
        do {
            nextRoot = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: mutations,
                runFileName: runFileName,
                currentRoot: currentRoot,
                rootURL: manifestURL,
                segmentDirectory: segmentDirectory,
                rootFaultInjector: { point in
                    try Self.forwardManifestFault(point, to: injector)
                }
            )
        } catch {
            // Run bytes may already be durable and root rename visibility can be ambiguous under
            // fault injection. A fresh bootstrap is the sole convergence path.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        let newState: DirectoryHeadRecoveredState
        do {
            newState = try initializeEmptyDirectoryHeadGeneration(generation: nextGeneration)
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        enqueueCurrentDirectoryHeadGenerationForCleanup(
            state: previousDirectoryState,
            generation: manifest.generation
        )
        directoryHeadState = newState
        manifestRecordSequence = 0
        manifestRecordKeys.removeAll(keepingCapacity: true)
        segmentedManifestRoot = nextRoot

        guard let rebuiltOwnership = validatedManifestOwnershipIndex(snapshot) else {
            requiresReopenBeforeFurtherAccess = true
            throw AkashicError.invalidManifest
        }
        manifestOwnershipIndex = rebuiltOwnership
        manifestLiveByteCount = rebuiltOwnership.totalBytes
        scheduleAutomaticSegmentedRunPrefixPreparationIfNeeded()
        return snapshot
    }
}
