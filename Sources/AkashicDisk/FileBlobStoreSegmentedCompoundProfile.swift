import AkashicCore
import Foundation

extension FileBlobStore {
    /// Explicit package-only capability transition from the V3 binary-base profile to the V4
    /// compound-run profile. Logical authority, generation, directory-head state, base bytes, and
    /// existing run descriptors remain unchanged; only the root profile capability changes.
    /// Older V1/V2/V3 qualification opens therefore fail closed after this switch.
    @discardableResult
    package func resourceProbeMigrateSegmentedV3ToCompoundV4()
        throws -> SegmentedManifestRootV1
    {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            currentRoot.base.kind == .baseBinaryV2,
            currentRoot.generation == manifest.generation,
            currentRoot.runs.allSatisfy({ $0.kind == .runV1 }),
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            segmentedManifestCheckpointPresealCandidate == nil,
            segmentedManifestCompoundPresealCandidate == nil,
            segmentedManifestRunPrefixCollapseCandidate == nil
        else { throw AkashicError.transactionConflict }

        let next = try SegmentedManifestPrototypeV1.makeRootV4(
            generation: currentRoot.generation,
            base: currentRoot.base,
            runs: currentRoot.runs
        )
        try SegmentedManifestPrototypeV1.writeRoot(next, to: manifestURL)
        segmentedManifestRoot = next
        return next
    }
}
