import AkashicCore
import Foundation

package struct FileBlobStoreSegmentedRunCollapseResult: Sendable {
    package let inputRunCount: Int
    package let outputRunCount: Int
    package let touchedKeyCount: Int
    package let finalUpsertCount: Int
    package let inputRunBytes: Int
    package let outputRunBytes: Int
}

extension FileBlobStore {
    /// Explicit package-only V3 run-collapse candidate.
    ///
    /// This primitive is intentionally synchronous and actor-isolated for its first qualification:
    /// it scans only the bounded run set, not the live base, and does not suspend while those
    /// descriptors are its proof input. Automatic scheduling and detached preparation remain a
    /// separate resource-design problem.
    @discardableResult
    package func resourceProbeCollapseSegmentedRunsV3()
        throws -> FileBlobStoreSegmentedRunCollapseResult?
    {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let frozenRoot = segmentedManifestRoot,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            frozenRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        guard segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty
        else { throw AkashicError.transactionConflict }

        return try collapseSegmentedRunsV3(
            frozenRoot: frozenRoot,
            preserving: [],
            unmaterializedReservationCount: 0
        )?.result
    }

    @discardableResult
    package func resourceProbeCollapseSegmentedRunsV4()
        throws -> FileBlobStoreSegmentedRunCollapseResult?
    {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let frozenRoot = segmentedManifestRoot,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            frozenRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        guard segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            segmentedManifestCompoundPresealCandidate == nil,
            segmentedManifestRunPrefixCollapseCandidate == nil
        else { throw AkashicError.transactionConflict }

        return try collapseSegmentedRunsV3(
            frozenRoot: frozenRoot,
            preserving: [],
            unmaterializedReservationCount: 0
        )?.result
    }

    /// Hard-cap bounded-history rescue. A detached full-base compactor may be arbitrarily delayed,
    /// so this path preserves its source-read lease and candidate-name reservation instead of waiting for
    /// it. If the bounded run history cannot be encoded into fewer descriptors, the caller falls
    /// back to the already-qualified synchronous full-base compaction path.
    func collapseSegmentedRunsV3SynchronouslyAtRunCapacity(
        frozenRoot: SegmentedManifestRootV1
    ) throws -> SegmentedManifestRootV1? {
        let v3 = segmentedManifestRunCapacityPolicy
                == .synchronousV3RunCollapseThenCompactionAtHardLimit
            && frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3
        let v4 = segmentedManifestRunCapacityPolicy.usesV4HardCapacityBackstop
            && frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4
        guard (v3 || v4),
            frozenRoot.base.kind == .baseBinaryV2,
            frozenRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors,
            segmentedManifestRoot == frozenRoot
        else { throw AkashicError.limitExceeded }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let preserving = segmentedManifestCompactionPreservedNames()
        let reservation = segmentedManifestUnmaterializedReservationCount(in: segmentDirectory)
        return try collapseSegmentedRunsV3(
            frozenRoot: frozenRoot,
            preserving: preserving,
            unmaterializedReservationCount: reservation
        )?.root
    }

    private func collapseSegmentedRunsV3(
        frozenRoot: SegmentedManifestRootV1,
        preserving preservedNames: Set<String>,
        unmaterializedReservationCount: Int
    ) throws -> (
        root: SegmentedManifestRootV1,
        result: FileBlobStoreSegmentedRunCollapseResult
    )? {
        guard segmentedManifestRoot == frozenRoot else {
            throw AkashicError.transactionConflict
        }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: frozenRoot,
            directory: segmentDirectory,
            preserving: preservedNames
        )
        guard let plan = try SegmentedManifestRunCollapseV1.plan(
            frozenRoot: frozenRoot,
            segmentDirectory: segmentDirectory
        ) else { return nil }

        // Old root + all replacement runs coexist until the single root switch. Physical cleanup
        // debt can consume part of the nominal second-topology budget even when the logical plan is
        // valid. Treat that *pre-write* headroom shortage as "this collapse strategy is unavailable"
        // rather than a terminal hard-cap failure, so the caller may try the one-file full-base
        // compaction fallback. Filesystem/authority failures after materialization starts still throw.
        let requiredMaterializationEntries = plan.outputRunCount
            + unmaterializedReservationCount
        let availableMaterializationEntries = try SegmentedManifestSegmentCleanupV1
            .availableMaterializationEntries(directory: segmentDirectory)
        guard availableMaterializationEntries >= requiredMaterializationEntries else {
            return nil
        }

        var replacementDescriptors: [SegmentedManifestDescriptorV1] = []
        replacementDescriptors.reserveCapacity(plan.outputRunCount)
        do {
            for mutations in plan.replacementMutationRuns {
                let name = "run-g\(frozenRoot.generation)-\(UUID().uuidString.lowercased()).seg"
                replacementDescriptors.append(
                    try SegmentedManifestPrototypeV1.writeRun(
                        mutations,
                        fileName: name,
                        directory: segmentDirectory
                    )
                )
            }
        } catch {
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: frozenRoot,
                    directory: segmentDirectory,
                    preserving: preservedNames
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
            }
            throw error
        }

        let nextRoot: SegmentedManifestRootV1
        do {
            nextRoot = try SegmentedManifestPrototypeV1.makeRootPreservingProfile(
                of: frozenRoot,
                generation: frozenRoot.generation,
                base: frozenRoot.base,
                runs: replacementDescriptors
            )
        } catch {
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: frozenRoot,
                    directory: segmentDirectory,
                    preserving: preservedNames
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
            }
            throw error
        }

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
            // Root rename visibility can be ambiguous. Do not guess which topology owns cleanup;
            // bootstrap must converge old-root or replacement-root authority first.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        // Topology only: logical manifest, PhysicalBlobID ownership, live-byte accounting and
        // directory-head generation are unchanged by the root switch.
        segmentedManifestRoot = nextRoot
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: nextRoot,
                directory: segmentDirectory,
                preserving: preservedNames
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        return (
            root: nextRoot,
            result: FileBlobStoreSegmentedRunCollapseResult(
                inputRunCount: plan.inputRunCount,
                outputRunCount: plan.outputRunCount,
                touchedKeyCount: plan.touchedKeyCount,
                finalUpsertCount: plan.finalUpsertCount,
                inputRunBytes: plan.inputRunBytes,
                outputRunBytes: plan.outputRunBytes
            )
        )
    }
}
