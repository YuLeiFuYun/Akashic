import AkashicCore
import Foundation

package enum FileBlobStoreSegmentedCompactionPhase: Sendable {
    case candidateVerified
}

package typealias FileBlobStoreSegmentedCompactionObserver =
    @Sendable (FileBlobStoreSegmentedCompactionPhase) async -> Void
package typealias FileBlobStoreSegmentedCompactionPreparationObserver = @Sendable () async -> Void

package enum FileBlobStoreSegmentedRunCapacityPolicy: Sendable, Equatable {
    case rejectAtHardLimit
    case synchronousV3CompactionAtHardLimit
    case synchronousV3RunCollapseThenCompactionAtHardLimit
    case synchronousV4RunCollapseThenCompactionAtHardLimit
    /// Package-only research policy: after a V4 checkpoint reaches exactly `prefixRunCount`,
    /// prepare that immutable prefix in detached work and adopt it immediately if still compatible.
    /// The synchronous V4 run-collapse/full-compaction chain remains the hard-cap backstop.
    case backgroundV4StablePrefixAtRunCount(prefixRunCount: Int)

    var usesV4HardCapacityBackstop: Bool {
        switch self {
        case .synchronousV4RunCollapseThenCompactionAtHardLimit,
            .backgroundV4StablePrefixAtRunCount:
            true
        default:
            false
        }
    }

    var automaticV4StablePrefixRunCount: Int? {
        guard case let .backgroundV4StablePrefixAtRunCount(prefixRunCount) = self else {
            return nil
        }
        return prefixRunCount
    }
}

extension FileBlobStore {
    /// Hard-cap liveness chain for the package-only V3 candidate.
    ///
    /// Compressible run history is first reduced using bounded run-only work. Incompressible history
    /// retains the O(live) full-base compaction as the final progress backstop. The older explicit
    /// policy continues to select full-base compaction directly for control/evidence continuity.
    func relieveSegmentedManifestV3RunCapacitySynchronously(
        frozenRoot: SegmentedManifestRootV1
    ) throws -> SegmentedManifestRootV1 {
        switch segmentedManifestRunCapacityPolicy {
        case .rejectAtHardLimit:
            throw AkashicError.limitExceeded
        case .synchronousV3CompactionAtHardLimit:
            return try compactSegmentedManifestV3SynchronouslyAtRunCapacity(
                frozenRoot: frozenRoot
            )
        case .synchronousV3RunCollapseThenCompactionAtHardLimit:
            if let collapsed = try collapseSegmentedRunsV3SynchronouslyAtRunCapacity(
                frozenRoot: frozenRoot
            ) {
                return collapsed
            }
            return try compactSegmentedManifestV3SynchronouslyAtRunCapacity(
                frozenRoot: frozenRoot
            )
        case .synchronousV4RunCollapseThenCompactionAtHardLimit:
            throw AkashicError.limitExceeded
        case .backgroundV4StablePrefixAtRunCount:
            throw AkashicError.limitExceeded
        }
    }

    func relieveSegmentedManifestV4RunCapacitySynchronously(
        frozenRoot: SegmentedManifestRootV1
    ) throws -> SegmentedManifestRootV1 {
        guard segmentedManifestRunCapacityPolicy.usesV4HardCapacityBackstop,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4
        else { throw AkashicError.limitExceeded }
        // Hard-cap foreground progress supersedes speculative planning. Cancellation is
        // cooperative; source names remain read-leased until the detached task actually exits.
        recordAutomaticSegmentedRunPrefixHardCapCancellationIfNeeded()
        cancelSegmentedRunPrefixPreparationForHardCapacity()
        // A prepared immutable prefix is cheaper to adopt than rebuilding the same collapse at the
        // hard boundary. If foreground topology superseded that exact prefix, adoption repays the
        // stale physical candidate and returns nil, after which the established liveness chain
        // remains unchanged.
        if let prepared = try adoptSegmentedRunPrefixCollapseV4IfCompatible(
            currentRoot: frozenRoot
        ) {
            return prepared.root
        }
        if let collapsed = try collapseSegmentedRunsV3SynchronouslyAtRunCapacity(
            frozenRoot: frozenRoot
        ) {
            return collapsed
        }
        return try compactSegmentedManifestV3SynchronouslyAtRunCapacity(
            frozenRoot: frozenRoot
        )
    }

    /// Hard-cap liveness primitive for the package-only V3 candidate.
    ///
    /// Unlike the detached compactor below, this path intentionally performs O(live) preparation
    /// on the writer actor. It exists only as the correctness/liveness backstop when no run
    /// descriptor remains. A later background scheduler may reduce how often this path is reached,
    /// but it cannot replace the hard progress boundary because background completion time is not
    /// bounded by foreground mutation rate.
    func compactSegmentedManifestV3SynchronouslyAtRunCapacity(
        frozenRoot: SegmentedManifestRootV1
    ) throws -> SegmentedManifestRootV1 {
        let v3Policy = segmentedManifestRunCapacityPolicy == .synchronousV3CompactionAtHardLimit
            || segmentedManifestRunCapacityPolicy
                == .synchronousV3RunCollapseThenCompactionAtHardLimit
        let v4Policy = segmentedManifestRunCapacityPolicy.usesV4HardCapacityBackstop
        guard ((v3Policy && frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3)
                || (v4Policy && frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4)),
            frozenRoot.base.kind == .baseBinaryV2,
            frozenRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors,
            segmentedManifestRoot == frozenRoot
        else { throw AkashicError.limitExceeded }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        // A background V3 compaction may already own one candidate name while its detached
        // preparation is arbitrarily delayed. The hard progress path must not depend on that task
        // completing. Preserve its reserved candidate-name entry (or one unmaterialized reservation) and build a
        // second, foreground-owned candidate from the *current* 64-run root. The background task
        // will later observe that its frozen base/prefix was superseded and repay its own candidate.
        //
        // Keeping the synchronous candidate local is important: the single standing candidate name
        // continues to identify only the detached background task, so ordinary checkpoint cleanup
        // and headroom accounting can preserve it while this hard rescue publishes.
        let backgroundCandidateNames = segmentedManifestCompactionPreservedNames()
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: frozenRoot,
            directory: segmentDirectory,
            preserving: backgroundCandidateNames
        )
        let backgroundReservation = segmentedManifestUnmaterializedReservationCount(
            in: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: 1 + backgroundReservation
        )

        let candidateName = "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        let candidate: SegmentedManifestBinaryBaseCompactionCandidateV3
        do {
            candidate = try SegmentedManifestBinaryBaseCompactionV3.prepare(
                frozenRoot: frozenRoot,
                segmentDirectory: segmentDirectory,
                candidateFileName: candidateName
            )
        } catch {
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: segmentedManifestRoot,
                    directory: segmentDirectory,
                    preserving: backgroundCandidateNames
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
            }
            throw error
        }

        let compactedRoot = try SegmentedManifestPrototypeV1.makeRootPreservingProfile(
            of: frozenRoot,
            generation: frozenRoot.generation,
            base: candidate.base,
            runs: []
        )
        let injector = faultInjector
        do {
            try SegmentedManifestPrototypeV1.writeRoot(
                compactedRoot,
                to: manifestURL,
                faultInjector: { point in
                    try Self.forwardManifestFault(point, to: injector)
                }
            )
        } catch {
            // Rename visibility may already have crossed. Do not delete either the synchronous
            // candidate or an in-flight background candidate using stale actor topology; bootstrap
            // is the only safe cleanup authority after this point.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        segmentedManifestRoot = compactedRoot
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: compactedRoot,
                directory: segmentDirectory,
                preserving: backgroundCandidateNames
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        return compactedRoot
    }

    /// Explicit package-only compaction candidate. This performs O(live) reconstruction/encoding on
    /// a detached task and keeps actor-side publication bounded by the <=64 descriptor root.
    /// Automatic scheduling is intentionally separate from this primitive.
    @discardableResult
    func segmentedManifestCompactionPreservedNames() -> Set<String> {
        var names = segmentedManifestCompactionReadLeaseNames
        if let name = segmentedManifestCompactionCandidateName { names.insert(name) }
        if let name = segmentedManifestCompoundPresealCandidate?.draft.fileName {
            names.insert(name)
        }
        if let candidate = segmentedManifestRunPrefixCollapseCandidate {
            names.formUnion(candidate.replacementRuns.map(\.fileName))
        }
        names.formUnion(segmentedManifestRunPrefixMaterializationNames)
        return names
    }

    func segmentedManifestUnmaterializedReservationCount(in directory: URL) -> Int {
        var count = 0
        if let name = segmentedManifestCompactionCandidateName {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) { count += 1 }
        }
        for name in segmentedManifestRunPrefixMaterializationNames {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) { count += 1 }
        }
        return count
    }


}
