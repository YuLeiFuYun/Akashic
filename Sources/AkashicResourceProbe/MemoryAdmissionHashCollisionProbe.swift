import Foundation

private struct CollisionCaseResult: Codable {
    let hashMode: String
    let estimator: String
    let ghostCapacity: Int
    let workload: String
    let requests: Int
    let hits: Int
    let falseAdmits: Int
    let falseRejects: Int
    let admissionContests: Int
    let agingPasses: Int
    let maximumCounter: Int
    let counterPayloadBytes: Int
    let maximumGhostEntries: Int
    let ghostShallowPayloadBytes: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
    let coherentExactComparisons: Int
    let sketchFallbackComparisons: Int
    let fallbackMissingCandidateComparisons: Int
    let fallbackMissingVictimComparisons: Int
    let maximumMissingVictimCount: Int
    let residentMismatches: Int
}

private struct CollisionDecisionControl: Codable {
    let estimator: String
    let ghostCapacity: Int
    let pressured: Bool
    let fingerprintsIdentical: Bool
    let exactCandidate: Int
    let exactVictim: Int
    let estimatedCandidate: Int
    let estimatedVictim: Int
    let exactDecision: Bool
    let policyDecision: Bool
    let ghostEntryCount: Int
}

private struct CollisionKeyPayloadControl: Codable {
    let ghostEntries: Int
    let payloadBytesPerKey: Int
    let knownOwnedKeyPayloadBytes: Int
    let shallowKeyStructBytes: Int
    let dictionaryEntries: Int
    let fixedEntryCountBoundsArbitraryKeyBytes: Bool
}

private struct CollisionProbeReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let adversarialHashHardening: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
        let fullMemoryFootprintQualified: Bool
        let deterministicHashPersistence: Bool
    }

    let schemaVersion: Int
    let sketchRows: Int
    let sketchWidth: Int
    let contestHorizon: Int
    let dynamicCases: [CollisionCaseResult]
    let decisionControls: [CollisionDecisionControl]
    let keyPayloadControl: CollisionKeyPayloadControl
    let allResidentLookupsExact: Bool
    let allVictimBoundsPreserved: Bool
    let allGhostEntryBoundsPreserved: Bool
    let hashOnlyIdenticalHashLosesDecision: Bool
    let boundedGhostRecoversUnpressuredDecision: Bool
    let boundedGhostPressureCanLoseRepair: Bool
    let claims: Claims
}

private struct LargePayloadCollisionKey: Hashable, Sendable {
    let id: Int
    let payload: Data

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(0) }
}

enum MemoryAdmissionHashCollisionProbe {
    static func run() throws {
        let workloads = [
            "dominant", "phase", "cold-scan", "hundred-hot-pressure", "long-candidate",
        ]
        let configurations: [(CollisionHashMode, [CollisionEstimator])] = [
            (.normal, [.hashOnly, .exactGhost(capacity: 64), .oracleExactVictims]),
            (.constant, [
                .hashOnly,
                .exactGhost(capacity: 16),
                .exactGhost(capacity: 64),
                .exactGhost(capacity: 256),
                .oracleExactVictims,
            ]),
            (.twoCluster, [.hashOnly, .exactGhost(capacity: 64), .oracleExactVictims]),
        ]
        var cases: [CollisionCaseResult] = []
        for (hashMode, estimators) in configurations {
            for estimator in estimators {
                for workload in workloads {
                    cases.append(runCase(hashMode: hashMode, estimator: estimator, workload: workload))
                }
            }
        }

        let controls: [CollisionDecisionControl] = [
            decisionControl(estimator: .hashOnly, pressured: false),
            decisionControl(estimator: .exactGhost(capacity: 16), pressured: false),
            decisionControl(estimator: .exactGhost(capacity: 64), pressured: false),
            decisionControl(estimator: .exactGhost(capacity: 256), pressured: false),
            decisionControl(estimator: .exactGhost(capacity: 16), pressured: true),
            decisionControl(estimator: .exactGhost(capacity: 64), pressured: true),
            decisionControl(estimator: .exactGhost(capacity: 256), pressured: true),
        ]
        let payload = keyPayloadControl()
        let hashOnly = controls.first { $0.estimator == "hash-only" }!
        let unpressuredGhosts = controls.filter { $0.ghostCapacity > 0 && !$0.pressured }
        let pressuredGhosts = controls.filter { $0.ghostCapacity > 0 && $0.pressured }
        let report = CollisionProbeReport(
            schemaVersion: 1,
            sketchRows: CollisionSketch.rowCount,
            sketchWidth: 128,
            contestHorizon: 8,
            dynamicCases: cases,
            decisionControls: controls,
            keyPayloadControl: payload,
            allResidentLookupsExact: cases.allSatisfy { $0.residentMismatches == 0 },
            allVictimBoundsPreserved: cases.allSatisfy {
                $0.maximumVictimCount <= 9 && $0.maximumVictimCost <= 90
            },
            allGhostEntryBoundsPreserved: cases.allSatisfy {
                $0.ghostCapacity == 0 || $0.maximumGhostEntries <= $0.ghostCapacity
            },
            hashOnlyIdenticalHashLosesDecision: hashOnly.fingerprintsIdentical
                && hashOnly.exactDecision && !hashOnly.policyDecision,
            boundedGhostRecoversUnpressuredDecision: unpressuredGhosts.allSatisfy {
                $0.fingerprintsIdentical && $0.exactDecision && $0.policyDecision
            },
            boundedGhostPressureCanLoseRepair: pressuredGhosts.allSatisfy {
                $0.exactDecision && !$0.policyDecision
            },
            claims: .init(
                productionPolicy: false,
                adversarialHashHardening: false,
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

    private static func runCase(
        hashMode: CollisionHashMode,
        estimator: CollisionEstimator,
        workload: String
    ) -> CollisionCaseResult {
        let policy = CollisionAdmissionPolicy(hashMode: hashMode, estimator: estimator)
        policy.primeHotSet()
        let requests = trace(workload)
        var hits = 0
        for request in requests where policy.request(request) { hits += 1 }
        return CollisionCaseResult(
            hashMode: hashMode.rawValue,
            estimator: estimator.name,
            ghostCapacity: estimator.ghostCapacity,
            workload: workload,
            requests: requests.count,
            hits: hits,
            falseAdmits: policy.falseAdmits,
            falseRejects: policy.falseRejects,
            admissionContests: policy.admissionContests,
            agingPasses: policy.agingPasses,
            maximumCounter: policy.maximumCounter,
            counterPayloadBytes: policy.counterPayloadBytes,
            maximumGhostEntries: policy.maximumGhostEntries,
            ghostShallowPayloadBytes: policy.ghostShallowPayloadBytes,
            maximumVictimCount: policy.maximumVictimCount,
            maximumVictimCost: policy.maximumVictimCost,
            coherentExactComparisons: policy.coherentExactComparisons,
            sketchFallbackComparisons: policy.sketchFallbackComparisons,
            fallbackMissingCandidateComparisons: policy.fallbackMissingCandidateComparisons,
            fallbackMissingVictimComparisons: policy.fallbackMissingVictimComparisons,
            maximumMissingVictimCount: policy.maximumMissingVictimCount,
            residentMismatches: policy.residentMismatches
        )
    }

    private static func decisionControl(
        estimator: CollisionEstimator,
        pressured: Bool
    ) -> CollisionDecisionControl {
        let victim = CollisionKey(id: 1, mode: .constant)
        let candidate = CollisionKey(id: 2, mode: .constant)
        var sketch = CollisionSketch()
        var ghost: CollisionGhost?
        if case .exactGhost(let capacity) = estimator {
            ghost = CollisionGhost(capacity: capacity)
        }
        for _ in 0..<2 {
            sketch.increment(collisionFingerprint(victim))
            ghost?.observe(victim)
        }
        for _ in 0..<50 {
            sketch.increment(collisionFingerprint(candidate))
            ghost?.observe(candidate)
        }
        if pressured, estimator.ghostCapacity > 0 {
            for id in 0..<(estimator.ghostCapacity * 2 + 8) {
                let cold = CollisionKey(id: 10_000 + id, mode: .constant)
                sketch.increment(collisionFingerprint(cold))
                ghost?.observe(cold)
            }
        }
        func estimate(_ key: CollisionKey) -> Int {
            if let value = ghost?.estimate(key) { return value }
            return sketch.estimate(collisionFingerprint(key))
        }
        let candidateEstimate = estimate(candidate)
        let victimEstimate = estimate(victim)
        return CollisionDecisionControl(
            estimator: estimator.name,
            ghostCapacity: estimator.ghostCapacity,
            pressured: pressured,
            fingerprintsIdentical: collisionFingerprint(candidate) == collisionFingerprint(victim),
            exactCandidate: 50,
            exactVictim: 2,
            estimatedCandidate: candidateEstimate,
            estimatedVictim: victimEstimate,
            exactDecision: true,
            policyDecision: candidateEstimate > victimEstimate,
            ghostEntryCount: ghost?.entryCount ?? 0
        )
    }

    private static func keyPayloadControl() -> CollisionKeyPayloadControl {
        let entryCount = 64
        let payloadBytes = 4_096
        var dictionary: [LargePayloadCollisionKey: Int] = [:]
        for id in 0..<entryCount {
            let key = LargePayloadCollisionKey(
                id: id,
                payload: Data(repeating: UInt8(truncatingIfNeeded: id), count: payloadBytes)
            )
            dictionary[key] = id
        }
        return CollisionKeyPayloadControl(
            ghostEntries: entryCount,
            payloadBytesPerKey: payloadBytes,
            knownOwnedKeyPayloadBytes: entryCount * payloadBytes,
            shallowKeyStructBytes: entryCount * MemoryLayout<LargePayloadCollisionKey>.stride,
            dictionaryEntries: dictionary.count,
            fixedEntryCountBoundsArbitraryKeyBytes: false
        )
    }

    private static func trace(_ name: String) -> [CollisionRequest] {
        var result: [CollisionRequest] = []
        switch name {
        case "dominant":
            appendDominant(rounds: 100, id: 500, into: &result)
        case "phase":
            appendDominant(rounds: 60, id: 500, into: &result)
            appendDominant(rounds: 60, id: 501, into: &result)
        case "cold-scan":
            for round in 0..<500 {
                for hot in 0..<10 { result.append(.init(id: hot, cost: 10)) }
                result.append(.init(id: 10_000 + round, cost: 10))
            }
        case "hundred-hot-pressure":
            for cycle in 0..<20 {
                for id in 0..<100 { result.append(.init(id: 1_000 + id, cost: 10)) }
                for cold in 0..<50 {
                    result.append(.init(id: 20_000 + cycle * 50 + cold, cost: 10))
                }
            }
        case "long-candidate":
            for round in 0..<600 {
                result.append(.init(id: 500, cost: 90))
                if round % 4 == 0 { result.append(.init(id: round % 10, cost: 10)) }
            }
        default:
            preconditionFailure("unknown workload")
        }
        return result
    }

    private static func appendDominant(
        rounds: Int,
        id: Int,
        into result: inout [CollisionRequest]
    ) {
        for round in 0..<rounds {
            for _ in 0..<9 { result.append(.init(id: id, cost: 90)) }
            result.append(.init(id: round % 10, cost: 10))
        }
    }
}
