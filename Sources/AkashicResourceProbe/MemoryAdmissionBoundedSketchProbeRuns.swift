import AkashicMemory
import Foundation

extension MemoryAdmissionBoundedSketchProbe {
    static func run(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--config" else {
            throw ProbeError.invalidArguments
        }
        let configData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let config = try JSONDecoder().decode(SketchConfigFile.self, from: configData)
        let clocks = config.families.flatMap { family in
            family.values.map { SketchClockConfig(kind: family.kind, value: $0) }
        }
        guard !clocks.isEmpty,
            clocks.allSatisfy({ ($0.kind == "cost-volume" || $0.kind == "contest") && $0.value > 0 })
        else { throw ProbeError.invalidArguments }

        let widths = [128, 512, 2048]
        let workloads = [
            "unique-small", "unique-medium", "unique-giant", "two-touch",
            "dominant", "sparse", "phase", "alternating", "small-to-giant",
            "giant-to-small", "cold-cardinality",
        ]
        var results: [SketchPolicyResult] = []
        for clock in clocks {
            for width in widths {
                for workload in workloads {
                    results.append(runCase(clock: clock, width: width, workload: workload))
                }
            }
        }
        let collisions = widths.map(collisionControl)
        let summary = [
            "allCollisionControlsCreateFalseHot": collisions.allSatisfy(\.falseHotCreated),
            "allCounterPayloadsExact": results.allSatisfy { $0.counterPayloadBytes == FourRowCountMinSketch.rowCount * $0.width },
            "allVictimBoundsPreserved": results.allSatisfy { $0.maximumVictimCount <= 9 && $0.maximumVictimCost <= 90 },
        ]
        let report = SketchProbeReport(
            schemaVersion: 1,
            rows: FourRowCountMinSketch.rowCount,
            widths: widths,
            eligibleClocks: clocks,
            results: results,
            collisions: collisions,
            summary: summary,
            claims: .init(
                productionPolicy: false,
                shardedConcurrencyQualified: false,
                formalPerformance: false,
                fullMemoryFootprintQualified: false,
                deterministicHashPersistence: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func runTransactionFrontier(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let width = 128
        let victimKey = 0
        let candidateKey = findSeparatedKey(
            startingAt: 10_000,
            avoiding: victimKey,
            width: width
        )
        let rows = [
            try transactionFrontierCase(
                workload: "stale-admit-after-victim-evidence-rise",
                width: width,
                candidateKey: candidateKey,
                victimKey: victimKey,
                candidateSeedCount: 8,
                victimSeedCount: 1,
                evidenceTarget: victimKey,
                evidenceAvoid: candidateKey
            ),
            try transactionFrontierCase(
                workload: "stale-reject-after-candidate-evidence-rise",
                width: width,
                candidateKey: candidateKey,
                victimKey: victimKey,
                candidateSeedCount: 1,
                victimSeedCount: 8,
                evidenceTarget: candidateKey,
                evidenceAvoid: victimKey
            ),
        ]
        let staleAdmit = rows[0]
        let staleReject = rows[1]
        let checks: [String: Bool] = [
            "stale-admit-flips-to-current-reject": staleAdmit.beforeAdmit
                && !staleAdmit.afterAdmit,
            "stale-reject-flips-to-current-admit": !staleReject.beforeAdmit
                && staleReject.afterAdmit,
            "cache-structure-and-version-remain-unchanged": rows.allSatisfy {
                $0.structuralVictimsUnchanged && !$0.evictionStateVersionChanged
            },
            "old-structural-snapshots-still-commit-through-version-fast-path": rows.allSatisfy {
                $0.structuralCommitAccepted && $0.structuralValidationMode == "versionFastPath"
            },
        ]
        let observations: [String: Bool] = [
            "external-sketch-evidence-can-change-without-cache-decision-state-changing":
                rows.allSatisfy { !$0.evictionStateVersionChanged },
            "structural-token-cannot-linearize-admission-evidence":
                rows.allSatisfy { $0.beforeAdmit != $0.afterAdmit }
                    && rows.allSatisfy { $0.structuralCommitAccepted },
            "staleness-can-cause-both-over-admit-and-under-admit":
                staleAdmit.beforeAdmit && !staleAdmit.afterAdmit
                    && !staleReject.beforeAdmit && staleReject.afterAdmit,
        ]
        let report = SketchTransactionFrontierReport(
            schemaVersion: 1,
            width: width,
            cases: rows,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "cacheStructuralTransactionQualified": true,
                "externalSketchEvidenceLinearized": false,
                "boundedStalenessPolicyDefined": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    static func runEvidenceConsistencyFrontier(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let width = 128
        let victimKey = 0
        let candidateKey = findSeparatedKey(
            startingAt: 10_000,
            avoiding: victimKey,
            width: width
        )
        let unrelatedKey = findKeyAvoiding(
            startingAt: 2_000_000,
            targets: [victimKey, candidateKey],
            width: width
        )

        var seeded = FourRowCountMinSketch(width: width)
        for _ in 0..<8 { seeded.increment(candidateKey) }
        seeded.increment(victimKey)
        let initialCandidate = seeded.estimate(candidateKey)
        let initialVictim = seeded.estimate(victimKey)
        precondition(initialCandidate > initialVictim)

        let retryBudgets = [1, 2, 4, 8, 16]
        let strictRows = retryBudgets.map { budget -> SketchEvidenceVersionRetryCase in
            var sketch = seeded
            var version: UInt64 = 0
            var accepted = false
            var attempts = 0
            let beforeCandidate = sketch.estimate(candidateKey)
            let beforeVictim = sketch.estimate(victimKey)
            let beforeDecision = beforeCandidate > beforeVictim
            for _ in 0..<budget {
                attempts += 1
                let observedVersion = version
                // This update is deliberately irrelevant to every candidate/victim counter cell.
                sketch.increment(unrelatedKey)
                version &+= 1
                if observedVersion == version {
                    accepted = true
                    break
                }
            }
            let afterCandidate = sketch.estimate(candidateKey)
            let afterVictim = sketch.estimate(victimKey)
            return .init(
                retryBudget: budget,
                attempts: attempts,
                accepted: accepted,
                relevantEstimatesChanged:
                    afterCandidate != beforeCandidate || afterVictim != beforeVictim,
                decisionChanged: (afterCandidate > afterVictim) != beforeDecision
            )
        }

        let intervals = [8, 32, 128]
        let epochRows = intervals.map { interval -> SketchEvidenceEpochLagCase in
            var sketch = EpochLatchedFourRowSketch(width: width, epochInterval: interval)
            sketch.observe(victimKey)
            sketch.observe(victimKey)
            sketch.publishCurrentWithoutAging()
            let beforeCandidate = sketch.publishedEstimate(candidateKey)
            let beforeVictim = sketch.publishedEstimate(victimKey)
            precondition(beforeCandidate <= beforeVictim)

            var observations = 0
            while sketch.publishedEstimate(candidateKey) <= sketch.publishedEstimate(victimKey) {
                sketch.observe(candidateKey)
                observations += 1
                precondition(observations <= interval * 2)
            }
            return .init(
                epochInterval: interval,
                observationsUntilPublishedDecisionFlip: observations,
                publishedCandidateEstimateBefore: beforeCandidate,
                publishedVictimEstimateBefore: beforeVictim,
                publishedCandidateEstimateAfter: sketch.publishedEstimate(candidateKey),
                publishedVictimEstimateAfter: sketch.publishedEstimate(victimKey),
                singleSketchCounterBytes: sketch.singleSketchCounterBytes,
                dualSketchLogicalCounterBytes: sketch.dualSketchLogicalCounterBytes
            )
        }

        let checks: [String: Bool] = [
            "unrelated-update-does-not-touch-relevant-estimates": strictRows.allSatisfy {
                !$0.relevantEstimatesChanged && !$0.decisionChanged
            },
            "strict-global-version-can-exhaust-every-fixed-retry-budget": strictRows.allSatisfy {
                !$0.accepted && $0.attempts == $0.retryBudget
            },
            "epoch-latched-evidence-flips-at-one-explicit-epoch": epochRows.allSatisfy {
                $0.observationsUntilPublishedDecisionFlip == $0.epochInterval
            },
            "epoch-latched-logical-counter-payload-is-two-x": epochRows.allSatisfy {
                $0.dualSketchLogicalCounterBytes == 2 * $0.singleSketchCounterBytes
            },
        ]
        let observations: [String: Bool] = [
            "global-version-is-too-coarse-for-approximate-evidence": strictRows.allSatisfy {
                !$0.relevantEstimatesChanged && !$0.accepted
            },
            "immutable-evidence-epoch-trades-retry-starvation-for-bounded-phase-lag":
                epochRows.allSatisfy {
                    $0.observationsUntilPublishedDecisionFlip == $0.epochInterval
                },
            "epoch-size-becomes-an-explicit-resource-quality-control":
                zip(epochRows, epochRows.dropFirst()).allSatisfy { lhs, rhs in
                    rhs.observationsUntilPublishedDecisionFlip
                        > lhs.observationsUntilPublishedDecisionFlip
                },
        ]
        let report = SketchEvidenceConsistencyReport(
            schemaVersion: 1,
            width: width,
            unrelatedEvidenceKey: unrelatedKey,
            strictVersionRetries: strictRows,
            epochLag: epochRows,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "strictGlobalSketchVersionRecommended": false,
                "epochLatchedCandidateQualified": false,
                "boundedEvidenceStalenessMechanism": true,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    static func runEpochQualityFrontier(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let clocks = [
            SketchClockConfig(kind: "cost-volume", value: 4),
            SketchClockConfig(kind: "contest", value: 64),
        ]
        let widths = [128, 512, 2048]
        let workloads = [
            "unique-small", "unique-medium", "unique-giant", "two-touch",
            "dominant", "sparse", "phase", "alternating", "small-to-giant",
            "giant-to-small", "cold-cardinality",
        ]

        var rows: [SketchEpochQualityRow] = []
        for clock in clocks {
            for width in widths {
                for workload in workloads {
                    for mode in [SketchEvidenceMode.live, .epochLatched] {
                        let result = runCase(
                            clock: clock,
                            width: width,
                            workload: workload,
                            evidenceMode: mode
                        )
                        rows.append(
                            .init(
                                evidenceMode: mode.rawValue,
                                clockKind: result.clockKind,
                                clockValue: result.clockValue,
                                width: result.width,
                                workload: result.workload,
                                requests: result.requests,
                                hits: result.hits,
                                misses: result.misses,
                                falseAdmits: result.falseAdmits,
                                falseRejects: result.falseRejects,
                                admissionContests: result.admissionContests,
                                agingPasses: result.agingPasses,
                                counterPayloadBytes: result.counterPayloadBytes,
                                maximumVictimCount: result.maximumVictimCount,
                                maximumVictimCost: result.maximumVictimCost
                            )
                        )
                    }
                }
            }
        }

        var deltas: [SketchEpochQualityDelta] = []
        for clock in clocks {
            for width in widths {
                for workload in workloads {
                    guard let live = rows.first(where: {
                        $0.evidenceMode == SketchEvidenceMode.live.rawValue
                            && $0.clockKind == clock.kind
                            && $0.clockValue == clock.value
                            && $0.width == width
                            && $0.workload == workload
                    }), let latched = rows.first(where: {
                        $0.evidenceMode == SketchEvidenceMode.epochLatched.rawValue
                            && $0.clockKind == clock.kind
                            && $0.clockValue == clock.value
                            && $0.width == width
                            && $0.workload == workload
                    }) else {
                        throw ProbeError.resourceSampleFailed
                    }
                    deltas.append(
                        .init(
                            clockKind: clock.kind,
                            clockValue: clock.value,
                            width: width,
                            workload: workload,
                            hitDeltaLatchedMinusLive: latched.hits - live.hits,
                            falseAdmitDeltaLatchedMinusLive:
                                latched.falseAdmits - live.falseAdmits,
                            falseRejectDeltaLatchedMinusLive:
                                latched.falseRejects - live.falseRejects,
                            counterPayloadDeltaBytes:
                                latched.counterPayloadBytes - live.counterPayloadBytes
                        )
                    )
                }
            }
        }

        let pairedMechanicsExact = deltas.allSatisfy { delta in
            guard let live = rows.first(where: {
                $0.evidenceMode == SketchEvidenceMode.live.rawValue
                    && $0.clockKind == delta.clockKind
                    && $0.clockValue == delta.clockValue
                    && $0.width == delta.width
                    && $0.workload == delta.workload
            }), let latched = rows.first(where: {
                $0.evidenceMode == SketchEvidenceMode.epochLatched.rawValue
                    && $0.clockKind == delta.clockKind
                    && $0.clockValue == delta.clockValue
                    && $0.width == delta.width
                    && $0.workload == delta.workload
            }) else { return false }
            return live.requests == latched.requests
                && latched.counterPayloadBytes == 2 * live.counterPayloadBytes
        }
        let phaseWorkloads = Set(["phase", "alternating", "small-to-giant", "giant-to-small"])
        let phaseDeltas = deltas.filter { phaseWorkloads.contains($0.workload) }
        let checks: [String: Bool] = [
            "complete-live-latched-pairing": rows.count
                == clocks.count * widths.count * workloads.count * 2
                && deltas.count == clocks.count * widths.count * workloads.count,
            "same-request-corpus-and-two-x-latched-counter-payload": pairedMechanicsExact,
            "all-cache-victim-bounds-preserved": rows.allSatisfy {
                $0.maximumVictimCount <= 9 && $0.maximumVictimCost <= 90
            },
            "all-hit-accounting-exact": rows.allSatisfy { $0.hits + $0.misses == $0.requests },
        ]
        let observations: [String: Bool] = [
            "latched-changes-at-least-one-workload-outcome": deltas.contains {
                $0.hitDeltaLatchedMinusLive != 0
                    || $0.falseAdmitDeltaLatchedMinusLive != 0
                    || $0.falseRejectDeltaLatchedMinusLive != 0
            },
            "latched-has-at-least-one-hit-loss": deltas.contains {
                $0.hitDeltaLatchedMinusLive < 0
            },
            "latched-has-at-least-one-hit-gain": deltas.contains {
                $0.hitDeltaLatchedMinusLive > 0
            },
            "phase-family-exposes-evidence-lag": phaseDeltas.contains {
                $0.hitDeltaLatchedMinusLive != 0
                    || $0.falseAdmitDeltaLatchedMinusLive != 0
                    || $0.falseRejectDeltaLatchedMinusLive != 0
            },
            "quality-effect-depends-on-width-or-clock": Set(deltas.map {
                "\($0.workload):\($0.hitDeltaLatchedMinusLive):"
                    + "\($0.falseAdmitDeltaLatchedMinusLive):"
                    + "\($0.falseRejectDeltaLatchedMinusLive)"
            }).count > workloads.count,
        ]
        let report = SketchEpochQualityReport(
            schemaVersion: 1,
            clocks: clocks,
            widths: widths,
            workloads: workloads,
            rows: rows,
            deltas: deltas,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "epochLatchedCandidateQualified": false,
                "liveEvidenceLinearized": false,
                "hostBusinessSemantics": false,
                "multiWorkloadAdmissionQualityMechanism": true,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else { throw ProbeError.resourceSampleFailed }
    }
}
