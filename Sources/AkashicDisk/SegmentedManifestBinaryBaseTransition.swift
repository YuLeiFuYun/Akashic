import AkashicCore
import Foundation

package struct SegmentedManifestBinaryBaseTransitionCandidateV2: Sendable {
    package let frozenRoot: SegmentedManifestRootV1
    package let root: SegmentedManifestRootV1
    package let base: SegmentedManifestDescriptorV1
    package let semanticCommitment: String
}

package enum SegmentedManifestBinaryBaseTransitionV2 {
    /// Prepare, but do not publish, a V2 binary-base root for one exact V1 frozen topology.
    ///
    /// The durable binary base remains physical debt until the caller separately publishes `root`.
    /// The transition intentionally keeps the segmented generation unchanged because representation
    /// topology is not logical authority.
    package static func prepare(
        frozenRoot: SegmentedManifestRootV1,
        segmentDirectory: URL,
        candidateFileName: String
    ) throws -> SegmentedManifestBinaryBaseTransitionCandidateV2 {
        guard frozenRoot.profile == SegmentedManifestPrototypeV1.profileV1,
            frozenRoot.base.kind == .baseJSON,
            SegmentedManifestSegmentCleanupV1.isProductionCanonical(candidateFileName),
            candidateFileName.hasPrefix("base-binary-"),
            SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
                candidateFileName,
                kind: .baseBinaryV1
            )
        else { throw AkashicError.invalidManifest }

        let frozenState = try SegmentedManifestPrototypeV1.recover(
            root: frozenRoot,
            segmentDirectory: segmentDirectory
        )
        let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(frozenState)
        let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
            frozenState,
            fileName: candidateFileName,
            directory: segmentDirectory
        )
        let verified = try SegmentedManifestPrototypeV1.readBase(
            base,
            directory: segmentDirectory
        )
        guard verified == frozenState,
            try SegmentedManifestPrototypeV1.semanticStateCommitment(verified) == commitment
        else { throw AkashicError.invalidManifest }

        let root = try SegmentedManifestPrototypeV1.makeRootV2(
            generation: frozenRoot.generation,
            base: base,
            runs: []
        )
        guard root.generation == frozenRoot.generation,
            root.profile == SegmentedManifestPrototypeV1.profileV2,
            root.base == base,
            root.runs.isEmpty
        else { throw AkashicError.invalidManifest }

        return SegmentedManifestBinaryBaseTransitionCandidateV2(
            frozenRoot: frozenRoot,
            root: root,
            base: base,
            semanticCommitment: commitment
        )
    }
}

package struct SegmentedManifestBinaryBaseCompactionCandidateV2: Sendable {
    package let frozenRoot: SegmentedManifestRootV1
    package let base: SegmentedManifestDescriptorV1
    package let semanticCommitment: String
}

package enum SegmentedManifestBinaryBaseCompactionV2 {
    /// Prepare a compacted immutable binary base for one exact frozen V2 root.
    ///
    /// The caller must still prove that the current root extends `frozenRoot` by a suffix before
    /// publishing a replacement V2 root. Candidate bytes are physical debt until that publication.
    package static func prepare(
        frozenRoot: SegmentedManifestRootV1,
        segmentDirectory: URL,
        candidateFileName: String
    ) throws -> SegmentedManifestBinaryBaseCompactionCandidateV2 {
        guard frozenRoot.profile == SegmentedManifestPrototypeV1.profileV2,
            frozenRoot.base.kind == .baseBinaryV1,
            SegmentedManifestSegmentCleanupV1.isProductionCanonical(candidateFileName),
            candidateFileName.hasPrefix("base-binary-"),
            SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
                candidateFileName,
                kind: .baseBinaryV1
            )
        else { throw AkashicError.invalidManifest }

        let frozenState = try SegmentedManifestPrototypeV1.recover(
            root: frozenRoot,
            segmentDirectory: segmentDirectory
        )
        let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(frozenState)
        let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
            frozenState,
            fileName: candidateFileName,
            directory: segmentDirectory
        )
        let verifiedState = try SegmentedManifestPrototypeV1.readBase(
            base,
            directory: segmentDirectory
        )
        guard verifiedState == frozenState,
            try SegmentedManifestPrototypeV1.semanticStateCommitment(verifiedState) == commitment
        else { throw AkashicError.invalidManifest }
        return SegmentedManifestBinaryBaseCompactionCandidateV2(
            frozenRoot: frozenRoot,
            base: base,
            semanticCommitment: commitment
        )
    }
}
