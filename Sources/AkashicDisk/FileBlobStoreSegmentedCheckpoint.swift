import AkashicCore
import Foundation

extension FileBlobStore {

    func checkpointSegmentedManifest(_ candidate: Manifest) throws -> Manifest {
        guard loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            candidate.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            candidate.deltaCarrierProfile == .directoryHeadV2,
            let currentRoot = segmentedManifestRoot,
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

        guard currentRoot.profile == SegmentedManifestPrototypeV1.profileV1,
            currentRoot.base.kind == .baseJSON,
            currentRoot.runs.count < SegmentedManifestPrototypeV1.maximumRunDescriptors
        else { throw AkashicError.limitExceeded }

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
            directory: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory
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
        return snapshot
    }
}
