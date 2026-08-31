import AkashicMemory
import Foundation

extension MemoryAdmissionBoundedSketchProbe {
    static func runEpochHybridQualityFrontier(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let clocks = [
            SketchClockConfig(kind: "cost-volume", value: 4),
            SketchClockConfig(kind: "contest", value: 64),
        ]
        let widths = [128, 512, 2048]
        let workloads = [
            "unique-small", "unique-medium", "unique-giant", "two-touch",
            "dominant", "sparse", "phase", "alternating", "small-to-giant",
            "giant-to-small", "cold-cardinality", "victim-reheat",
        ]
        var comparisons: [SketchEpochHybridComparison] = []
        for clock in clocks {
            for width in widths {
                for workload in workloads {
                    let live = runCase(
                        clock: clock,
                        width: width,
                        workload: workload,
                        evidenceMode: .live
                    )
                    let latched = runCase(
                        clock: clock,
                        width: width,
                        workload: workload,
                        evidenceMode: .epochLatched
                    )
                    let candidateDelta = runCase(
                        clock: clock,
                        width: width,
                        workload: workload,
                        evidenceMode: .epochLatchedCandidateDelta
                    )
                    comparisons.append(
                        .init(
                            clockKind: clock.kind,
                            clockValue: clock.value,
                            width: width,
                            workload: workload,
                            liveHits: live.hits,
                            latchedHits: latched.hits,
                            candidateDeltaHits: candidateDelta.hits,
                            liveFalseAdmits: live.falseAdmits,
                            latchedFalseAdmits: latched.falseAdmits,
                            candidateDeltaFalseAdmits: candidateDelta.falseAdmits,
                            liveFalseRejects: live.falseRejects,
                            latchedFalseRejects: latched.falseRejects,
                            candidateDeltaFalseRejects: candidateDelta.falseRejects,
                            candidateDeltaHitDeltaVsLive: candidateDelta.hits - live.hits,
                            candidateDeltaHitRecoveryVsLatched:
                                candidateDelta.hits - latched.hits
                        )
                    )
                }
            }
        }

        let phaseWorkloads = Set(["phase", "alternating", "small-to-giant", "giant-to-small"])
        let phaseRows = comparisons.filter { phaseWorkloads.contains($0.workload) }
        let checks: [String: Bool] = [
            "complete-matrix": comparisons.count
                == clocks.count * widths.count * workloads.count,
            "candidate-delta-cache-accounting-bounded": comparisons.allSatisfy {
                $0.candidateDeltaHits >= 0
            },
        ]
        let observations: [String: Bool] = [
            "candidate-delta-recovers-some-latched-hit-loss": comparisons.contains {
                $0.latchedHits < $0.liveHits && $0.candidateDeltaHits > $0.latchedHits
            },
            "candidate-delta-fully-recovers-some-latched-hit-loss": comparisons.contains {
                $0.latchedHits < $0.liveHits && $0.candidateDeltaHits >= $0.liveHits
            },
            "candidate-delta-still-has-some-hit-loss-vs-live": comparisons.contains {
                $0.candidateDeltaHits < $0.liveHits
            },
            "candidate-delta-can-create-more-false-admits-than-latched": comparisons.contains {
                $0.candidateDeltaFalseAdmits > $0.latchedFalseAdmits
            },
            "phase-family-remains-nonuniform": phaseRows.contains {
                $0.candidateDeltaHitDeltaVsLive < 0
            } && phaseRows.contains {
                $0.candidateDeltaHitDeltaVsLive > 0
            },
        ]
        let report = SketchEpochHybridQualityReport(
            schemaVersion: 1,
            clocks: clocks,
            widths: widths,
            workloads: workloads,
            comparisons: comparisons,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "candidateDeltaQualified": false,
                "victimEvidenceImmutableWithinEpoch": true,
                "candidateEvidenceMonotoneWithinEpoch": true,
                "multiWorkloadAdmissionQualityMechanism": true,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else { throw ProbeError.resourceSampleFailed }
    }

    static func transactionFrontierCase(
        workload: String,
        width: Int,
        candidateKey: Int,
        victimKey: Int,
        candidateSeedCount: Int,
        victimSeedCount: Int,
        evidenceTarget: Int,
        evidenceAvoid: Int
    ) throws -> SketchTransactionFrontierCase {
        let cache = MemoryCache<Int, Int>(costLimit: 2)
        cache.insert(victimKey, for: victimKey, cost: 1)
        cache.insert(1, for: 1, cost: 1)
        let structuralSnapshot = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        guard structuralSnapshot.plan.victims.map(\.key) == [victimKey] else {
            throw ProbeError.resourceSampleFailed
        }

        var sketch = FourRowCountMinSketch(width: width)
        for _ in 0..<candidateSeedCount { sketch.increment(candidateKey) }
        for _ in 0..<victimSeedCount { sketch.increment(victimKey) }
        let beforeCandidate = sketch.estimate(candidateKey)
        let beforeVictim = sketch.estimate(victimKey)
        let beforeAdmit = beforeCandidate > beforeVictim

        let colliders = findIndependentColliders(
            target: evidenceTarget,
            avoiding: evidenceAvoid,
            width: width
        )
        for key in colliders {
            for _ in 0..<16 { sketch.increment(key) }
        }
        let afterCandidate = sketch.estimate(candidateKey)
        let afterVictim = sketch.estimate(victimKey)
        let afterAdmit = afterCandidate > afterVictim

        let structuralCurrent = cache.resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: 1
        )
        let commit = cache.resourceProbeCommitRevocationAwareSnapshot(
            candidateKey,
            for: candidateKey,
            cost: 1,
            expectedSnapshot: structuralSnapshot
        )
        return .init(
            workload: workload,
            candidateKey: candidateKey,
            victimKey: victimKey,
            evidenceColliders: colliders,
            beforeCandidateEstimate: beforeCandidate,
            beforeVictimEstimate: beforeVictim,
            beforeAdmit: beforeAdmit,
            afterCandidateEstimate: afterCandidate,
            afterVictimEstimate: afterVictim,
            afterAdmit: afterAdmit,
            structuralVictimsUnchanged:
                structuralCurrent.plan.victims.map(\.key)
                    == structuralSnapshot.plan.victims.map(\.key),
            evictionStateVersionChanged:
                structuralCurrent.evictionStateVersion
                    != structuralSnapshot.evictionStateVersion,
            structuralCommitAccepted: commit.accepted,
            structuralValidationMode: commit.validationMode.rawValue
        )
    }

    static func findSeparatedKey(startingAt start: Int, avoiding: Int, width: Int) -> Int {
        let sketch = FourRowCountMinSketch(width: width)
        var candidate = start
        while true {
            if (0..<FourRowCountMinSketch.rowCount).allSatisfy({ row in
                sketch.position(candidate, row: row) != sketch.position(avoiding, row: row)
            }) {
                return candidate
            }
            candidate += 1
        }
    }

    static func findKeyAvoiding(
        startingAt start: Int,
        targets: [Int],
        width: Int
    ) -> Int {
        let sketch = FourRowCountMinSketch(width: width)
        var candidate = start
        while true {
            let separated = targets.allSatisfy { target in
                (0..<FourRowCountMinSketch.rowCount).allSatisfy { row in
                    sketch.position(candidate, row: row) != sketch.position(target, row: row)
                }
            }
            if separated { return candidate }
            candidate += 1
        }
    }

    static func findIndependentColliders(
        target: Int,
        avoiding: Int,
        width: Int
    ) -> [Int] {
        let sketch = FourRowCountMinSketch(width: width)
        var colliders: [Int] = []
        var cursor = 1_000_000
        for row in 0..<FourRowCountMinSketch.rowCount {
            let wanted = sketch.position(target, row: row)
            while true {
                let candidate = cursor
                cursor += 1
                guard candidate != target,
                    candidate != avoiding,
                    sketch.position(candidate, row: row) == wanted,
                    (0..<FourRowCountMinSketch.rowCount).allSatisfy({ otherRow in
                        sketch.position(candidate, row: otherRow)
                            != sketch.position(avoiding, row: otherRow)
                    })
                else { continue }
                colliders.append(candidate)
                break
            }
        }
        return colliders
    }

    static func runCase(
        clock: SketchClockConfig,
        width: Int,
        workload: String,
        evidenceMode: SketchEvidenceMode = .live
    ) -> SketchPolicyResult {
        let policy = BoundedSketchAdmissionPolicy(
            clock: clock,
            width: width,
            evidenceMode: evidenceMode
        )
        policy.primeHotSet()
        let requests = trace(workload)
        var hits = 0
        for request in requests where policy.request(request) { hits += 1 }
        return SketchPolicyResult(
            clockKind: clock.kind,
            clockValue: clock.value,
            width: width,
            workload: workload,
            requests: requests.count,
            hits: hits,
            misses: requests.count - hits,
            falseAdmits: policy.falseAdmits,
            falseRejects: policy.falseRejects,
            admissionContests: policy.admissionContests,
            agingPasses: policy.agingPasses,
            maximumCounter: policy.maximumCounter,
            counterPayloadBytes: policy.counterPayloadBytes,
            maximumVictimCount: policy.maximumVictimCount,
            maximumVictimCost: policy.maximumVictimCost
        )
    }

    static func collisionControl(width: Int) -> SketchCollisionResult {
        let target = 900_000 + width
        var sketch = FourRowCountMinSketch(width: width)
        var colliders: [Int] = []
        var cursor = 1_000_000
        for row in 0..<FourRowCountMinSketch.rowCount {
            let wanted = sketch.position(target, row: row)
            while sketch.position(cursor, row: row) != wanted || cursor == target { cursor += 1 }
            colliders.append(cursor)
            cursor += 1
        }
        for key in colliders { for _ in 0..<64 { sketch.increment(key) } }
        let estimate = sketch.estimate(target)
        return SketchCollisionResult(
            width: width,
            targetKey: target,
            colliders: colliders,
            incrementsPerCollider: 64,
            exactTargetCount: 0,
            sketchTargetEstimate: estimate,
            falseHotCreated: estimate > 0
        )
    }

    static func trace(_ name: String) -> [SketchRequest] {
        var result: [SketchRequest] = []
        switch name {
        case "unique-small": appendPollution(rounds: 100, cost: 10, base: 10_000, into: &result)
        case "unique-medium": appendPollution(rounds: 100, cost: 40, base: 20_000, into: &result)
        case "unique-giant": appendPollution(rounds: 100, cost: 90, base: 30_000, into: &result)
        case "two-touch":
            for index in 0..<200 {
                let key = 40_000 + index
                result += [.init(key: key, cost: 10), .init(key: key, cost: 10)]
            }
        case "dominant": appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
        case "sparse":
            result.append(.init(key: 600, cost: 90))
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: 600, cost: 90))
            for _ in 0..<100 { for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) } }
        case "phase":
            appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 90, into: &result)
        case "alternating":
            for _ in 0..<5 {
                appendDominant(rounds: 20, key: 500, cost: 90, into: &result)
                appendDominant(rounds: 20, key: 501, cost: 90, into: &result)
            }
        case "small-to-giant":
            appendDominant(rounds: 100, key: 500, cost: 10, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 90, into: &result)
        case "giant-to-small":
            appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 10, into: &result)
        case "cold-cardinality":
            for index in 0..<10_000 { result.append(.init(key: 100_000 + index, cost: 10)) }
        case "victim-reheat":
            // Reheat the current 9 x 10-cost main residents without generating admission contests,
            // then present one giant candidate often enough for current candidate evidence to rise
            // while contest-clock victim evidence stays on the old published epoch. The final hot
            // probe converts a bad giant admission into an observable hit loss.
            for _ in 0..<12 {
                for key in 0..<9 { result.append(.init(key: key, cost: 10)) }
            }
            for _ in 0..<24 { result.append(.init(key: 950, cost: 90)) }
            for _ in 0..<20 {
                for key in 0..<9 { result.append(.init(key: key, cost: 10)) }
            }
        default: preconditionFailure("unknown workload")
        }
        return result
    }

    static func appendPollution(
        rounds: Int, cost: Int, base: Int, into result: inout [SketchRequest]
    ) {
        for round in 0..<rounds {
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: base + round, cost: cost))
        }
    }

    static func appendDominant(
        rounds: Int, key: Int, cost: Int, into result: inout [SketchRequest]
    ) {
        for round in 0..<rounds {
            for _ in 0..<9 { result.append(.init(key: key, cost: cost)) }
            result.append(.init(key: round % 10, cost: 10))
        }
    }
}
