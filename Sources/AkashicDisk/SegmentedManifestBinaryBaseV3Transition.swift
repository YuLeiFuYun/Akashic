import AkashicCore
import Foundation

package struct SegmentedManifestBinaryBaseTransitionCandidateV3: Sendable {
    package let frozenRoot: SegmentedManifestRootV1
    package let root: SegmentedManifestRootV1
    package let base: SegmentedManifestDescriptorV1
    package let semanticCommitment: String
}

package enum SegmentedManifestBinaryBaseTransitionV3 {
    package static func prepare(
        frozenRoot: SegmentedManifestRootV1,
        segmentDirectory: URL,
        candidateFileName: String
    ) throws -> SegmentedManifestBinaryBaseTransitionCandidateV3 {
        let sourceAccepted =
            (frozenRoot.profile == SegmentedManifestPrototypeV1.profileV1
                && frozenRoot.base.kind == .baseJSON)
            || (frozenRoot.profile == SegmentedManifestPrototypeV1.profileV2
                && frozenRoot.base.kind == .baseBinaryV1)
        guard sourceAccepted,
            SegmentedManifestSegmentCleanupV1.isProductionCanonical(candidateFileName),
            candidateFileName.hasPrefix("base-binary-v2-"),
            SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
                candidateFileName,
                kind: .baseBinaryV2
            )
        else { throw AkashicError.invalidManifest }

        let frozenState = try SegmentedManifestPrototypeV1.recover(
            root: frozenRoot,
            segmentDirectory: segmentDirectory
        )
        let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(frozenState)
        let base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
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

        let root = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: frozenRoot.generation,
            base: base,
            runs: []
        )
        guard root.generation == frozenRoot.generation,
            root.profile == SegmentedManifestPrototypeV1.profileV3,
            root.base == base,
            root.runs.isEmpty
        else { throw AkashicError.invalidManifest }
        return SegmentedManifestBinaryBaseTransitionCandidateV3(
            frozenRoot: frozenRoot,
            root: root,
            base: base,
            semanticCommitment: commitment
        )
    }
}

package struct SegmentedManifestBinaryBaseCompactionCandidateV3: Sendable {
    package let frozenRoot: SegmentedManifestRootV1
    package let base: SegmentedManifestDescriptorV1
    package let semanticCommitment: String
}

package enum SegmentedManifestBinaryBaseCompactionV3 {
    package static func prepare(
        frozenRoot: SegmentedManifestRootV1,
        segmentDirectory: URL,
        candidateFileName: String
    ) throws -> SegmentedManifestBinaryBaseCompactionCandidateV3 {
        guard (frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3
                || frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4),
            frozenRoot.base.kind == .baseBinaryV2,
            SegmentedManifestSegmentCleanupV1.isProductionCanonical(candidateFileName),
            candidateFileName.hasPrefix("base-binary-v2-"),
            SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
                candidateFileName,
                kind: .baseBinaryV2
            )
        else { throw AkashicError.invalidManifest }

        let frozenState = try SegmentedManifestPrototypeV1.recover(
            root: frozenRoot,
            segmentDirectory: segmentDirectory
        )
        let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(frozenState)
        let base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
            frozenState,
            fileName: candidateFileName,
            directory: segmentDirectory
        )
        let verified = try SegmentedManifestPrototypeV1.readBase(base, directory: segmentDirectory)
        guard verified == frozenState,
            try SegmentedManifestPrototypeV1.semanticStateCommitment(verified) == commitment
        else { throw AkashicError.invalidManifest }
        return SegmentedManifestBinaryBaseCompactionCandidateV3(
            frozenRoot: frozenRoot,
            base: base,
            semanticCommitment: commitment
        )
    }
}
