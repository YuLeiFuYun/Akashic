import Foundation

enum CacheReadResearchCommand {
    static func dispatch(_ command: String, arguments: [String]) async throws -> Bool {
        switch command {
        case "memory-admission-victim-oracle":
            try MemoryAdmissionVictimProbe.run()
        case "memory-admission-aging-oracle":
            try MemoryAdmissionAgingProbe.run()
        case "memory-admission-cost-volume-oracle":
            try MemoryAdmissionCostVolumeProbe.run()
        case "memory-admission-contest-aging-oracle":
            try MemoryAdmissionContestAgingProbe.run()
        case "memory-admission-bounded-sketch":
            try MemoryAdmissionBoundedSketchProbe.run(arguments: arguments)
        case "memory-admission-sketch-transaction-frontier-current":
            try MemoryAdmissionBoundedSketchProbe.runTransactionFrontier(arguments: arguments)
        case "memory-admission-sketch-evidence-consistency-current":
            try MemoryAdmissionBoundedSketchProbe.runEvidenceConsistencyFrontier(
                arguments: arguments
            )
        case "memory-admission-sketch-epoch-quality-current":
            try MemoryAdmissionBoundedSketchProbe.runEpochQualityFrontier(
                arguments: arguments
            )
        case "memory-admission-sketch-epoch-hybrid-quality-current":
            try MemoryAdmissionBoundedSketchProbe.runEpochHybridQualityFrontier(
                arguments: arguments
            )
        case "memory-admission-transaction-complexity-current":
            try MemoryAdmissionTransactionComplexityProbe.run(arguments: arguments)
        case "memory-admission-bounded-structural-fallback-current":
            try MemoryAdmissionBoundedStructuralFallbackProbe.run(arguments: arguments)
        case "memory-admission-fragmentation-frontier-current":
            try MemoryAdmissionFragmentationFrontierProbe.run(arguments: arguments)
        case "memory-deferred-retirement-concurrency-current":
            try MemoryDeferredRetirementConcurrencyProbe.run(arguments: arguments)
        case "memory-retirement-work-scaling-current":
            try MemoryRetirementWorkScalingProbe.run(arguments: arguments)
        case "memory-admission-competition":
            try MemoryAdmissionCompetitionProbe.run(workloads: arguments)
        case "memory-admission-future-oracle-current":
            try MemoryAdmissionCompetitionProbe.runFutureOracle(workloads: arguments)
        case "memory-admission-future-arrival-oracle-current":
            try MemoryAdmissionCompetitionProbe.runFutureArrivalOracle(workloads: arguments)
        case "memory-admission-future-arrival-no-stale-visit-oracle-current":
            try MemoryAdmissionCompetitionProbe.runFutureArrivalNoStaleVisitOracle(
                workloads: arguments
            )
        case "memory-admission-expiring-second-hit-current":
            try MemoryAdmissionCompetitionProbe.runExpiringSecondHitFrontier(
                workloads: arguments
            )
        case "memory-admission-hand-revoked-second-hit-current":
            try MemoryAdmissionCompetitionProbe.runHandRevokedSecondHitFrontier(
                workloads: arguments
            )
        case "memory-admission-counter-saturation":
            try MemoryAdmissionCounterSaturationProbe.run()
        case "memory-admission-hash-collision-frontier":
            try MemoryAdmissionHashCollisionProbe.run()
        case "memory-sieve-byte-partition-current":
            try MemorySIEVEBytePartitionProbe.run()
        case "memory-sieve-interleaved-scan-current":
            try MemorySIEVEInterleavedScanProbe.run()
        case "memory-sieve-topology-skew-current":
            try MemorySIEVETopologySkewProbe.run()
        case "memory-sieve-hot-cost-skew-current":
            try MemorySIEVEHotCostSkewProbe.run()
        case "memory-sieve-delayed-second-touch-current":
            try MemorySIEVEDelayedSecondTouchProbe.run()
        case "memory-sieve-hand-topology-current":
            try MemorySIEVEHandTopologyProbe.run()
        case "memory-sieve-second-touch-distance-current":
            try MemorySIEVESecondTouchDistanceProbe.run()
        case "memory-sieve-second-touch-survival-current":
            try MemorySIEVESecondTouchSurvivalProbe.run()
        case "memory-sieve-second-touch-phase-current":
            try MemorySIEVESecondTouchPhaseProbe.run()
        case "memory-sharded-budget-current":
            try MemoryShardedBudgetProbe.run()
        case "memory-sieve-hot-refill-recovery-current":
            try MemorySIEVEHotRefillRecoveryProbe.run()
        case "memory-sieve-ghost-refill-current":
            try MemorySIEVEGhostRefillProbe.run()
        case "memory-sieve-composite-repair-current":
            try MemorySIEVECompositeRepairProbe.run()
        case "memory-sieve-fingerprint-ghost-current":
            try MemorySIEVEFingerprintGhostProbe.run()
        case "memory-sieve-fingerprint-composite-current":
            try MemorySIEVEFingerprintCompositeProbe.run()
        case "memory-sharded-victim-planner-current":
            try MemoryShardedVictimPlannerProbe.run()
        case "memory-sharded-victim-planner-replay-current":
            try MemoryShardedVictimPlannerReplayProbe.run()
        case "memory-sharded-victim-planner-challenger-current":
            try MemoryShardedVictimPlannerChallengerProbe.run()
        case "read-scheduler-hol-shadow":
            try await ReadSchedulerHOLProbe.run()
        case "read-scheduler-bounded-bypass-model":
            try ReadSchedulerBoundedBypassModelProbe.run()
        case "read-scheduler-bounded-bypass-actual":
            try await ReadSchedulerBoundedBypassActualProbe.run()
        case "read-scheduler-bounded-bypass-scan-cost":
            try await ReadSchedulerBoundedBypassScanCostProbe.run()
        case "read-scheduler-bounded-bypass-size-index":
            try await ReadSchedulerBoundedBypassSizeIndexProbe.run()
        case "read-scheduler-exact-bypass-index-current":
            try await ReadSchedulerExactBypassIndexProbe.run(arguments: arguments)
        case "read-scheduler-bounded-bypass-service":
            try await ReadSchedulerBoundedBypassServiceProbe.run()
        case "read-scheduler-structural-reservation-current":
            try await ReadSchedulerStructuralReservationProbe.run()
        default:
            return false
        }
        return true
    }
}
