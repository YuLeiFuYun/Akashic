import AkashicCore
import Foundation

extension FileBlobStore {
    package func resourceProbeCompactSegmentedManifestV1(
        observer: FileBlobStoreSegmentedCompactionObserver? = nil,
        preparationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? = nil
    ) async throws -> Bool {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let frozenRoot = segmentedManifestRoot,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV1,
            frozenRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        guard !frozenRoot.runs.isEmpty else { return false }
        guard segmentedManifestCompactionCandidateName == nil else {
            throw AkashicError.transactionConflict
        }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: frozenRoot,
            directory: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory
        )

        let candidateName = "base-compaction-\(UUID().uuidString.lowercased()).json"
        segmentedManifestCompactionCandidateName = candidateName
        let task = Task.detached {
            if let preparationObserver { await preparationObserver() }
            return try SegmentedManifestCompactionV1.prepare(
                frozenRoot: frozenRoot,
                segmentDirectory: segmentDirectory,
                candidateFileName: candidateName
            )
        }

        let candidate: SegmentedManifestCompactionCandidateV1
        do {
            candidate = try await task.value
        } catch {
            segmentedManifestCompactionCandidateName = nil
            segmentedManifestBestEffortCandidateCleanup(
                currentRoot: segmentedManifestRoot,
                directory: segmentDirectory
            )
            throw error
        }

        if let observer { await observer(.candidateVerified) }
        guard !requiresReopenBeforeFurtherAccess,
            let currentRoot = segmentedManifestRoot,
            currentRoot.base == candidate.frozenRoot.base,
            currentRoot.runs.count >= candidate.frozenRoot.runs.count,
            Array(currentRoot.runs.prefix(candidate.frozenRoot.runs.count))
                == candidate.frozenRoot.runs
        else {
            segmentedManifestCompactionCandidateName = nil
            try segmentedManifestRepayCandidateOrPoison(
                currentRoot: segmentedManifestRoot,
                directory: segmentDirectory
            )
            return false
        }

        let suffix = Array(currentRoot.runs.dropFirst(candidate.frozenRoot.runs.count))
        let nextRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: currentRoot.generation,
            base: candidate.base,
            runs: suffix
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
            segmentedManifestCompactionCandidateName = nil
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        // Compaction is physical topology only. Logical manifest, ownership index, live bytes and
        // the current directory-head generation remain unchanged.
        segmentedManifestRoot = nextRoot
        segmentedManifestCompactionCandidateName = nil
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: nextRoot,
                directory: segmentDirectory
            )
        } catch {
            // Root publication already committed. Do not roll it back; force a fresh bootstrap to
            // re-establish the physical-debt boundary before any further stateful operation.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        return true
    }

    /// Explicit package-only V2 compaction candidate. This is deliberately separate from the V1
    /// JSON compactor so profile-specific physical representation cannot be selected implicitly.
    /// Automatic scheduling remains outside this primitive.
    @discardableResult
    package func resourceProbeCompactSegmentedManifestV2(
        observer: FileBlobStoreSegmentedCompactionObserver? = nil,
        preparationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? = nil
    ) async throws -> Bool {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let frozenRoot = segmentedManifestRoot,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV2,
            frozenRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        guard !frozenRoot.runs.isEmpty else { return false }
        guard segmentedManifestCompactionCandidateName == nil else {
            throw AkashicError.transactionConflict
        }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: frozenRoot,
            directory: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory
        )

        let candidateName = "base-binary-\(UUID().uuidString.lowercased()).akb"
        segmentedManifestCompactionCandidateName = candidateName
        let task = Task.detached {
            if let preparationObserver { await preparationObserver() }
            return try SegmentedManifestBinaryBaseCompactionV2.prepare(
                frozenRoot: frozenRoot,
                segmentDirectory: segmentDirectory,
                candidateFileName: candidateName
            )
        }

        let candidate: SegmentedManifestBinaryBaseCompactionCandidateV2
        do {
            candidate = try await task.value
        } catch {
            segmentedManifestCompactionCandidateName = nil
            segmentedManifestBestEffortCandidateCleanup(
                currentRoot: segmentedManifestRoot,
                directory: segmentDirectory
            )
            throw error
        }

        if let observer { await observer(.candidateVerified) }
        guard !requiresReopenBeforeFurtherAccess,
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV2,
            currentRoot.base == candidate.frozenRoot.base,
            currentRoot.runs.count >= candidate.frozenRoot.runs.count,
            Array(currentRoot.runs.prefix(candidate.frozenRoot.runs.count))
                == candidate.frozenRoot.runs
        else {
            segmentedManifestCompactionCandidateName = nil
            try segmentedManifestRepayCandidateOrPoison(
                currentRoot: segmentedManifestRoot,
                directory: segmentDirectory
            )
            return false
        }

        let suffix = Array(currentRoot.runs.dropFirst(candidate.frozenRoot.runs.count))
        let nextRoot = try SegmentedManifestPrototypeV1.makeRootV2(
            generation: currentRoot.generation,
            base: candidate.base,
            runs: suffix
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
            segmentedManifestCompactionCandidateName = nil
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        // As with V1, compaction changes physical topology only. It must not mutate logical
        // manifest state, ownership index, live-byte accounting or directory-head generation.
        segmentedManifestRoot = nextRoot
        segmentedManifestCompactionCandidateName = nil
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: nextRoot,
                directory: segmentDirectory
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        return true
    }

    /// Explicit package-only V3 compaction candidate using the 92-byte binary-base V2 wire.
    /// Automatic scheduling remains outside this primitive.
    @discardableResult
    package func resourceProbeCompactSegmentedManifestV3(
        observer: FileBlobStoreSegmentedCompactionObserver? = nil,
        preparationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? = nil
    ) async throws -> Bool {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let frozenRoot = segmentedManifestRoot,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            frozenRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        guard !frozenRoot.runs.isEmpty else { return false }
        guard segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestRunPrefixCollapseCandidate == nil
        else {
            throw AkashicError.transactionConflict
        }

        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: frozenRoot,
            directory: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory
        )

        let candidateName = "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        segmentedManifestCompactionCandidateName = candidateName
        segmentedManifestCompactionReadLeaseNames = Set(
            [frozenRoot.base.fileName] + frozenRoot.runs.map(\.fileName)
        )
        let task = Task.detached {
            if let preparationObserver { await preparationObserver() }
            return try SegmentedManifestBinaryBaseCompactionV3.prepare(
                frozenRoot: frozenRoot,
                segmentDirectory: segmentDirectory,
                candidateFileName: candidateName
            )
        }

        let candidate: SegmentedManifestBinaryBaseCompactionCandidateV3
        do {
            candidate = try await task.value
        } catch {
            segmentedManifestCompactionCandidateName = nil
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            segmentedManifestBestEffortCandidateCleanup(
                currentRoot: segmentedManifestRoot,
                directory: segmentDirectory
            )
            throw error
        }

        // Another actor operation may have crossed an ambiguous root-publication boundary while
        // detached preparation was in flight. In that state actor topology is no longer cleanup
        // authority; leave the candidate for fresh bootstrap instead of reclaiming against stale
        // `segmentedManifestRoot`.
        if requiresReopenBeforeFurtherAccess {
            if segmentedManifestCompactionCandidateName == candidateName {
                segmentedManifestCompactionCandidateName = nil
            }
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            return false
        }

        if let observer { await observer(.candidateVerified) }
        if requiresReopenBeforeFurtherAccess {
            if segmentedManifestCompactionCandidateName == candidateName {
                segmentedManifestCompactionCandidateName = nil
            }
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            return false
        }
        guard !requiresReopenBeforeFurtherAccess,
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            currentRoot.base == candidate.frozenRoot.base,
            currentRoot.runs.count >= candidate.frozenRoot.runs.count,
            Array(currentRoot.runs.prefix(candidate.frozenRoot.runs.count))
                == candidate.frozenRoot.runs
        else {
            segmentedManifestCompactionCandidateName = nil
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            try segmentedManifestRepayCandidateOrPoison(
                currentRoot: segmentedManifestRoot,
                directory: segmentDirectory
            )
            return false
        }

        let suffix = Array(currentRoot.runs.dropFirst(candidate.frozenRoot.runs.count))
        let nextRoot = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: currentRoot.generation,
            base: candidate.base,
            runs: suffix
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
            segmentedManifestCompactionCandidateName = nil
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        segmentedManifestRoot = nextRoot
        segmentedManifestCompactionCandidateName = nil
        segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: nextRoot,
                directory: segmentDirectory
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        return true
    }

    private func segmentedManifestRepayCandidateOrPoison(
        currentRoot: SegmentedManifestRootV1?,
        directory: URL
    ) throws {
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: currentRoot,
                directory: directory
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
    }

    private func segmentedManifestBestEffortCandidateCleanup(
        currentRoot: SegmentedManifestRootV1?,
        directory: URL
    ) {
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: currentRoot,
                directory: directory
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
        }
    }
}
