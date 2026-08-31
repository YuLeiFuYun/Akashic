import AkashicMemory
import Foundation

private struct AdmissionCostDifferentialWitness: Codable {
    let costsFromHand: [Int]
    let ternaryStateFromHand: [Int]
    let incomingCost: Int
    let fixedPointVictims: [Int]
    let onePassVictims: [Int]
    let fixedPointReleasedCost: Int
    let onePassReleasedCost: Int
    let fixedPointExplicitRevocations: [Int]
    let onePassExplicitRevocations: [Int]
    let fixedPointTraceRecomputations: Int
}

private struct AdmissionCostDifferentialReport: Codable {
    let schemaVersion: Int
    let residentCount: Int
    let costAlphabet: [Int]
    let costLayoutCount: Int
    let ternaryStateCount: Int
    let totalCases: Int
    let victimSequenceMismatchCount: Int
    let releasedCostMismatchCount: Int
    let explicitRevocationMismatchCount: Int
    let maximumFixedPointTraceRecomputations: Int
    let smallestMismatch: AdmissionCostDifferentialWitness?
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

private struct AdmissionCostFixedPointResult {
    let victims: [Int]
    let releasedCost: Int
    let revocations: [Int]
    let recomputations: Int
}

private struct AdmissionCostOnePassResult {
    let victims: [Int]
    let releasedCost: Int
    let revocations: [Int]
}

enum MemoryAdmissionRevocationCostDifferentialProbe {
    private static let residentCount = 5
    private static let costAlphabet = [1, 2]

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let handOrder = try baseHandOrder()
        let costLayoutCount = intPow(costAlphabet.count, residentCount)
        let ternaryStateCount = intPow(3, residentCount)
        var totalCases = 0
        var victimMismatches = 0
        var releasedCostMismatches = 0
        var revocationMismatches = 0
        var maximumRecomputations = 0
        var smallestMismatch: AdmissionCostDifferentialWitness?

        for costEncoded in 0..<costLayoutCount {
            let costsFromHand = decodeCostLayout(costEncoded, digits: residentCount)
            let costsByKey = Dictionary(
                uniqueKeysWithValues: zip(handOrder, costsFromHand)
            )
            let totalResidentCost = costsFromHand.reduce(0, +)
            let maximumIncomingCost = min(totalResidentCost, 5)
            for stateEncoded in 0..<ternaryStateCount {
                let ternary = decodeTernary(stateEncoded, digits: residentCount)
                var visited = Set<Int>()
                var provisional = Set<Int>()
                for (position, state) in ternary.enumerated() {
                    let key = handOrder[position]
                    if state >= 1 { visited.insert(key) }
                    if state == 2 { provisional.insert(key) }
                }
                for incomingCost in 1...maximumIncomingCost {
                    totalCases += 1
                    let fixed = try fixedPoint(
                        handOrder: handOrder,
                        costsByKey: costsByKey,
                        costLimit: totalResidentCost,
                        visited: visited,
                        provisional: provisional,
                        incomingCost: incomingCost
                    )
                    let onePass = onePass(
                        handOrder: handOrder,
                        costsByKey: costsByKey,
                        visited: visited,
                        provisional: provisional,
                        incomingCost: incomingCost
                    )
                    maximumRecomputations = max(maximumRecomputations, fixed.recomputations)
                    let victimMismatch = fixed.victims != onePass.victims
                    let releasedMismatch = fixed.releasedCost != onePass.releasedCost
                    let revocationMismatch = fixed.revocations != onePass.revocations
                    if victimMismatch { victimMismatches += 1 }
                    if releasedMismatch { releasedCostMismatches += 1 }
                    if revocationMismatch { revocationMismatches += 1 }
                    if (victimMismatch || releasedMismatch || revocationMismatch),
                        smallestMismatch == nil
                    {
                        smallestMismatch = .init(
                            costsFromHand: costsFromHand,
                            ternaryStateFromHand: ternary,
                            incomingCost: incomingCost,
                            fixedPointVictims: fixed.victims,
                            onePassVictims: onePass.victims,
                            fixedPointReleasedCost: fixed.releasedCost,
                            onePassReleasedCost: onePass.releasedCost,
                            fixedPointExplicitRevocations: fixed.revocations,
                            onePassExplicitRevocations: onePass.revocations,
                            fixedPointTraceRecomputations: fixed.recomputations
                        )
                    }
                }
            }
        }

        let expectedTotal = costLayoutCount * ternaryStateCount * 5
        let checks: [String: Bool] = [
            "enumerated-complete-cost-x-visit-x-incoming-space": totalCases == expectedTotal,
            "victim-sequence-exact": victimMismatches == 0,
            "released-cost-exact": releasedCostMismatches == 0,
            "explicit-revocation-order-exact": revocationMismatches == 0,
            "fixed-point-finite-in-bounded-space": maximumRecomputations <= residentCount + 1,
        ]
        let observations: [String: Bool] = [
            "restart-fixed-point-collapses-to-one-final-hand-walk-with-cost-skew":
                victimMismatches == 0
                    && releasedCostMismatches == 0
                    && revocationMismatches == 0,
            "fixed-point-still-recomputes-multiple-traces-in-some-states":
                maximumRecomputations > 1,
        ]
        let report = AdmissionCostDifferentialReport(
            schemaVersion: 1,
            residentCount: residentCount,
            costAlphabet: costAlphabet,
            costLayoutCount: costLayoutCount,
            ternaryStateCount: ternaryStateCount,
            totalCases: totalCases,
            victimSequenceMismatchCount: victimMismatches,
            releasedCostMismatchCount: releasedCostMismatches,
            explicitRevocationMismatchCount: revocationMismatches,
            maximumFixedPointTraceRecomputations: maximumRecomputations,
            smallestMismatch: smallestMismatch,
            checks: checks,
            observations: observations,
            claims: [
                "onePassExactForExhaustiveN5Costs1Or2": true,
                "productionImplementationQualified": false,
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

    private static func fixedPoint(
        handOrder: [Int],
        costsByKey: [Int: Int],
        costLimit: Int,
        visited: Set<Int>,
        provisional: Set<Int>,
        incomingCost: Int
    ) throws -> AdmissionCostFixedPointResult {
        let cache = makeCache(
            handOrder: handOrder,
            costsByKey: costsByKey,
            costLimit: costLimit,
            visited: visited
        )
        var provisional = provisional
        var revocations: [Int] = []
        var recomputations = 0
        while true {
            let trace = cache.resourceProbeEvictionTrace(incomingCost: incomingCost)
            recomputations += 1
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
                releasedCost: trace.victims.reduce(0) { $0 + $1.cost },
                revocations: revocations,
                recomputations: recomputations
            )
        }
    }

    private static func onePass(
        handOrder: [Int],
        costsByKey: [Int: Int],
        visited: Set<Int>,
        provisional: Set<Int>,
        incomingCost: Int
    ) -> AdmissionCostOnePassResult {
        var ring = handOrder
        var visited = visited
        var cursor = 0
        var requiredCost = incomingCost
        var victims: [Int] = []
        var revocations: [Int] = []
        var releasedCost = 0
        while requiredCost > 0, !ring.isEmpty {
            let visitedCount = ring.reduce(into: 0) { count, key in
                if visited.contains(key) { count += 1 }
            }
            if visitedCount == ring.count
                && !ring.contains(where: provisional.contains)
            {
                for key in ring { visited.remove(key) }
            }
            if cursor >= ring.count { cursor = 0 }
            let key = ring[cursor]
            if visited.contains(key) {
                if provisional.contains(key) {
                    visited.remove(key)
                    revocations.append(key)
                    victims.append(key)
                    let cost = costsByKey[key] ?? 0
                    releasedCost += cost
                    requiredCost -= cost
                    ring.remove(at: cursor)
                    if cursor >= ring.count { cursor = 0 }
                } else {
                    visited.remove(key)
                    cursor += 1
                    if cursor >= ring.count { cursor = 0 }
                }
            } else {
                victims.append(key)
                let cost = costsByKey[key] ?? 0
                releasedCost += cost
                requiredCost -= cost
                ring.remove(at: cursor)
                if cursor >= ring.count { cursor = 0 }
            }
        }
        return .init(victims: victims, releasedCost: releasedCost, revocations: revocations)
    }

    private static func baseHandOrder() throws -> [Int] {
        let cache = MemoryCache<Int, Int>(costLimit: residentCount)
        for key in 0..<residentCount { cache.insert(key, for: key, cost: 1) }
        let order = cache.resourceProbeEvictionTrace(incomingCost: residentCount).victims.map(\.key)
        guard order.count == residentCount else {
            throw ProbeError.resourceSampleFailed
        }
        return order
    }

    private static func makeCache(
        handOrder: [Int],
        costsByKey: [Int: Int],
        costLimit: Int,
        visited: Set<Int>
    ) -> MemoryCache<Int, Int> {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        for key in 0..<residentCount {
            cache.insert(key, for: key, cost: costsByKey[key] ?? 1)
        }
        precondition(
            cache.resourceProbeEvictionTrace(incomingCost: costLimit).victims.map(\.key)
                == handOrder
        )
        for key in visited { precondition(cache.resourceProbeMarkVisited(for: key)) }
        return cache
    }

    private static func decodeCostLayout(_ value: Int, digits: Int) -> [Int] {
        var value = value
        var result = [Int](repeating: costAlphabet[0], count: digits)
        for index in 0..<digits {
            result[index] = costAlphabet[value % costAlphabet.count]
            value /= costAlphabet.count
        }
        return result
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
