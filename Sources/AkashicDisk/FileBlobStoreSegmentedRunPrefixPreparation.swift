import AkashicCore
import Foundation

extension FileBlobStore {
    package func resourceProbePrepareSegmentedRunPrefixCollapseV4(
        prefixRunCount: Int,
        admission: FileBlobStoreSegmentedRunPrefixPreparationAdmission = .anyStrictReduction,
        preparationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? = nil,
        materializationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? = nil,
        materializationProgressObserver:
            FileBlobStoreSegmentedRunPrefixMaterializationProgressObserver? = nil,
        rejectionObserver: FileBlobStoreSegmentedRunPrefixPreparationRejectionObserver? = nil
    ) async throws -> FileBlobStoreSegmentedRunPrefixCollapseResult? {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let frozenRoot = segmentedManifestRoot,
            frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            frozenRoot.base.kind == .baseBinaryV2,
            frozenRoot.generation == manifest.generation
        else { throw AkashicError.unsupportedSchema }
        guard prefixRunCount > 1,
            prefixRunCount <= frozenRoot.runs.count,
            segmentedManifestCompactionCandidateName == nil,
            segmentedManifestCompactionReadLeaseNames.isEmpty,
            segmentedManifestCheckpointPresealCandidate == nil,
            segmentedManifestCompoundPresealCandidate == nil,
            segmentedManifestRunPrefixCollapseCandidate == nil,
            segmentedManifestRunPrefixPreparationTask == nil,
            segmentedManifestRunPrefixMaterializationNames.isEmpty,
            segmentedManifestRunPrefixMaterializationTask == nil
        else { throw AkashicError.transactionConflict }

        let sourcePrefixRuns = Array(frozenRoot.runs.prefix(prefixRunCount))
        let prefixRoot = try SegmentedManifestPrototypeV1.makeRootPreservingProfile(
            of: frozenRoot,
            generation: frozenRoot.generation,
            base: frozenRoot.base,
            runs: sourcePrefixRuns
        )
        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: frozenRoot,
            directory: segmentDirectory,
            preserving: segmentedManifestCompactionPreservedNames()
        )

        // The expensive bounded run replay is detached. While it is in flight the actor may keep
        // publishing immutable suffix runs. A read lease protects the frozen prefix if a hard-cap
        // rescue supersedes that root before preparation resumes; the rescue path already preserves
        // these names and never waits for detached work to finish.
        segmentedManifestCompactionReadLeaseNames = Set(sourcePrefixRuns.map(\.fileName))
        let preparationToken = UUID()
        let task = Task.detached {
            if let preparationObserver { await preparationObserver() }
            try Task.checkCancellation()
            return try SegmentedManifestRunCollapseV1.plan(
                frozenRoot: prefixRoot,
                segmentDirectory: segmentDirectory,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        segmentedManifestRunPrefixPreparationTask = task
        segmentedManifestRunPrefixPreparationToken = preparationToken
        let plan: SegmentedManifestRunCollapsePlanV1?
        do {
            plan = try await task.value
            clearSegmentedRunPrefixPreparationTask(token: preparationToken)
        } catch is CancellationError {
            clearSegmentedRunPrefixPreparationTask(token: preparationToken)
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            if !requiresReopenBeforeFurtherAccess {
                do {
                    _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                        root: segmentedManifestRoot,
                        directory: segmentDirectory,
                        preserving: segmentedManifestCompactionPreservedNames()
                    )
                } catch {
                    requiresReopenBeforeFurtherAccess = true
                    throw error
                }
            }
            if let rejectionObserver { await rejectionObserver(.staleOrCancelled) }
            return nil
        } catch {
            clearSegmentedRunPrefixPreparationTask(token: preparationToken)
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            if !requiresReopenBeforeFurtherAccess {
                do {
                    _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                        root: segmentedManifestRoot,
                        directory: segmentDirectory,
                        preserving: segmentedManifestCompactionPreservedNames()
                    )
                } catch {
                    requiresReopenBeforeFurtherAccess = true
                }
            }
            throw error
        }
        guard let plan else {
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            // The detached planner can legitimately conclude that this prefix is not collapsible.
            // While it was suspended, foreground hard-cap rescue may already have replaced the
            // frozen topology while preserving these source names solely for the read lease. Once
            // the lease is released, repay that now-unreferenced physical debt immediately rather
            // than leaving it stranded until some unrelated maintenance pass.
            if !requiresReopenBeforeFurtherAccess {
                do {
                    _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                        root: segmentedManifestRoot,
                        directory: segmentDirectory,
                        preserving: segmentedManifestCompactionPreservedNames()
                    )
                } catch {
                    requiresReopenBeforeFurtherAccess = true
                    throw error
                }
            }
            if let rejectionObserver { await rejectionObserver(.plannerNoCandidate) }
            return nil
        }

        // Writer poison/authority ambiguity dominates speculative resource policy. A rejected
        // optimization must never become the reason a reopen-required instance appears healthy.
        if requiresReopenBeforeFurtherAccess {
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            if let rejectionObserver { await rejectionObserver(.staleOrCancelled) }
            return nil
        }

        if let rejection = admission.frozenRejection(
            inputRunCount: plan.inputRunCount,
            outputRunCount: plan.outputRunCount,
            inputRunBytes: plan.inputRunBytes,
            outputRunBytes: plan.outputRunBytes
        ) {
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            // Policy rejection happens before any output-name reservation or materialization.
            // Repay any now-unreferenced source topology that was held only by the read lease, but
            // leave the authoritative root untouched. Hard-cap/manual callers retain the default
            // any-strict-reduction behavior and therefore never depend on this speculative floor.
            if !requiresReopenBeforeFurtherAccess {
                do {
                    _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                        root: segmentedManifestRoot,
                        directory: segmentDirectory,
                        preserving: segmentedManifestCompactionPreservedNames()
                    )
                } catch {
                    requiresReopenBeforeFurtherAccess = true
                    throw error
                }
            }
            if let rejectionObserver { await rejectionObserver(rejection) }
            return nil
        }
        guard let currentRoot = segmentedManifestRoot,
            currentRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            currentRoot.base == frozenRoot.base,
            currentRoot.generation >= frozenRoot.generation,
            currentRoot.runs.count >= sourcePrefixRuns.count,
            Array(currentRoot.runs.prefix(sourcePrefixRuns.count)) == sourcePrefixRuns
        else {
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: segmentedManifestRoot,
                    directory: segmentDirectory,
                    preserving: segmentedManifestCompactionPreservedNames()
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            if let rejectionObserver { await rejectionObserver(.staleOrCancelled) }
            return nil
        }

        let observedSuffixRunCount = currentRoot.runs.count - sourcePrefixRuns.count
        guard admission.acceptsObservedSuffix(
            inputRunCount: plan.inputRunCount,
            outputRunCount: plan.outputRunCount,
            suffixRunCount: observedSuffixRunCount,
            inputRunBytes: plan.inputRunBytes,
            outputRunBytes: plan.outputRunBytes
        ) else {
            segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
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
            if let rejectionObserver {
                await rejectionObserver(
                    .suffixRecurrenceBeforeMaterialization(
                        observedSuffixRunCount: observedSuffixRunCount
                    )
                )
            }
            return nil
        }

        // Planning is complete and the exact source prefix is still authoritative. No detached
        // work needs those source paths anymore, so release the read lease before starting output
        // materialization. The current root itself continues to protect the source prefix.
        segmentedManifestCompactionReadLeaseNames.removeAll(keepingCapacity: true)
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: plan.outputRunCount
        )
        let replacementNames = (0..<plan.outputRunCount).map { _ in
            "run-g\(currentRoot.generation)-\(UUID().uuidString.lowercased()).seg"
        }
        segmentedManifestRunPrefixMaterializationNames = Set(replacementNames)
        let materializationToken = UUID()
        let materializationTask = Task.detached {
            if let materializationObserver { await materializationObserver() }
            try Task.checkCancellation()
            var replacements: [SegmentedManifestDescriptorV1] = []
            replacements.reserveCapacity(plan.outputRunCount)
            for (mutations, name) in zip(plan.replacementMutationRuns, replacementNames) {
                try Task.checkCancellation()
                let descriptor = try SegmentedManifestPrototypeV1.writeRun(
                    mutations,
                    fileName: name,
                    directory: segmentDirectory
                )
                replacements.append(descriptor)
                if let materializationProgressObserver {
                    await materializationProgressObserver(
                        replacements.count,
                        plan.outputRunCount
                    )
                }
            }
            try Task.checkCancellation()
            return replacements
        }
        segmentedManifestRunPrefixMaterializationTask = materializationTask
        segmentedManifestRunPrefixMaterializationToken = materializationToken

        let replacements: [SegmentedManifestDescriptorV1]
        do {
            replacements = try await materializationTask.value
            clearSegmentedRunPrefixMaterializationTask(token: materializationToken)
        } catch is CancellationError {
            clearSegmentedRunPrefixMaterializationTask(token: materializationToken)
            segmentedManifestRunPrefixMaterializationNames.removeAll(keepingCapacity: true)
            if !requiresReopenBeforeFurtherAccess {
                do {
                    _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                        root: segmentedManifestRoot,
                        directory: segmentDirectory,
                        preserving: segmentedManifestCompactionPreservedNames()
                    )
                } catch {
                    requiresReopenBeforeFurtherAccess = true
                    throw error
                }
            }
            if let rejectionObserver { await rejectionObserver(.staleOrCancelled) }
            return nil
        } catch {
            clearSegmentedRunPrefixMaterializationTask(token: materializationToken)
            segmentedManifestRunPrefixMaterializationNames.removeAll(keepingCapacity: true)
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: segmentedManifestRoot,
                    directory: segmentDirectory,
                    preserving: segmentedManifestCompactionPreservedNames()
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
            }
            throw error
        }

        if requiresReopenBeforeFurtherAccess {
            segmentedManifestRunPrefixMaterializationNames.removeAll(keepingCapacity: true)
            if let rejectionObserver { await rejectionObserver(.staleOrCancelled) }
            return nil
        }
        guard let materializedRoot = segmentedManifestRoot,
            materializedRoot.profile == SegmentedManifestPrototypeV1.profileV4,
            materializedRoot.base == frozenRoot.base,
            materializedRoot.generation >= frozenRoot.generation,
            materializedRoot.runs.count >= sourcePrefixRuns.count,
            Array(materializedRoot.runs.prefix(sourcePrefixRuns.count)) == sourcePrefixRuns
        else {
            segmentedManifestRunPrefixMaterializationNames.removeAll(keepingCapacity: true)
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: segmentedManifestRoot,
                    directory: segmentDirectory,
                    preserving: segmentedManifestCompactionPreservedNames()
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            if let rejectionObserver { await rejectionObserver(.staleOrCancelled) }
            return nil
        }


        let materializedSuffixRunCount = materializedRoot.runs.count - sourcePrefixRuns.count
        guard admission.acceptsObservedSuffix(
            inputRunCount: plan.inputRunCount,
            outputRunCount: plan.outputRunCount,
            suffixRunCount: materializedSuffixRunCount,
            inputRunBytes: plan.inputRunBytes,
            outputRunBytes: plan.outputRunBytes
        ) else {
            // The plan was still worthwhile before materialization, but foreground suffix growth
            // consumed that margin while detached output writes were in flight. The outputs are
            // non-authoritative; drop their reservation and reclaim them before returning nil.
            segmentedManifestRunPrefixMaterializationNames.removeAll(keepingCapacity: true)
            do {
                _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                    root: materializedRoot,
                    directory: segmentDirectory,
                    preserving: segmentedManifestCompactionPreservedNames()
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            if let rejectionObserver {
                await rejectionObserver(
                    .suffixRecurrenceAfterMaterialization(
                        observedSuffixRunCount: materializedSuffixRunCount
                    )
                )
            }
            return nil
        }

        segmentedManifestRunPrefixCollapseCandidate = .init(
            generation: frozenRoot.generation,
            profile: frozenRoot.profile,
            base: frozenRoot.base,
            sourcePrefixRuns: sourcePrefixRuns,
            replacementRuns: replacements,
            touchedKeyCount: plan.touchedKeyCount,
            finalUpsertCount: plan.finalUpsertCount,
            inputRunBytes: plan.inputRunBytes,
            outputRunBytes: plan.outputRunBytes
        )
        // Candidate ownership now preserves every materialized output name. Clear the detached
        // materialization reservation only after that handoff is visible in actor state.
        segmentedManifestRunPrefixMaterializationNames.removeAll(keepingCapacity: true)
        return FileBlobStoreSegmentedRunPrefixCollapseResult(
            sourcePrefixRunCount: sourcePrefixRuns.count,
            replacementRunCount: replacements.count,
            suffixRunCount: materializedRoot.runs.count - sourcePrefixRuns.count,
            finalRunCount: replacements.count
                + materializedRoot.runs.count - sourcePrefixRuns.count,
            touchedKeyCount: plan.touchedKeyCount,
            finalUpsertCount: plan.finalUpsertCount,
            inputRunBytes: plan.inputRunBytes,
            outputRunBytes: plan.outputRunBytes
        )
    }

    func cancelSegmentedRunPrefixPreparationForHardCapacity() {
        segmentedManifestRunPrefixPreparationTask?.cancel()
        segmentedManifestRunPrefixMaterializationTask?.cancel()
    }

    private func clearSegmentedRunPrefixPreparationTask(token: UUID) {
        guard segmentedManifestRunPrefixPreparationToken == token else { return }
        segmentedManifestRunPrefixPreparationTask = nil
        segmentedManifestRunPrefixPreparationToken = nil
    }

    private func clearSegmentedRunPrefixMaterializationTask(token: UUID) {
        guard segmentedManifestRunPrefixMaterializationToken == token else { return }
        segmentedManifestRunPrefixMaterializationTask = nil
        segmentedManifestRunPrefixMaterializationToken = nil
    }
}
