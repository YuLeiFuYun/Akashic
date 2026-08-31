import AkashicMemory
import Foundation

private struct AdmissionRevocationBudgetPoint: Codable {
    let budget: Int
    let exactSemanticsReachableInOneInsertion: Bool
}

private struct AdmissionRevocationComplexityCase: Codable {
    let residentCount: Int
    let incomingCost: Int
    let deliberatelyUnvisitedKey: Int
    let initialProvisionalCount: Int
    let exactRevocationCount: Int
    let exactTraceRecomputationCount: Int
    let exactFinalVictimCount: Int
    let exactFinalVictimCost: Int
    let batchRevocationCount: Int
    let batchOverRevocationCount: Int
    let exactVisitedResidentCountAfterInsert: Int
    let batchVisitedResidentCountAfterInsert: Int
    let exactNextOneUnitVictim: Int?
    let batchNextOneUnitVictim: Int?
    let exactNextPressurePrefersNewCandidate: Bool
    let batchNextPressureConsumesIncumbent: Bool
    let minimumExactRevocationBudget: Int
    let fixedBudgets: [AdmissionRevocationBudgetPoint]
}

private struct AdmissionRevocationComplexityReport: Codable {
    let schemaVersion: Int
    let cases: [AdmissionRevocationComplexityCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum MemoryAdmissionRevocationComplexityProbe {
    private static let sizes = [8, 16, 32, 64, 128]
    private static let fixedBudgets = [1, 2, 4, 8, 16]

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let rows = try sizes.map(runCase)
        let checks: [String: Bool] = [
            "fixture-avoids-full-visited-epoch-reset": rows.allSatisfy {
                $0.initialProvisionalCount == $0.residentCount - 1
            },
            "exact-revocations-scale-as-incoming-cost-minus-one": rows.allSatisfy {
                $0.exactRevocationCount == $0.incomingCost - 1
            },
            "exact-recomputes-once-per-revocation-plus-final-trace": rows.allSatisfy {
                $0.exactTraceRecomputationCount == $0.exactRevocationCount + 1
            },
            "batch-revokes-entire-provisional-set": rows.allSatisfy {
                $0.batchRevocationCount == $0.residentCount - 1
            },
            "batch-over-revocation-scales-as-half-resident-count": rows.allSatisfy {
                $0.batchOverRevocationCount == $0.residentCount / 2
            },
            "exact-and-batch-release-same-immediate-cost": rows.allSatisfy {
                $0.exactFinalVictimCount == $0.incomingCost
                    && $0.exactFinalVictimCost == $0.incomingCost
            },
            "future-one-unit-pressure-diverges": rows.allSatisfy {
                $0.exactNextPressurePrefersNewCandidate
                    && $0.batchNextPressureConsumesIncumbent
                    && $0.exactNextOneUnitVictim != $0.batchNextOneUnitVictim
            },
        ]
        let observations: [String: Bool] = [
            "no-fixed-small-revocation-budget-preserves-one-shot-exact-semantics":
                rows.last.map { row in
                    fixedBudgets.allSatisfy { budget in
                        budget < row.minimumExactRevocationBudget
                    }
                } ?? false,
            "one-pass-batch-bounds-trace-count-by-over-revoking-live-second-chances":
                rows.allSatisfy {
                    $0.batchVisitedResidentCountAfterInsert == 0
                        && $0.exactVisitedResidentCountAfterInsert == $0.residentCount / 2
                },
            "work-and-semantic-damage-grow-with-cache-cardinality":
                zip(rows, rows.dropFirst()).allSatisfy { lhs, rhs in
                    rhs.exactTraceRecomputationCount > lhs.exactTraceRecomputationCount
                        && rhs.batchOverRevocationCount > lhs.batchOverRevocationCount
                },
        ]
        let report = AdmissionRevocationComplexityReport(
            schemaVersion: 1,
            cases: rows,
            checks: checks,
            observations: observations,
            claims: [
                "fixedPointOneShotBounded": false,
                "batchSemanticallyEquivalentToFixedPoint": false,
                "handLocalLeaseRevocationMotivated": true,
                "productionPolicyRecommendation": false,
                "formalPerformance": false,
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

    private static func runCase(_ residentCount: Int) throws -> AdmissionRevocationComplexityCase {
        precondition(residentCount.isMultiple(of: 2))
        let incomingCost = residentCount / 2
        let incomingKey = residentCount

        let exactSeed = try seededCache(residentCount: residentCount)
        let exact = exactSeed.cache
        var exactProvisional = exactSeed.provisional
        var exactRevocations = 0
        var exactRecomputations = 0
        var finalTrace: MemoryCacheEvictionTrace<Int>?
        while true {
            let trace = exact.resourceProbeEvictionTrace(incomingCost: incomingCost)
            exactRecomputations += 1
            if let provisionalKey = trace.clearedVisitedKeys.first(where: exactProvisional.contains) {
                guard exact.resourceProbeClearVisited(for: provisionalKey) else {
                    throw ProbeError.resourceSampleFailed
                }
                exactProvisional.remove(provisionalKey)
                exactRevocations += 1
                continue
            }
            finalTrace = trace
            break
        }
        guard let finalTrace else { throw ProbeError.resourceSampleFailed }
        let exactVictimCost = finalTrace.victims.reduce(0) { $0 + $1.cost }
        exact.insert(incomingKey, for: incomingKey, cost: incomingCost)
        let exactVisitState = exact.resourceProbeVisitState()
        let exactNextVictim = exact.resourceProbeEvictionTrace(incomingCost: 1).victims.first?.key

        let batchSeed = try seededCache(residentCount: residentCount)
        let batch = batchSeed.cache
        var batchProvisional = batchSeed.provisional
        let batchTrace = batch.resourceProbeEvictionTrace(incomingCost: incomingCost)
        var batchRevocations = 0
        for key in batchTrace.clearedVisitedKeys where batchProvisional.contains(key) {
            guard batch.resourceProbeClearVisited(for: key) else {
                throw ProbeError.resourceSampleFailed
            }
            batchProvisional.remove(key)
            batchRevocations += 1
        }
        batch.insert(incomingKey, for: incomingKey, cost: incomingCost)
        let batchVisitState = batch.resourceProbeVisitState()
        let batchNextVictim = batch.resourceProbeEvictionTrace(incomingCost: 1).victims.first?.key

        return AdmissionRevocationComplexityCase(
            residentCount: residentCount,
            incomingCost: incomingCost,
            deliberatelyUnvisitedKey: exactSeed.deliberatelyUnvisitedKey,
            initialProvisionalCount: exactSeed.provisional.count,
            exactRevocationCount: exactRevocations,
            exactTraceRecomputationCount: exactRecomputations,
            exactFinalVictimCount: finalTrace.victims.count,
            exactFinalVictimCost: exactVictimCost,
            batchRevocationCount: batchRevocations,
            batchOverRevocationCount: batchRevocations - exactRevocations,
            exactVisitedResidentCountAfterInsert: exactVisitState.visitedCount,
            batchVisitedResidentCountAfterInsert: batchVisitState.visitedCount,
            exactNextOneUnitVictim: exactNextVictim,
            batchNextOneUnitVictim: batchNextVictim,
            exactNextPressurePrefersNewCandidate: exactNextVictim == incomingKey,
            batchNextPressureConsumesIncumbent:
                batchNextVictim.map { $0 >= 0 && $0 < residentCount } ?? false,
            minimumExactRevocationBudget: exactRevocations,
            fixedBudgets: fixedBudgets.map {
                AdmissionRevocationBudgetPoint(
                    budget: $0,
                    exactSemanticsReachableInOneInsertion: $0 >= exactRevocations
                )
            }
        )
    }

    private struct SeededCache {
        let cache: MemoryCache<Int, Int>
        let provisional: Set<Int>
        let deliberatelyUnvisitedKey: Int
    }

    private static func seededCache(residentCount: Int) throws -> SeededCache {
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(key, for: key, cost: 1)
        }
        let handOrder = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        guard handOrder.count == residentCount,
            let deliberatelyUnvisitedKey = handOrder.last
        else { throw ProbeError.resourceSampleFailed }
        var provisional = Set<Int>()
        provisional.reserveCapacity(residentCount - 1)
        for key in handOrder.dropLast() {
            guard cache.resourceProbeMarkVisited(for: key) else {
                throw ProbeError.resourceSampleFailed
            }
            provisional.insert(key)
        }
        let state = cache.resourceProbeVisitState()
        guard state.visitedCount == residentCount - 1 else {
            throw ProbeError.resourceSampleFailed
        }
        return .init(
            cache: cache,
            provisional: provisional,
            deliberatelyUnvisitedKey: deliberatelyUnvisitedKey
        )
    }
}
