import Foundation

extension SegmentedManifestShadowProbe {
    static func dispatchResearchCommand(_ command: String, arguments: [String]) async throws -> Bool {
        switch command {
        case "segmented-manifest-shadow":
            try run(arguments: arguments)
        case "segmented-manifest-process-seed":
            try processCrashSeed(arguments: arguments)
        case "segmented-manifest-process-crash":
            try processCrash(arguments: arguments)
        case "segmented-manifest-process-inspect":
            try processCrashInspect(arguments: arguments)
        case "segmented-manifest-rebase-shadow":
            try rebaseShadow(arguments: arguments)
        case "segmented-manifest-bounded-proof":
            try boundedProofShadow(arguments: arguments)
        case "segmented-manifest-headroom-shadow":
            try headroomShadow(arguments: arguments)
        case "segmented-manifest-session-token":
            try sessionTokenShadow(arguments: arguments)
        case "segmented-manifest-generated-proof":
            try generatedProofShadow(arguments: arguments)
        case "segmented-manifest-rebase-crash-seed":
            try rebaseCrashSeed(arguments: arguments)
        case "segmented-manifest-rebase-crash":
            try rebaseCrash(arguments: arguments)
        case "segmented-manifest-rebase-crash-inspect":
            try rebaseCrashInspect(arguments: arguments)
        case "segmented-manifest-directory-epoch":
            try await directoryEpochShadow(arguments: arguments)
        case "segmented-manifest-epoch-handoff":
            try epochHandoffShadow(arguments: arguments)
        case "segmented-manifest-epoch-crash-seed":
            try epochCrashSeed(arguments: arguments)
        case "segmented-manifest-epoch-crash":
            try epochCrash(arguments: arguments)
        case "segmented-manifest-epoch-crash-inspect":
            try epochCrashInspect(arguments: arguments)
        case "segmented-checkpoint-resource":
            try checkpointResource(arguments: arguments)
        case "segmented-manifest-segment-gc":
            try segmentGCShadow(arguments: arguments)
        case "segmented-schema5-package-prototype":
            try schema5PackagePrototype(arguments: arguments)
        case "segmented-schema5-base-preflight":
            try schema5BasePreflight(arguments: arguments)
        case "segmented-schema5-reopen-depth":
            try schema5ReopenDepth(arguments: arguments)
        case "segmented-schema5-recovery-phase-profile":
            try schema5RecoveryPhaseProfile(arguments: arguments)
        case "segmented-schema5-compaction-trigger-causal":
            try schema5CompactionTriggerCausal(arguments: arguments)
        case "segmented-schema5-codec-micro":
            try schema5CodecMicro()
        case "segmented-schema5-fast-decoder-differential":
            try schema5FastDecoderDifferential()
        case "segmented-schema5-migration-shadow":
            try await schema5MigrationShadow(arguments: arguments)
        case "segmented-schema5-migration-crash-seed":
            try await schema5MigrationCrashSeed(arguments: arguments)
        case "segmented-schema5-migration-crash":
            try await schema5MigrationCrash(arguments: arguments)
        case "segmented-schema5-migration-crash-inspect":
            try await schema5MigrationCrashInspect(arguments: arguments)
        case "segmented-schema5-migration-complete":
            try await schema5MigrationComplete(arguments: arguments)
        case "segmented-schema5-migration-head-crash":
            try schema5MigrationHeadCrash(arguments: arguments)
        case "segmented-schema5-migration-head-inspect":
            try await schema5MigrationHeadInspect(arguments: arguments)
        case "segmented-schema5-migration-future-head-control":
            try await schema5MigrationFutureHeadControl(arguments: arguments)
        case "segmented-schema5-fileblob-integration":
            try await schema5FileBlobStoreIntegration(arguments: arguments)
        case "segmented-schema5-checkpoint-crash-seed":
            try await schema5CheckpointCrashSeed(arguments: arguments)
        case "segmented-schema5-checkpoint-crash":
            try await schema5CheckpointCrash(arguments: arguments)
        case "segmented-schema5-checkpoint-crash-inspect":
            try await schema5CheckpointCrashInspect(arguments: arguments)
        case "segmented-schema5-phase-alias-checkpoint-crash-seed":
            try await schema5PhaseAliasCheckpointCrashSeed(arguments: arguments)
        case "segmented-schema5-phase-alias-checkpoint-crash":
            try await schema5PhaseAliasCheckpointCrash(arguments: arguments)
        case "segmented-schema5-phase-alias-checkpoint-crash-inspect":
            try await schema5PhaseAliasCheckpointCrashInspect(arguments: arguments)
        case "segmented-schema5-recovery-liveness":
            try await SegmentedSchema5RecoveryLivenessProbe.run(arguments: arguments)
        case "segmented-schema5-capacity-preflight":
            try await schema5CapacityPreflight(arguments: arguments)
        case "segmented-schema5-run-cap-rescue-current":
            try await schema5RunCapacityRescue(arguments: arguments)
        case "segmented-schema5-run-cap-collapse-fallback-current":
            try await schema5RunCapacityCollapseFallback(arguments: arguments)
        case "segmented-schema5-run-cap-boundary-resource":
            try await schema5RunCapacityBoundaryResource(arguments: arguments)
        case "segmented-schema5-checkpoint-boundary-resource":
            try await schema5CheckpointBoundaryResource(arguments: arguments)
        case "segmented-schema5-checkpoint-preseal-current":
            try await schema5CheckpointPreseal(arguments: arguments)
        case "segmented-schema5-run-cap-rescue-crash-seed":
            try await schema5RunCapacityRescueCrashSeed(arguments: arguments)
        case "segmented-schema5-run-cap-rescue-crash":
            try await schema5RunCapacityRescueCrash(arguments: arguments)
        case "segmented-schema5-run-cap-rescue-crash-recover":
            try await schema5RunCapacityRescueCrashRecover(arguments: arguments)
        case "segmented-schema5-run-cap-collapse-crash":
            try await schema5RunCapacityCollapseCrash(arguments: arguments)
        case "segmented-schema5-run-cap-collapse-crash-recover":
            try await schema5RunCapacityCollapseCrashRecover(arguments: arguments)
        case "segmented-schema5-run-cap-background-composition-current":
            try await schema5RunCapacityBackgroundComposition(arguments: arguments)
        case "segmented-schema5-run-collapse-current":
            try await schema5RunCollapse(arguments: arguments)
        case "segmented-schema5-run-collapse-crash-seed":
            try await schema5RunCollapseCrashSeed(arguments: arguments)
        case "segmented-schema5-run-collapse-crash":
            try await schema5RunCollapseCrash(arguments: arguments)
        case "segmented-schema5-run-collapse-crash-recover":
            try await schema5RunCollapseCrashRecover(arguments: arguments)
        case "segmented-schema5-run-collapse-resource":
            try await schema5RunCollapseResource(arguments: arguments)
        case "segmented-schema5-checkpoint-one-head-crash":
            try await schema5CheckpointOneHeadCrash(arguments: arguments)
        case "segmented-schema5-public-segment-gc":
            try await schema5PublicSegmentGC(arguments: arguments)
        case "segmented-schema5-name-ownership-control":
            try await schema5NameOwnershipControl(arguments: arguments)
        case "segmented-schema5-referenced-physical-ownership":
            try await schema5ReferencedPhysicalOwnership(arguments: arguments)
        case "segmented-schema5-long-sequence-worker":
            try await schema5LongSequenceWorker(arguments: arguments)
        case "segmented-schema5-long-sequence-inspect":
            try await schema5LongSequenceInspect(arguments: arguments)
        case "segmented-schema5-random-sequence-worker":
            try await schema5RandomSequenceWorker(arguments: arguments)
        case "segmented-schema5-random-sequence-inspect":
            try await schema5RandomSequenceInspect(arguments: arguments)
        case "segmented-schema5-v3-recovery-cleanup-open":
            try await schema5V3RecoveryCleanupOpen(arguments: arguments)
        case "multiprocess-point-read-wait":
            try await multiProcessPointReadWait(arguments: arguments)
        case "multiprocess-point-read-remove":
            try await multiProcessPointReadRemove(arguments: arguments)
        case "multiprocess-retirement-reader":
            try await multiProcessRetirementBarrierReader(arguments: arguments)
        case "multiprocess-retirement-remove":
            try await multiProcessRetirementBarrierRemove(arguments: arguments)
        case "multiprocess-retirement-check":
            try multiProcessRetirementBarrierCheck(arguments: arguments)
        case "multiprocess-retirement-turnstile-reader":
            try await multiProcessRetirementTurnstileReader(arguments: arguments)
        case "multiprocess-retirement-turnstile-remove":
            try await multiProcessRetirementTurnstileRemove(arguments: arguments)
        case "multiprocess-retirement-turnstile-check":
            try multiProcessRetirementTurnstileCheck(arguments: arguments)
        case "multiprocess-retirement-local-refcount":
            try await multiProcessRetirementLocalRefcount(arguments: arguments)
        case "multiprocess-retirement-local-admission":
            try await multiProcessRetirementLocalAdmission(arguments: arguments)
        case "multiprocess-retirement-local-writer-state":
            try await multiProcessRetirementLocalWriterState(arguments: arguments)
        case "multiprocess-retirement-local-writer-remote-reader":
            try await multiProcessRetirementLocalWriterRemoteReader(arguments: arguments)
        case "segmented-schema5-compaction-integration":
            try await schema5CompactionIntegration(arguments: arguments)
        case "segmented-schema5-compaction-crash-seed":
            try await schema5CompactionCrashSeed(arguments: arguments)
        case "segmented-schema5-compaction-crash":
            try await schema5CompactionCrash(arguments: arguments)
        case "segmented-schema5-compaction-crash-inspect":
            try await schema5CompactionCrashInspect(arguments: arguments)
        case "segmented-schema5-compaction-headroom":
            try await schema5CompactionHeadroom(arguments: arguments)
        case "segmented-schema5-compaction-resource":
            try await schema5CompactionResource(arguments: arguments)
        case "segmented-manifest-locality-trace-current":
            try SegmentedManifestLocalityTraceProbe.run()
        case "segmented-binary-base-correctness":
            try binaryBaseCorrectness()
        case "segmented-binary-base-resource":
            try binaryBaseResource()
        case "segmented-binary-base-v2-root-shadow":
            try binaryBaseV2RootShadow()
        case "segmented-binary-base-v2-seed":
            try binaryBaseV2Seed(arguments: arguments)
        case "segmented-binary-base-v2-transition-shadow":
            try binaryBaseV2TransitionShadow()
        case "segmented-binary-base-v2-transition-crash-seed":
            try binaryBaseV2TransitionCrashSeed(arguments: arguments)
        case "segmented-binary-base-v2-transition-crash":
            try binaryBaseV2TransitionCrash(arguments: arguments)
        case "segmented-binary-base-v2-transition-crash-inspect":
            try binaryBaseV2TransitionCrashInspect(arguments: arguments)
        case "segmented-binary-base-v3-root-shadow":
            try binaryBaseV3RootShadow()
        case "segmented-binary-base-v3-transition-crash-seed":
            try binaryBaseV3TransitionCrashSeed(arguments: arguments)
        case "segmented-binary-base-v3-transition-crash":
            try binaryBaseV3TransitionCrash(arguments: arguments)
        case "segmented-binary-base-v3-transition-crash-inspect":
            try binaryBaseV3TransitionCrashInspect(arguments: arguments)
        default:
            return false
        }
        return true
    }
}
