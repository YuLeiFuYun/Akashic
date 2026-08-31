import AkashicCore
import Foundation

package struct SegmentedManifestCompactionCandidateV1: Sendable {
    package let frozenRoot: SegmentedManifestRootV1
    package let base: SegmentedManifestDescriptorV1
    package let semanticCommitment: String
}

package enum SegmentedManifestCompactionV1 {
    /// Build and independently verify a compacted base for exactly `frozenRoot`.
    ///
    /// The returned value is only a process-local verified candidate. It is not logical authority
    /// until an actor later proves prefix extension and publishes a new root referencing `base`.
    package static func prepare(
        frozenRoot: SegmentedManifestRootV1,
        segmentDirectory: URL,
        candidateFileName: String
    ) throws -> SegmentedManifestCompactionCandidateV1 {
        guard SegmentedManifestSegmentCleanupV1.isProductionCanonical(candidateFileName),
            candidateFileName.hasPrefix("base-compaction-")
        else { throw AkashicError.invalidManifest }

        let frozenState = try SegmentedManifestPrototypeV1.recover(
            root: frozenRoot,
            segmentDirectory: segmentDirectory
        )
        let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(frozenState)
        let baseData = try SegmentedManifestPrototypeV1.encodeCompactionBaseSnapshot(
            generation: frozenRoot.generation,
            state: frozenState
        )
        let candidate = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: frozenState.count,
            fileName: candidateFileName,
            directory: segmentDirectory
        )

        // Verification happens after durable publication of the candidate inode. Akashic never
        // rewrites that pathname after this check. External/media mutation after verification is
        // detected by descriptor hash during recovery; bounded foreground publication does not
        // claim to prevent that TOCTOU class.
        let verifiedState = try SegmentedManifestPrototypeV1.readBase(
            candidate,
            directory: segmentDirectory
        )
        guard verifiedState == frozenState,
            try SegmentedManifestPrototypeV1.semanticStateCommitment(verifiedState) == commitment
        else { throw AkashicError.invalidManifest }
        return SegmentedManifestCompactionCandidateV1(
            frozenRoot: frozenRoot,
            base: candidate,
            semanticCommitment: commitment
        )
    }
}

extension SegmentedManifestPrototypeV1 {
    package static func encodeCompactionBaseSnapshot(
        generation: UInt64,
        state: [String: SegmentedManifestEntry]
    ) throws -> Data {
        guard generation > 0, state.count <= FileBlobStore.maximumManifestEntryCount else {
            throw AkashicError.invalidManifest
        }
        var entries: [String: FileBlobStore.Entry] = [:]
        entries.reserveCapacity(state.count)
        var physicalIDs = Set<PhysicalBlobID>()
        physicalIDs.reserveCapacity(state.count)
        for (key, entry) in state {
            try validate(entry)
            guard key == entry.key,
                physicalIDs.insert(entry.physicalID).inserted
            else { throw AkashicError.invalidManifest }
            entries[key] = FileBlobStore.Entry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
        let snapshot = FileBlobStore.Manifest(
            schemaVersion: FileBlobStore.directoryHeadManifestSchemaVersion,
            generation: generation,
            deltaCarrierProfile: .directoryHeadV2,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count > 0,
            data.count <= maximumBaseBytes,
            data.count <= maximumReferencedSegmentBytes
        else { throw AkashicError.limitExceeded }
        return data
    }
}
