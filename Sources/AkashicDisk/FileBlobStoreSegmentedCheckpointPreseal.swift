import AkashicCore
import Foundation

package struct FileBlobStoreSegmentedCheckpointPresealResult: Sendable {
    package let generation: UInt64
    package let sourceSequence: UInt64
    package let sourceDistinctKeyCount: Int
    package let candidateFileName: String
    package let candidateByteCount: Int
    package let candidateRecordCount: Int
}

extension FileBlobStore {
    /// Package-only metadata republish used by V3 manifest research. This advances logical
    /// metadata authority without rewriting or reallocating the payload, so checkpoint experiments
    /// can vary epoch topology independently from PhysicalBlobID ownership.
    package func resourceProbeRepublishEntry(
        digest: BlobDigest,
        partition: CachePartitionID,
        lastAccess: Date
    ) throws {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            let root = segmentedManifestRoot,
            root.profile == SegmentedManifestPrototypeV1.profileV3
                || root.profile == SegmentedManifestPrototypeV1.profileV4
        else { throw AkashicError.transactionConflict }

        let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
        guard let current = manifest.entries[key],
            current.digest == digest,
            current.partition == partition
        else { throw AkashicError.notFound }

        manifest = try persistSingleKeyManifestEntry(
            key: key,
            entry: Entry(
                physicalID: current.physicalID,
                partition: current.partition,
                digest: current.digest,
                byteCount: current.byteCount,
                lastAccess: lastAccess
            )
        )
    }

    /// Explicit package-only V3 prefix preparation. The candidate is a durable immutable run file,
    /// but it has no logical authority until a later manifest root references it.
    ///
    /// First qualification deliberately excludes detached compaction and the final two run slots.
    /// Those composition cases are separate proof obligations after the basic prefix/tail protocol
    /// has exact authority/crash/resource evidence.
    package func resourceProbePrepareSegmentedCheckpointPresealV3()
        throws -> FileBlobStoreSegmentedCheckpointPresealResult
    {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.generation == manifest.generation,
            currentRoot.runs.count <= SegmentedManifestPrototypeV1.maximumRunDescriptors - 2,
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            segmentedManifestCheckpointPresealCandidate == nil
        else { throw AkashicError.transactionConflict }

        let state = try currentDirectoryHeadState()
        guard state.activeHead.g == manifest.generation,
            Int(state.activeHead.c) == state.latest.count,
            !state.latest.isEmpty,
            state.latest.count < SegmentedManifestPrototypeV1.maximumRunRecords
        else { throw AkashicError.limitExceeded }

        var mutations: [SegmentedManifestMutation] = []
        mutations.reserveCapacity(state.latest.count)
        for key in state.latest.keys.sorted() {
            guard let item = state.latest[key],
                item.record.generation == manifest.generation
            else { throw AkashicError.invalidManifest }
            mutations.append(try segmentedCheckpointMutation(key: key, item: item))
        }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: currentRoot,
            directory: segmentDirectory,
            preserving: segmentedManifestCompactionPreservedNames()
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: 1
        )
        let name = "run-g\(manifest.generation)-\(UUID().uuidString.lowercased()).seg"
        let descriptor = try SegmentedManifestPrototypeV1.writeRun(
            mutations,
            fileName: name,
            directory: segmentDirectory
        )
        segmentedManifestCheckpointPresealCandidate = .init(
            generation: manifest.generation,
            sourceSequence: state.activeHead.s,
            sourceDistinctKeyCount: state.latest.count,
            sourceHeadRoot: state.activeHead.r,
            descriptor: descriptor
        )
        return .init(
            generation: manifest.generation,
            sourceSequence: state.activeHead.s,
            sourceDistinctKeyCount: state.latest.count,
            candidateFileName: descriptor.fileName,
            candidateByteCount: descriptor.byteCount,
            candidateRecordCount: descriptor.recordCount
        )
    }

    /// Returns a completed checkpoint when a prepared prefix can reduce foreground run records.
    /// Returns nil after clearing an unusable/performance-useless candidate so the normal bounded
    /// checkpoint path remains the correctness/liveness fallback.
    func checkpointSegmentedManifestUsingPresealIfBeneficial(
        currentRoot: SegmentedManifestRootV1,
        previousDirectoryState: DirectoryHeadRecoveredState,
        transition: ManifestOwnershipTransition,
        normalMutationCount: Int
    ) throws -> Manifest? {
        guard let candidate = segmentedManifestCheckpointPresealCandidate else { return nil }

        guard candidate.generation == manifest.generation,
            currentRoot.generation == manifest.generation,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.runs.count <= SegmentedManifestPrototypeV1.maximumRunDescriptors - 2,
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            previousDirectoryState.activeHead.g == candidate.generation,
            previousDirectoryState.activeHead.s >= candidate.sourceSequence,
            candidate.sourceDistinctKeyCount == candidate.descriptor.recordCount,
            candidate.sourceDistinctKeyCount > 0,
            candidate.sourceDistinctKeyCount < SegmentedManifestPrototypeV1.maximumRunRecords
        else {
            segmentedManifestCheckpointPresealCandidate = nil
            return nil
        }

        var tailByKey: [String: SegmentedManifestMutation] = [:]
        tailByKey.reserveCapacity(
            min(previousDirectoryState.latest.count + 1, SegmentedManifestPrototypeV1.maximumRunRecords)
        )
        for (key, item) in previousDirectoryState.latest
        where item.identity.sequence > candidate.sourceSequence {
            guard item.record.generation == manifest.generation else {
                throw AkashicError.invalidManifest
            }
            tailByKey[key] = try segmentedCheckpointMutation(key: key, item: item)
        }
        tailByKey[transition.key] = try segmentedCheckpointMutation(transition: transition)

        // A candidate never becomes required for correctness. Heavy churn can leave all 512 keys in
        // the tail; in that case prefix+tail moves no record work out of the boundary and would only
        // add a root descriptor, so discard it and use the normal one-run checkpoint.
        guard !tailByKey.isEmpty,
            tailByKey.count <= SegmentedManifestPrototypeV1.maximumRunRecords,
            tailByKey.count < normalMutationCount
        else {
            segmentedManifestCheckpointPresealCandidate = nil
            return nil
        }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        do {
            // The candidate has existed across foreground operations. Re-read and hash it before a
            // root can grant authority; actor memory alone is not an integrity proof for the file.
            let decoded = try SegmentedManifestPrototypeV1.readRun(
                candidate.descriptor,
                directory: segmentDirectory
            )
            guard decoded.count == candidate.sourceDistinctKeyCount else {
                throw AkashicError.invalidManifest
            }
        } catch {
            // Non-authoritative speculative metadata must not become a mandatory availability
            // dependency. Clear the actor hint; normal checkpoint cleanup will reclaim the file or
            // fail closed on an unsafe filesystem identity.
            segmentedManifestCheckpointPresealCandidate = nil
            return nil
        }

        let tailMutations = tailByKey.values.sorted { $0.key < $1.key }
        let tailByteCount = SegmentedManifestPrototypeV1.headerBytes
            + tailMutations.count * SegmentedManifestPrototypeV1.runRecordBytes
        let referencedBytes = currentRoot.base.byteCount
            + currentRoot.runs.reduce(0) { $0 + $1.byteCount }
        guard referencedBytes
            <= SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes
                - candidate.descriptor.byteCount - tailByteCount
        else {
            segmentedManifestCheckpointPresealCandidate = nil
            return nil
        }

        try repayDirectoryHeadCleanupDebtBeforeMutation(
            limit: staleDirectoryHeadCleanupQueue.count
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: currentRoot,
            directory: segmentDirectory,
            preserving: Set([candidate.descriptor.fileName])
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: 1
        )

        let nextGeneration = currentRoot.generation + 1
        let tailName = "run-g\(nextGeneration)-\(UUID().uuidString.lowercased()).seg"
        let tailDescriptor: SegmentedManifestDescriptorV1
        do {
            tailDescriptor = try SegmentedManifestPrototypeV1.writeRun(
                tailMutations,
                fileName: tailName,
                directory: segmentDirectory
            )
        } catch {
            throw error
        }

        let nextRoot = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: nextGeneration,
            base: currentRoot.base,
            runs: currentRoot.runs + [candidate.descriptor, tailDescriptor]
        )
        let injector = faultInjector
        do {
            try SegmentedManifestPrototypeV1.writeRoot(
                nextRoot,
                to: manifestURL,
                faultInjector: { point in
                    try Self.forwardManifestFault(point, to: injector)
                }
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        return try adoptSegmentedSingleKeyCheckpointPublication(
            nextRoot: nextRoot,
            previousDirectoryState: previousDirectoryState,
            transition: transition
        )
    }

    func segmentedCheckpointMutation(
        key: String,
        item: DirectoryHeadLatestRecord
    ) throws -> SegmentedManifestMutation {
        if let entry = item.record.entry {
            guard manifest.entries[key] == entry,
                Self.isValidManifestEntryCore(key: key, entry: entry)
            else { throw AkashicError.invalidManifest }
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
        guard manifest.entries[key] == nil else { throw AkashicError.invalidManifest }
        return .tombstone(key: key)
    }

    func segmentedCheckpointMutation(
        transition: ManifestOwnershipTransition
    ) throws -> SegmentedManifestMutation {
        if let entry = transition.newEntry {
            guard Self.isValidManifestEntryCore(key: transition.key, entry: entry) else {
                throw AkashicError.storageUnavailable
            }
            return .upsert(
                SegmentedManifestEntry(
                    key: transition.key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: entry.lastAccess
                )
            )
        }
        return .tombstone(key: transition.key)
    }

    func adoptSegmentedSingleKeyCheckpointPublication(
        nextRoot: SegmentedManifestRootV1,
        previousDirectoryState: DirectoryHeadRecoveredState,
        transition: ManifestOwnershipTransition
    ) throws -> Manifest {
        let nextGeneration = nextRoot.generation
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
        segmentedManifestCheckpointPresealCandidate = nil
        segmentedManifestCompoundPresealCandidate = nil
        segmentedManifestCompoundFinalizeFaultInjector = nil

        if let entry = transition.newEntry {
            manifest.entries[transition.key] = entry
        } else {
            manifest.entries.removeValue(forKey: transition.key)
        }
        do {
            try adoptSchema4SingleKeyOwnershipTransition(transition)
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        manifest = Manifest(
            schemaVersion: manifest.schemaVersion,
            generation: nextGeneration,
            deltaCarrierProfile: manifest.deltaCarrierProfile,
            entries: manifest.entries
        )
        return manifest
    }
}
