import AkashicCore
import Foundation

package struct FileBlobStoreSegmentedRunPrefixCollapseResult: Sendable {
    package let sourcePrefixRunCount: Int
    package let replacementRunCount: Int
    package let suffixRunCount: Int
    package let finalRunCount: Int
    package let touchedKeyCount: Int
    package let finalUpsertCount: Int
    package let inputRunBytes: Int
    package let outputRunBytes: Int
}

package struct FileBlobStoreSegmentedRunPrefixBackgroundSnapshot: Sendable {
    package let sourceReadLeaseCount: Int
    package let materializationReservedNameCount: Int
    package let materializedReservedNameCount: Int
    package let planningTaskActive: Bool
    package let materializationTaskActive: Bool
}

package enum FileBlobStoreSegmentedRunPrefixPreparationRejection: Sendable, Equatable {
    case plannerNoCandidate
    case frozenDescriptorFloor(nextEligibleRunCount: Int)
    case frozenByteExpansion
    case suffixRecurrenceBeforeMaterialization(observedSuffixRunCount: Int)
    case suffixRecurrenceAfterMaterialization(observedSuffixRunCount: Int)
    case staleOrCancelled
}

package typealias FileBlobStoreSegmentedRunPrefixPreparationRejectionObserver =
    @Sendable (FileBlobStoreSegmentedRunPrefixPreparationRejection) async -> Void

package typealias FileBlobStoreSegmentedRunPrefixMaterializationProgressObserver =
    @Sendable (_ completedRunCount: Int, _ totalRunCount: Int) async -> Void

package enum FileBlobStoreSegmentedRunPrefixPreparationAdmission: Sendable {
    /// Generic/manual preparation and hard-cap correctness work accept every strict descriptor
    /// reduction. Even one recovered slot can be sufficient to preserve foreground progress.
    case anyStrictReduction

    /// Speculative automatic work must amortize its own replacement topology *and* must not expand
    /// the bounded run-history bytes it rewrites. Descriptor headroom and write bytes are separate
    /// resources: a replay-safe two-phase collapse can reduce 48 descriptors to a handful while
    /// still duplicating sparse upserts into release+upsert records and increasing logical bytes.
    /// Hard-cap/manual work deliberately does not use this stricter gate because bounded byte
    /// expansion can still be preferable to an O(live) base rewrite when progress is at risk.
    case speculativeAutomatic

    package func accepts(
        inputRunCount: Int,
        outputRunCount: Int,
        inputRunBytes: Int,
        outputRunBytes: Int
    ) -> Bool {
        guard inputRunCount > 0,
            outputRunCount >= 0,
            outputRunCount < inputRunCount,
            inputRunBytes >= 0,
            outputRunBytes >= 0
        else { return false }
        switch self {
        case .anyStrictReduction:
            return true
        case .speculativeAutomatic:
            return outputRunCount <= inputRunCount - outputRunCount
                && outputRunBytes <= inputRunBytes
        }
    }

    package func frozenRejection(
        inputRunCount: Int,
        outputRunCount: Int,
        inputRunBytes: Int,
        outputRunBytes: Int
    ) -> FileBlobStoreSegmentedRunPrefixPreparationRejection? {
        guard inputRunCount > 0,
            outputRunCount >= 0,
            outputRunCount < inputRunCount,
            inputRunBytes >= 0,
            outputRunBytes >= 0
        else { return .plannerNoCandidate }
        switch self {
        case .anyStrictReduction:
            return nil
        case .speculativeAutomatic:
            // Byte expansion has no count-only retry theorem. Classify it before descriptor
            // geometry so a plan that fails both cannot receive a false retry hint.
            guard outputRunBytes <= inputRunBytes else { return .frozenByteExpansion }
            let recovered = inputRunCount - outputRunCount
            guard outputRunCount <= recovered else {
                let doubled = outputRunCount.multipliedReportingOverflow(by: 2)
                return .frozenDescriptorFloor(
                    nextEligibleRunCount: doubled.overflow ? Int.max : doubled.partialValue
                )
            }
            return nil
        }
    }

    /// Re-evaluate speculative benefit against suffix work that arrived after the prefix froze.
    ///
    /// The frozen-plan floor alone is not enough: a 48 -> 24 plan is break-even at freeze time,
    /// but if 16 suffix runs arrive before adoption the resulting 40-run root reaches the exact
    /// trigger again after only eight checkpoints. That turns 24 replacement descriptors into an
    /// eight-checkpoint recurrence even though the original 48 -> 24 geometry looked acceptable.
    ///
    /// If adoption would remain below the exact trigger, require the replacement descriptor count
    /// to fit inside the *remaining recurrence distance*. If adoption is already at/above the
    /// trigger, exact-trigger scheduling will not immediately recur; the frozen strict-reduction,
    /// descriptor-amortization and byte-nonexpansion checks remain the applicable speculative floor.
    package func acceptsObservedSuffix(
        inputRunCount: Int,
        outputRunCount: Int,
        suffixRunCount: Int,
        inputRunBytes: Int,
        outputRunBytes: Int
    ) -> Bool {
        guard suffixRunCount >= 0,
            accepts(
                inputRunCount: inputRunCount,
                outputRunCount: outputRunCount,
                inputRunBytes: inputRunBytes,
                outputRunBytes: outputRunBytes
            )
        else { return false }
        switch self {
        case .anyStrictReduction:
            return true
        case .speculativeAutomatic:
            let adopted = outputRunCount.addingReportingOverflow(suffixRunCount)
            guard !adopted.overflow else { return false }
            guard adopted.partialValue < inputRunCount else { return true }
            let recurrenceDistance = inputRunCount - adopted.partialValue
            return outputRunCount <= recurrenceDistance
        }
    }
}

extension FileBlobStore {
    /// Prepare a topology-only replacement for an immutable authoritative V4 run prefix.
    ///
    /// Unlike active-epoch preseal, this candidate does not snapshot mutable directory-head state.
    /// Later checkpoints may append run descriptors to the current root while the exact frozen
    /// prefix remains valid. No logical authority changes until a later root publication adopts the
    /// replacement prefix.
    package func resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        -> FileBlobStoreSegmentedRunPrefixBackgroundSnapshot
    {
        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let materialized = segmentedManifestRunPrefixMaterializationNames.reduce(into: 0) {
            count, name in
            let url = segmentDirectory.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) { count += 1 }
        }
        return .init(
            sourceReadLeaseCount: segmentedManifestCompactionReadLeaseNames.count,
            materializationReservedNameCount: segmentedManifestRunPrefixMaterializationNames.count,
            materializedReservedNameCount: materialized,
            planningTaskActive: segmentedManifestRunPrefixPreparationTask != nil,
            materializationTaskActive: segmentedManifestRunPrefixMaterializationTask != nil
        )
    }

    package func resourceProbeAdoptSegmentedRunPrefixCollapseV4()
        throws -> FileBlobStoreSegmentedRunPrefixCollapseResult?
    {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            currentRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        return try adoptSegmentedRunPrefixCollapseV4IfCompatible(currentRoot: currentRoot)?.result
    }

    func adoptSegmentedRunPrefixCollapseV4IfCompatible(
        currentRoot: SegmentedManifestRootV1
    ) throws -> (
        root: SegmentedManifestRootV1,
        result: FileBlobStoreSegmentedRunPrefixCollapseResult
    )? {
        guard let candidate = segmentedManifestRunPrefixCollapseCandidate else { return nil }
        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )

        let prefixStillExact = currentRoot.profile == candidate.profile
            && currentRoot.profile == SegmentedManifestPrototypeV1.profileV4
            // Root generation advances on every immutable suffix checkpoint. That does not change
            // the meaning of an already-authoritative run prefix. Candidate identity is therefore
            // the exact base + exact ordered source-prefix descriptor vector; generation is only a
            // monotonic source timestamp and must not make a valid prefix candidate stale.
            && currentRoot.generation >= candidate.generation
            && currentRoot.base == candidate.base
            && currentRoot.runs.count >= candidate.sourcePrefixRuns.count
            && Array(currentRoot.runs.prefix(candidate.sourcePrefixRuns.count))
                == candidate.sourcePrefixRuns
        guard prefixStillExact else {
            segmentedManifestRunPrefixCollapseCandidate = nil
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: currentRoot,
                    directory: segmentDirectory,
                    preserving: segmentedManifestCompactionPreservedNames()
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            return nil
        }

        // Revalidate every prepared replacement from disk immediately before it can become
        // authoritative. Preparation may have happened many foreground operations earlier.
        for descriptor in candidate.replacementRuns {
            _ = try SegmentedManifestPrototypeV1.readRun(
                descriptor,
                directory: segmentDirectory
            )
        }

        let suffix = Array(currentRoot.runs.dropFirst(candidate.sourcePrefixRuns.count))
        let nextRuns = candidate.replacementRuns + suffix
        guard nextRuns.count < currentRoot.runs.count,
            nextRuns.count <= SegmentedManifestPrototypeV1.maximumRunDescriptors
        else {
            segmentedManifestRunPrefixCollapseCandidate = nil
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: currentRoot,
                directory: segmentDirectory,
                preserving: segmentedManifestCompactionPreservedNames()
            )
            return nil
        }

        let nextRoot = try SegmentedManifestPrototypeV1.makeRootPreservingProfile(
            of: currentRoot,
            generation: currentRoot.generation,
            base: currentRoot.base,
            runs: nextRuns
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
            // Root rename visibility may already have switched topology. Bootstrap must decide the
            // authoritative root before any actor-side cleanup is attempted.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        segmentedManifestRoot = nextRoot
        segmentedManifestRunPrefixCollapseCandidate = nil
        do {
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: nextRoot,
                directory: segmentDirectory,
                preserving: segmentedManifestCompactionPreservedNames()
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        return (
            nextRoot,
            FileBlobStoreSegmentedRunPrefixCollapseResult(
                sourcePrefixRunCount: candidate.sourcePrefixRuns.count,
                replacementRunCount: candidate.replacementRuns.count,
                suffixRunCount: suffix.count,
                finalRunCount: nextRuns.count,
                touchedKeyCount: candidate.touchedKeyCount,
                finalUpsertCount: candidate.finalUpsertCount,
                inputRunBytes: candidate.inputRunBytes,
                outputRunBytes: candidate.outputRunBytes
            )
        )
    }
}
