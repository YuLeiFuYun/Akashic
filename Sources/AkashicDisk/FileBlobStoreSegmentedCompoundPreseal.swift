import AkashicCore
import Foundation

package struct FileBlobStoreSegmentedCompoundPresealResult: Sendable {
    package let generation: UInt64
    package let sourceSequence: UInt64
    package let sourceDistinctKeyCount: Int
    package let candidateFileName: String
    package let prefixByteCount: Int
}

extension FileBlobStore {
    package func resourceProbeSetSegmentedCompoundFinalizeFaultInjector(
        _ injector: SegmentedManifestCompoundRunV1.FinalizeFaultInjector?
    ) {
        segmentedManifestCompoundFinalizeFaultInjector = injector
    }

    package func resourceProbePrepareSegmentedCompoundPresealV4()
        throws -> FileBlobStoreSegmentedCompoundPresealResult
    {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.generation == manifest.generation,
            currentRoot.runs.count < SegmentedManifestPrototypeV1.maximumRunDescriptors,
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            segmentedManifestCheckpointPresealCandidate == nil,
            segmentedManifestCompoundPresealCandidate == nil,
            segmentedManifestRunPrefixCollapseCandidate == nil
        else { throw AkashicError.transactionConflict }

        let state = try currentDirectoryHeadState()
        guard state.activeHead.g == manifest.generation,
            Int(state.activeHead.c) == state.latest.count,
            !state.latest.isEmpty,
            state.latest.count <= SegmentedManifestCompoundRunV1.maximumPrefixRecords
        else { throw AkashicError.limitExceeded }

        var prefix: [SegmentedManifestMutation] = []
        prefix.reserveCapacity(state.latest.count)
        for key in state.latest.keys.sorted() {
            guard let item = state.latest[key],
                item.record.generation == manifest.generation
            else { throw AkashicError.invalidManifest }
            prefix.append(try segmentedCheckpointMutation(key: key, item: item))
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
        let name = "compound-g\(manifest.generation)-\(UUID().uuidString.lowercased()).cseg"
        let draft = try SegmentedManifestCompoundRunV1.writeDraft(
            prefix: prefix,
            fileName: name,
            directory: segmentDirectory
        )
        segmentedManifestCompoundPresealCandidate = .init(
            generation: manifest.generation,
            sourceSequence: state.activeHead.s,
            sourceDistinctKeyCount: state.latest.count,
            sourceHeadRoot: state.activeHead.r,
            draft: draft
        )
        return .init(
            generation: manifest.generation,
            sourceSequence: state.activeHead.s,
            sourceDistinctKeyCount: state.latest.count,
            candidateFileName: draft.fileName,
            prefixByteCount: draft.prefixByteCount
        )
    }

    func checkpointSegmentedManifestUsingCompoundPresealIfBeneficial(
        currentRoot: SegmentedManifestRootV1,
        previousDirectoryState: DirectoryHeadRecoveredState,
        transition: ManifestOwnershipTransition,
        normalMutationCount: Int
    ) throws -> Manifest? {
        guard let candidate = segmentedManifestCompoundPresealCandidate else { return nil }
        guard candidate.generation == manifest.generation,
            currentRoot.generation == manifest.generation,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.runs.count < SegmentedManifestPrototypeV1.maximumRunDescriptors,
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            previousDirectoryState.activeHead.g == candidate.generation,
            previousDirectoryState.activeHead.s >= candidate.sourceSequence,
            candidate.sourceDistinctKeyCount == candidate.draft.prefixRecordCount,
            candidate.sourceDistinctKeyCount > 0,
            candidate.sourceDistinctKeyCount <= SegmentedManifestCompoundRunV1.maximumPrefixRecords
        else {
            segmentedManifestCompoundPresealCandidate = nil
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
        guard !tailByKey.isEmpty,
            tailByKey.count <= SegmentedManifestCompoundRunV1.maximumAdoptedTailRecords,
            tailByKey.count < normalMutationCount
        else {
            segmentedManifestCompoundPresealCandidate = nil
            return nil
        }

        let tail = tailByKey.values.sorted { $0.key < $1.key }
        let tailByteCount = SegmentedManifestPrototypeV1.headerBytes
            + tail.count * SegmentedManifestPrototypeV1.runRecordBytes
        let finalByteCount = candidate.draft.prefixByteCount
            + tailByteCount
            + SegmentedManifestCompoundRunV1.footerBytes
        let referencedBytes = currentRoot.base.byteCount
            + currentRoot.runs.reduce(0) { $0 + $1.byteCount }
        guard finalByteCount <= SegmentedManifestCompoundRunV1.maximumBytes,
            referencedBytes
                <= SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes - finalByteCount
        else {
            segmentedManifestCompoundPresealCandidate = nil
            return nil
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
            preserving: Set([candidate.draft.fileName])
        )

        let descriptor: SegmentedManifestDescriptorV1
        do {
            descriptor = try SegmentedManifestCompoundRunV1.finalizeDraft(
                candidate.draft,
                tail: tail,
                directory: segmentDirectory,
                faultInjector: segmentedManifestCompoundFinalizeFaultInjector
            )
        } catch {
            segmentedManifestCompoundPresealCandidate = nil
            throw error
        }
        guard descriptor.recordCount == normalMutationCount else {
            segmentedManifestCompoundPresealCandidate = nil
            throw AkashicError.invalidManifest
        }

        let nextGeneration = currentRoot.generation + 1
        let nextRoot = try SegmentedManifestPrototypeV1.makeRootV4(
            generation: nextGeneration,
            base: currentRoot.base,
            runs: currentRoot.runs + [descriptor]
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
}
