import AkashicMemory
import Foundation

private struct AdmissionOnePassWitness: Codable {
    let ternaryStateFromHand: [Int]
    let incomingCost: Int
    let fixedPointVictims: [Int]
    let onePassVictims: [Int]
    let fixedPointExplicitRevocations: [Int]
    let onePassExplicitRevocations: [Int]
    let fixedPointTraceRecomputations: Int
    let fixedPointEpochResetCount: Int
    let onePassEpochResetCount: Int
}

private struct AdmissionOnePassDifferentialReport: Codable {
    let schemaVersion: Int
    let residentCount: Int
    let totalCases: Int
    let victimSequenceMismatchCount: Int
    let explicitRevocationMismatchCount: Int
    let fullAgreementCount: Int
    let noOrdinaryVisitedCaseCount: Int
    let noOrdinaryVisitedMismatchCount: Int
    let maximumFixedPointTraceRecomputations: Int
    let smallestVictimMismatch: AdmissionOnePassWitness?
    let smallestRevocationMismatch: AdmissionOnePassWitness?
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

private struct AdmissionFixedPointOracle {
    let victims: [Int]
    let explicitRevocations: [Int]
    let traceRecomputations: Int
    let epochResetCount: Int
}

private struct AdmissionOnePassModel {
    let victims: [Int]
    let explicitRevocations: [Int]
    let epochResetCount: Int
}

enum MemoryAdmissionRevocationOnePassProbe {
    private static let residentCount = 8

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let handOrder = try baseHandOrder()
        var totalCases = 0
        var victimMismatches = 0
        var revocationMismatches = 0
        var fullAgreements = 0
        var noOrdinaryCases = 0
        var noOrdinaryMismatches = 0
        var maximumRecomputations = 0
        var smallestVictimMismatch: AdmissionOnePassWitness?
        var smallestRevocationMismatch: AdmissionOnePassWitness?

        let stateCount = intPow(3, residentCount)
        for encoded in 0..<stateCount {
            let ternary = decodeTernary(encoded, digits: residentCount)
            var visited = Set<Int>()
            var provisional = Set<Int>()
            var hasOrdinaryVisited = false
            for (position, state) in ternary.enumerated() {
                let key = handOrder[position]
                switch state {
                case 0:
                    break
                case 1:
                    visited.insert(key)
                    hasOrdinaryVisited = true
                case 2:
                    visited.insert(key)
                    provisional.insert(key)
                default:
                    preconditionFailure("invalid ternary digit")
                }
            }
            for incomingCost in 1...(residentCount / 2) {
                totalCases += 1
                if !hasOrdinaryVisited { noOrdinaryCases += 1 }
                let fixed = try fixedPointOracle(
                    handOrder: handOrder,
                    visited: visited,
                    provisional: provisional,
                    incomingCost: incomingCost
                )
                let onePass = onePassModel(
                    handOrder: handOrder,
                    visited: visited,
                    provisional: provisional,
                    incomingCost: incomingCost
                )
                maximumRecomputations = max(
                    maximumRecomputations,
                    fixed.traceRecomputations
                )
                let victimMismatch = fixed.victims != onePass.victims
                let revocationMismatch = fixed.explicitRevocations != onePass.explicitRevocations
                if victimMismatch {
                    victimMismatches += 1
                    if !hasOrdinaryVisited { noOrdinaryMismatches += 1 }
                }
                if revocationMismatch { revocationMismatches += 1 }
                if !victimMismatch && !revocationMismatch { fullAgreements += 1 }

                let witness = AdmissionOnePassWitness(
                    ternaryStateFromHand: ternary,
                    incomingCost: incomingCost,
                    fixedPointVictims: fixed.victims,
                    onePassVictims: onePass.victims,
                    fixedPointExplicitRevocations: fixed.explicitRevocations,
                    onePassExplicitRevocations: onePass.explicitRevocations,
                    fixedPointTraceRecomputations: fixed.traceRecomputations,
                    fixedPointEpochResetCount: fixed.epochResetCount,
                    onePassEpochResetCount: onePass.epochResetCount
                )
                if victimMismatch && smallestVictimMismatch == nil {
                    smallestVictimMismatch = witness
                }
                if revocationMismatch && smallestRevocationMismatch == nil {
                    smallestRevocationMismatch = witness
                }
            }
        }

        let checks: [String: Bool] = [
            "enumerated-complete-n8-ternary-x-four-costs":
                totalCases == stateCount * (residentCount / 2),
            "fixed-point-recomputations-are-bounded-in-this-finite-space":
                maximumRecomputations <= residentCount + 1,
            "one-pass-victim-sequence-matches-fixed-point-exhaustively":
                victimMismatches == 0,
            "one-pass-explicit-revocations-match-fixed-point-exhaustively":
                revocationMismatches == 0,
            "no-ordinary-visited-subset-has-no-victim-divergence":
                noOrdinaryMismatches == 0,
        ]
        let observations: [String: Bool] = [
            "restart-fixed-point-collapses-to-one-final-hand-walk-on-n8-unit-cost":
                victimMismatches == 0
                    && revocationMismatches == 0
                    && fullAgreements == totalCases,
            "fixed-point-can-recompute-more-than-once": maximumRecomputations > 1,
        ]
        let report = AdmissionOnePassDifferentialReport(
            schemaVersion: 1,
            residentCount: residentCount,
            totalCases: totalCases,
            victimSequenceMismatchCount: victimMismatches,
            explicitRevocationMismatchCount: revocationMismatches,
            fullAgreementCount: fullAgreements,
            noOrdinaryVisitedCaseCount: noOrdinaryCases,
            noOrdinaryVisitedMismatchCount: noOrdinaryMismatches,
            maximumFixedPointTraceRecomputations: maximumRecomputations,
            smallestVictimMismatch: smallestVictimMismatch,
            smallestRevocationMismatch: smallestRevocationMismatch,
            checks: checks,
            observations: observations,
            claims: [
                "onePassExactForExhaustiveN8UnitCost": true,
                "onePassExactForVariableCostOrArbitraryN": false,
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

    private static func baseHandOrder() throws -> [Int] {
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount {
            cache.insert(key, for: key, cost: 1)
        }
        let order = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        guard order.count == residentCount else {
            throw ProbeError.resourceSampleFailed
        }
        return order
    }

    private static func fixedPointOracle(
        handOrder: [Int],
        visited: Set<Int>,
        provisional: Set<Int>,
        incomingCost: Int
    ) throws -> AdmissionFixedPointOracle {
        let cache = makeCache(handOrder: handOrder, visited: visited)
        var provisional = provisional
        var revocations: [Int] = []
        var recomputations = 0
        var epochResets = 0
        while true {
            let trace = cache.resourceProbeEvictionTrace(incomingCost: incomingCost)
            recomputations += 1
            epochResets += trace.fullVisitedEpochResetCount
            if let key = trace.clearedVisitedKeys.first(where: provisional.contains) {
                guard cache.resourceProbeClearVisited(for: key) else {
                    throw ProbeError.resourceSampleFailed
                }
                provisional.remove(key)
                revocations.append(key)
                continue
            }
            return .init(
                victims: trace.victims.map(\.key),
                explicitRevocations: revocations,
                traceRecomputations: recomputations,
                epochResetCount: epochResets
            )
        }
    }

    private static func onePassModel(
        handOrder: [Int],
        visited: Set<Int>,
        provisional: Set<Int>,
        incomingCost: Int
    ) -> AdmissionOnePassModel {
        var ring = handOrder
        var visited = visited
        var cursor = 0
        var requiredCost = incomingCost
        var victims: [Int] = []
        var revocations: [Int] = []
        var epochResets = 0

        while requiredCost > 0, !ring.isEmpty {
            let visitedCount = ring.reduce(into: 0) { count, key in
                if visited.contains(key) { count += 1 }
            }
            if visitedCount == ring.count
                && !ring.contains(where: provisional.contains)
            {
                for key in ring { visited.remove(key) }
                epochResets += 1
            }
            if cursor >= ring.count { cursor = 0 }
            let key = ring[cursor]
            if visited.contains(key) {
                if provisional.contains(key) {
                    visited.remove(key)
                    revocations.append(key)
                    victims.append(key)
                    ring.remove(at: cursor)
                    requiredCost -= 1
                    if cursor >= ring.count { cursor = 0 }
                } else {
                    visited.remove(key)
                    cursor += 1
                    if cursor >= ring.count { cursor = 0 }
                }
            } else {
                victims.append(key)
                ring.remove(at: cursor)
                requiredCost -= 1
                if cursor >= ring.count { cursor = 0 }
            }
        }
        return .init(
            victims: victims,
            explicitRevocations: revocations,
            epochResetCount: epochResets
        )
    }

    private static func makeCache(
        handOrder: [Int],
        visited: Set<Int>
    ) -> MemoryCache<Int, Int> {
        // Hand order is determined by insertion order for this no-eviction fixture. Reconstruct the
        // same cache from the key set, then verify topology rather than assuming the ring layout.
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount { cache.insert(key, for: key, cost: 1) }
        precondition(
            cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
                == handOrder
        )
        for key in visited {
            precondition(cache.resourceProbeMarkVisited(for: key))
        }
        return cache
    }

    private static func decodeTernary(_ value: Int, digits: Int) -> [Int] {
        var value = value
        var result = [Int](repeating: 0, count: digits)
        for index in 0..<digits {
            result[index] = value % 3
            value /= 3
        }
        return result
    }

    private static func intPow(_ base: Int, _ exponent: Int) -> Int {
        var result = 1
        for _ in 0..<exponent { result *= base }
        return result
    }
}
