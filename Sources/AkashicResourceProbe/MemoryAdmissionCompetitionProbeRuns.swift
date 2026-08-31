import AkashicMemory
import Foundation

extension MemoryAdmissionCompetitionProbe {
    static let costLimit = 1_024
    static let windowLimit = 64
    static let fillerBase = 0
    static let warmBase = 100_000
    static let coreBase = 200_000
    static let streamBase = 1_000_000
    static let burstBase = 2_000_000

    static func run(workloads requestedWorkloads: [String] = []) throws {
        let baseWorkloads = [
            "second-touch-stream",
            "one-touch-stream-control",
            "second-touch-gap-0b",
            "second-touch-gap-4b",
            "second-touch-gap-8b",
            "second-touch-gap-16b",
            "second-touch-gap-32b",
            "second-touch-gap-64b",
            "second-touch-gap-128b",
            "second-touch-gap-256b",
            "second-touch-gap-512b",
            "second-touch-gap-1024b",
            "second-touch-gap-2048b",
            "second-touch-gap-4096b",
            "two-touch-burst",
            "sparse-third-touch",
            "same-prefix-dead-s4",
            "same-prefix-third-s4",
            "same-prefix-dead-s16",
            "same-prefix-third-s16",
            "same-prefix-dead-s64",
            "same-prefix-third-s64",
            "physical-lease-branch-target-s64-n114",
            "physical-lease-branch-collateral-s64-n114",
            "sparse-third-size-32",
            "sparse-third-size-64",
            "sparse-third-size-128",
            "sparse-third-size-256",
            "sparse-third-size-512",
            "multi-sparse-third-c3-s128",
            "multi-sparse-third-c5-s64",
            "multi-sparse-third-c2-s256",
            "budget-fragment-small-first",
            "budget-fragment-large-first",
            "budget-occupancy-target64-decoys-first",
            "budget-occupancy-target64-target-first",
            "phase-shift",
            "cost-skew",
        ]
        let interleavedCohortWorkloads = [4, 8, 16, 32, 64].flatMap { cohortSize in
            [8, 32].map { quietHits in
                "interleaved-second-touch-c\(cohortSize)-q\(quietHits)"
            }
        }
        let anchorCohortWorkloads = [4, 8, 16, 32].flatMap { cohortSize in
            [8, 32].flatMap { quietHits in
                [1, 4, 8].flatMap { anchorCount in
                    [64, 256].map { scanObjects in
                        "anchor-second-touch-c\(cohortSize)-q\(quietHits)-a\(anchorCount)-n\(scanObjects)"
                    }
                }
            }
        }
        // Within each family all variants have the exact same request prefix: every 16-byte
        // candidate receives two requests, then the same hot/cold pressure is applied. Only the
        // final third-request target differs. Counts 5/9/17/33 place 80/144/272/528 candidate
        // bytes behind identical prefixes, just over the 64/128/256/512 speculative budgets.
        let indistinguishablePrefixWorkloads = [5, 9, 17, 33].flatMap { candidateCount in
            (0..<candidateCount).map {
                "indist-prefix-c\(candidateCount)-s16-target\($0)"
            }
        }
        let allWorkloads = baseWorkloads
            + interleavedCohortWorkloads
            + anchorCohortWorkloads
            + indistinguishablePrefixWorkloads
        let workloads: [String]
        if requestedWorkloads.isEmpty {
            workloads = allWorkloads
        } else {
            let available = Set(allWorkloads)
            guard Set(requestedWorkloads).count == requestedWorkloads.count,
                requestedWorkloads.allSatisfy(available.contains)
            else { throw ProbeError.resourceSampleFailed }
            workloads = requestedWorkloads
        }
        let policyFactories: [(String, () -> AdmissionCompetitionPolicy)] = [
            ("baseline-sieve", { BaselineSIEVECompetitionPolicy(limit: costLimit) }),
            ("delayed-promotion-1", { DelayedPromotionCompetitionPolicy(limit: costLimit) }),
            ("budgeted-second-hit-b64", {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 64)
            }),
            ("budgeted-second-hit-b128", {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 128)
            }),
            ("budgeted-second-hit-b256", {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 256)
            }),
            ("budgeted-second-hit-b512", {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 512)
            }),
            ("cohort-p8-q8", {
                CohortPromotionCompetitionPolicy(
                    limit: costLimit,
                    pendingLimit: 8,
                    quietEstablishedHitsRequired: 8
                )
            }),
            ("cohort-p8-q32", {
                CohortPromotionCompetitionPolicy(
                    limit: costLimit,
                    pendingLimit: 8,
                    quietEstablishedHitsRequired: 32
                )
            }),
            ("cohort-p32-q8", {
                CohortPromotionCompetitionPolicy(
                    limit: costLimit,
                    pendingLimit: 32,
                    quietEstablishedHitsRequired: 8
                )
            }),
            ("cohort-p32-q32", {
                CohortPromotionCompetitionPolicy(
                    limit: costLimit,
                    pendingLimit: 32,
                    quietEstablishedHitsRequired: 32
                )
            }),
            ("exact-two-hit-gate", { ExactTwoHitCompetitionPolicy(limit: costLimit) }),
            ("exact-age4096", {
                ExactFrequencyCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    agingVolume: 4_096
                )
            }),
            ("exact-age16384", {
                ExactFrequencyCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    agingVolume: 16_384
                )
            }),
            ("exact-byte-age4096", {
                ExactFrequencyCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    agingVolume: 4_096,
                    byteWeightedEvidence: true
                )
            }),
            ("exact-byte-age16384", {
                ExactFrequencyCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    agingVolume: 16_384,
                    byteWeightedEvidence: true
                )
            }),
            ("sketch-w128-age4096", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 128,
                    agingVolume: 4_096
                )
            }),
            ("sketch-w128-age16384", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 128,
                    agingVolume: 16_384
                )
            }),
            ("sketch-w512-age4096", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 512,
                    agingVolume: 4_096
                )
            }),
            ("sketch-w512-age16384", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 512,
                    agingVolume: 16_384
                )
            }),
            ("sketch-byte-w128-age4096", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 128,
                    agingVolume: 4_096,
                    byteWeightedEvidence: true
                )
            }),
            ("sketch-byte-w128-age16384", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 128,
                    agingVolume: 16_384,
                    byteWeightedEvidence: true
                )
            }),
            ("sketch-byte-w512-age4096", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 512,
                    agingVolume: 4_096,
                    byteWeightedEvidence: true
                )
            }),
            ("sketch-byte-w512-age16384", {
                BoundedSketchCompetitionPolicy(
                    limit: costLimit,
                    windowLimit: windowLimit,
                    width: 512,
                    agingVolume: 16_384,
                    byteWeightedEvidence: true
                )
            }),
        ]

        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            for (_, factory) in policyFactories {
                let policy = factory()
                policy.prepare(requests: trace.requests)
                policy.seed(trace.seed)
                results.append(run(policy: policy, workload: workload, requests: trace.requests))
            }
        }

        let comparisons = comparisonsAgainstBaseline(results)
        let collisions = [128, 512].map(collisionControl)
        let byKey = Dictionary(uniqueKeysWithValues: results.map { ("\($0.workload)|\($0.policy)", $0) })
        let secondTouchBaseline = byKey["second-touch-stream|baseline-sieve"]
        let oneTouchBaseline = byKey["one-touch-stream-control|baseline-sieve"]
        let twoHitSecondTouch = byKey["second-touch-stream|exact-two-hit-gate"]
        let twoHitBurst = byKey["two-touch-burst|exact-two-hit-gate"]
        let baselinePollutionReproduced = secondTouchBaseline.map { row in
            roleMetric(row, .core).byteHitRatio < 0.2
                && roleMetric(row, .warm).byteHitRatio < 0.2
        } ?? true
        let oneTouchControlProtected = oneTouchBaseline.map { row in
            roleMetric(row, .core).byteHitRatio == 1
                && roleMetric(row, .warm).byteHitRatio == 1
        } ?? true
        let twoHitProtectsHotSet = twoHitSecondTouch.map { row in
            roleMetric(row, .core).byteHitRatio > 0.95
                && roleMetric(row, .warm).byteHitRatio > 0.95
        } ?? true
        let twoHitSacrificesBurst = twoHitBurst.map { row in
            roleMetric(row, .burst).byteHitRatio == 0
        } ?? true
        let allResidentBoundsPreserved = results.allSatisfy {
            $0.maximumResidentCost <= costLimit
        }
        let allSketchesBounded = results.filter { $0.policy.hasPrefix("sketch-") }.allSatisfy {
            let expectedBytes = $0.policy.contains("w512") ? 2_048 : 512
            return $0.metadataBytes == expectedBytes
        }
        let collisionControlsCreateFalseHot = collisions.allSatisfy(\.falseHotCreated)
        let distanceWorkloads: Set<String> = [
            "second-touch-gap-0b",
            "second-touch-gap-4b",
            "second-touch-gap-8b",
            "second-touch-gap-16b",
            "second-touch-gap-32b",
            "second-touch-gap-64b",
            "second-touch-gap-128b",
            "second-touch-gap-256b",
            "second-touch-gap-512b",
            "second-touch-gap-1024b",
            "second-touch-gap-2048b",
            "second-touch-gap-4096b",
        ]
        let distanceTracesBalanced = results
            .filter { distanceWorkloads.contains($0.workload) }
            .allSatisfy { row in
                roleMetric(row, .stream).requests == 8_192
                    && roleMetric(row, .stream).requestBytes == 32_768
                    && roleMetric(row, .core).requests == 1_024
                    && roleMetric(row, .core).requestBytes == 4_096
                    && roleMetric(row, .warm).requests == 2_048
                    && roleMetric(row, .warm).requestBytes == 8_192
            }
        let checks: [String: Bool] = [
            "baseline-reproduces-second-touch-pollution": baselinePollutionReproduced,
            "baseline-one-touch-control-protected": oneTouchControlProtected,
            "two-hit-gate-protects-hot-set": twoHitProtectsHotSet,
            "two-hit-gate-sacrifices-second-access-burst": twoHitSacrificesBurst,
            "all-resident-bounds-preserved": allResidentBoundsPreserved,
            "all-sketches-bounded": allSketchesBounded,
            "collision-controls-create-false-hot": collisionControlsCreateFalseHot,
            "distance-traces-balanced": distanceTracesBalanced,
        ]

        let report = AdmissionCompetitionReport(
            schemaVersion: 2,
            costLimit: costLimit,
            windowLimit: windowLimit,
            workloads: workloads,
            policies: policyFactories.map(\.0),
            results: results,
            comparisonsAgainstBaseline: comparisons,
            collisions: collisions,
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    /// Perfect-lookahead control for separating online evidence quality from the fixed
    /// window+main/SIEVE replacement topology. This is intentionally not part of the normal
    /// competition matrix: remaining-trace knowledge is unbounded oracle information and can
    /// never be a production policy contract.
    static func runFutureOracle(workloads: [String]) throws {
        guard !workloads.isEmpty, Set(workloads).count == workloads.count else {
            throw ProbeError.resourceSampleFailed
        }

        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            let policy = FutureOracleCompetitionPolicy(
                limit: costLimit,
                windowLimit: windowLimit
            )
            policy.prepare(requests: trace.requests)
            policy.seed(trace.seed)
            results.append(
                run(policy: policy, workload: workload, requests: trace.requests)
            )
        }

        let checks: [String: Bool] = [
            "all-resident-bounds-preserved": results.allSatisfy {
                $0.maximumResidentCost <= costLimit
            },
            "all-oracle-future-state-consumed": results.allSatisfy {
                $0.metadataBytes == 0
            },
            "all-results-are-future-oracle": results.allSatisfy {
                $0.policy == "future-oracle-byte"
            },
        ]
        let report = AdmissionCompetitionReport(
            schemaVersion: 3,
            costLimit: costLimit,
            windowLimit: windowLimit,
            workloads: workloads,
            policies: ["future-oracle-byte"],
            results: results,
            comparisonsAgainstBaseline: [],
            collisions: [],
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }
}
