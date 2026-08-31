import AkashicMemory
import Foundation

private enum SIEVESecondTouchSurvivalBehavior: String, Codable, CaseIterable {
    /// Observe resident membership without granting SIEVE's visited second chance and never
    /// reinsert on miss. This isolates raw residency lifetime under the competing hot workload.
    case passiveMembership = "passive-membership"
    /// Use a real hit (therefore granting visited protection), but do not reinsert after a miss.
    /// This isolates retention-promotion feedback from miss-reinsert feedback.
    case visitNoReinsert = "visit-no-reinsert"
    /// Normal request semantics: a resident second request grants visited protection; a miss
    /// reinserts the object and therefore contributes additional endogenous cache churn.
    case requestReinsert = "request-reinsert"
}

private enum SIEVESecondTouchSurvivalTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

private struct SIEVESecondTouchSurvivalResidentShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int

    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

private struct SIEVESecondTouchSurvivalScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

private struct SIEVESecondTouchSurvivalCase: Codable {
    let residentShape: String
    let topology: String
    let coreReuseStride: Int
    let warmReuseStride: Int
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let interveningNewScanObjects: Int
    let interveningNewScanBytes: Int
    let behavior: String
    let warmupRounds: Int
    let measurementRounds: Int

    let coreRequestBytes: Int
    let coreHitBytes: Int
    let coreMissBytes: Int
    let coreByteHitRatio: Double
    let coreRefillBytes: Int

    let warmRequestBytes: Int
    let warmHitBytes: Int
    let warmMissBytes: Int
    let warmByteHitRatio: Double
    let warmRefillBytes: Int

    let scanSecondRequestBytes: Int
    let scanSecondHitBytes: Int
    let scanSecondMissBytes: Int
    let scanSecondByteHitRatio: Double
    let scanSecondReinsertBytes: Int

    let finalCost: Int
    let finalCount: Int
}

private struct SIEVESecondTouchSurvivalSummary: Codable {
    let behavior: String
    let scanObjectCost: Int
    let interveningNewScanObjects: Int
    let interveningNewScanBytes: Int
    let caseCount: Int
    let coreMissCaseCount: Int
    let warmMissCaseCount: Int
    let minimumCoreByteHitRatio: Double
    let minimumWarmByteHitRatio: Double
    let minimumScanSecondByteHitRatio: Double
    let maximumScanSecondByteHitRatio: Double
    let meanCoreByteHitRatio: Double
    let meanWarmByteHitRatio: Double
    let meanScanSecondByteHitRatio: Double
    let maximumScanSecondReinsertBytes: Int
}

private struct SIEVESecondTouchSurvivalReport: Codable {
    struct Claims: Codable {
        let cachePolicyMechanismEvaluated: Bool
        let productionPolicyRecommendation: Bool
        let formalPerformance: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let fillerBytes: Int
    let residentShapeNames: [String]
    let topologies: [String]
    let coreReuseStrides: [Int]
    let warmReuseStrides: [Int]
    let scanShapes: [[String: Int]]
    let interveningNewScanObjectCounts: [Int]
    let behaviors: [String]
    let warmupRounds: Int
    let measurementRounds: Int
    let cases: [SIEVESecondTouchSurvivalCase]
    let summaries: [SIEVESecondTouchSurvivalSummary]
    let allMeasurementVolumesBalanced: Bool
    let passiveObservationNeverReinserted: Bool
    let visitNoReinsertNeverReinserted: Bool
    let requestReinsertAccountingExact: Bool
    let allResidentCostsWithinLimit: Bool
    let claims: Claims
}

enum MemorySIEVESecondTouchSurvivalProbe {
    private static let costLimit = 1_024
    private static let fillerObjectCount = 128
    private static let fillerObjectCost = 4
    private static let warmupRounds = 64
    private static let measurementRounds = 64
    private static let fillerBase = 0
    private static let warmBase = 100_000
    private static let coreBase = 200_000
    private static let scanBase = 1_000_000

    private static let residentShapes = [
        SIEVESecondTouchSurvivalResidentShape(
            name: "uniform-4",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVESecondTouchSurvivalResidentShape(
            name: "medium-16",
            coreObjectCount: 16,
            coreObjectCost: 16,
            warmObjectCount: 16,
            warmObjectCost: 16
        ),
        SIEVESecondTouchSurvivalResidentShape(
            name: "large-core-64",
            coreObjectCount: 4,
            coreObjectCost: 64,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVESecondTouchSurvivalResidentShape(
            name: "large-warm-64",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 4,
            warmObjectCost: 64
        ),
    ]
    private static let coreReuseStrides = [1, 4, 16]
    private static let warmReuseStrides = [2, 8]
    private static let scanShapes = [
        SIEVESecondTouchSurvivalScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVESecondTouchSurvivalScanShape(objectCost: 64, objectsPerRound: 4),
    ]
    private static let interveningNewScanObjectCounts = [0, 1, 2, 4, 8, 16, 32]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })
        precondition(warmupRounds.isMultiple(of: 16))
        precondition(interveningNewScanObjectCounts.max()! < warmupRounds * 4)

        var cases: [SIEVESecondTouchSurvivalCase] = []
        for shape in residentShapes {
            for topology in SIEVESecondTouchSurvivalTopology.allCases {
                for coreReuseStride in coreReuseStrides {
                    for warmReuseStride in warmReuseStrides {
                        for scanShape in scanShapes {
                            for interveningObjects in interveningNewScanObjectCounts {
                                for behavior in SIEVESecondTouchSurvivalBehavior.allCases {
                                    cases.append(
                                        runCase(
                                            shape: shape,
                                            topology: topology,
                                            coreReuseStride: coreReuseStride,
                                            warmReuseStride: warmReuseStride,
                                            scanShape: scanShape,
                                            interveningObjects: interveningObjects,
                                            behavior: behavior
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        precondition(cases.count == 2_016)

        let expectedSecondBytes = measurementRounds * 256
        let allMeasurementVolumesBalanced = cases.allSatisfy { row in
            row.coreRequestBytes == (measurementRounds / row.coreReuseStride) * 256
                && row.warmRequestBytes == (measurementRounds / row.warmReuseStride) * 256
                && row.scanSecondRequestBytes == expectedSecondBytes
                && row.scanSecondHitBytes + row.scanSecondMissBytes == row.scanSecondRequestBytes
        }
        let passiveObservationNeverReinserted = cases
            .filter { $0.behavior == SIEVESecondTouchSurvivalBehavior.passiveMembership.rawValue }
            .allSatisfy { $0.scanSecondReinsertBytes == 0 }
        let visitNoReinsertNeverReinserted = cases
            .filter { $0.behavior == SIEVESecondTouchSurvivalBehavior.visitNoReinsert.rawValue }
            .allSatisfy { $0.scanSecondReinsertBytes == 0 }
        let requestReinsertAccountingExact = cases
            .filter { $0.behavior == SIEVESecondTouchSurvivalBehavior.requestReinsert.rawValue }
            .allSatisfy { $0.scanSecondReinsertBytes == $0.scanSecondMissBytes }
        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }

        var summaries: [SIEVESecondTouchSurvivalSummary] = []
        for behavior in SIEVESecondTouchSurvivalBehavior.allCases {
            for scanShape in scanShapes {
                for interveningObjects in interveningNewScanObjectCounts {
                    let rows = cases.filter {
                        $0.behavior == behavior.rawValue
                            && $0.scanObjectCost == scanShape.objectCost
                            && $0.interveningNewScanObjects == interveningObjects
                    }
                    precondition(rows.count == 48)
                    summaries.append(
                        SIEVESecondTouchSurvivalSummary(
                            behavior: behavior.rawValue,
                            scanObjectCost: scanShape.objectCost,
                            interveningNewScanObjects: interveningObjects,
                            interveningNewScanBytes: interveningObjects * scanShape.objectCost,
                            caseCount: rows.count,
                            coreMissCaseCount: rows.count(where: { $0.coreMissBytes > 0 }),
                            warmMissCaseCount: rows.count(where: { $0.warmMissBytes > 0 }),
                            minimumCoreByteHitRatio: rows.map(\.coreByteHitRatio).min() ?? 0,
                            minimumWarmByteHitRatio: rows.map(\.warmByteHitRatio).min() ?? 0,
                            minimumScanSecondByteHitRatio: rows.map(\.scanSecondByteHitRatio).min() ?? 0,
                            maximumScanSecondByteHitRatio: rows.map(\.scanSecondByteHitRatio).max() ?? 0,
                            meanCoreByteHitRatio: mean(rows.map(\.coreByteHitRatio)),
                            meanWarmByteHitRatio: mean(rows.map(\.warmByteHitRatio)),
                            meanScanSecondByteHitRatio: mean(rows.map(\.scanSecondByteHitRatio)),
                            maximumScanSecondReinsertBytes: rows.map(\.scanSecondReinsertBytes).max() ?? 0
                        )
                    )
                }
            }
        }

        let report = SIEVESecondTouchSurvivalReport(
            schemaVersion: 1,
            costLimit: costLimit,
            fillerBytes: fillerObjectCount * fillerObjectCost,
            residentShapeNames: residentShapes.map(\.name),
            topologies: SIEVESecondTouchSurvivalTopology.allCases.map(\.rawValue),
            coreReuseStrides: coreReuseStrides,
            warmReuseStrides: warmReuseStrides,
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            interveningNewScanObjectCounts: interveningNewScanObjectCounts,
            behaviors: SIEVESecondTouchSurvivalBehavior.allCases.map(\.rawValue),
            warmupRounds: warmupRounds,
            measurementRounds: measurementRounds,
            cases: cases,
            summaries: summaries,
            allMeasurementVolumesBalanced: allMeasurementVolumesBalanced,
            passiveObservationNeverReinserted: passiveObservationNeverReinserted,
            visitNoReinsertNeverReinserted: visitNoReinsertNeverReinserted,
            requestReinsertAccountingExact: requestReinsertAccountingExact,
            allResidentCostsWithinLimit: allResidentCostsWithinLimit,
            claims: .init(
                cachePolicyMechanismEvaluated: true,
                productionPolicyRecommendation: false,
                formalPerformance: false,
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
        guard allMeasurementVolumesBalanced,
            passiveObservationNeverReinserted,
            visitNoReinsertNeverReinserted,
            requestReinsertAccountingExact,
            allResidentCostsWithinLimit
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        shape: SIEVESecondTouchSurvivalResidentShape,
        topology: SIEVESecondTouchSurvivalTopology,
        coreReuseStride: Int,
        warmReuseStride: Int,
        scanShape: SIEVESecondTouchSurvivalScanShape,
        interveningObjects: Int,
        behavior: SIEVESecondTouchSurvivalBehavior
    ) -> SIEVESecondTouchSurvivalCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        let fillerKeys = (0..<fillerObjectCount).map { fillerBase + $0 }
        let warmKeys = (0..<shape.warmObjectCount).map { warmBase + $0 }
        let coreKeys = (0..<shape.coreObjectCount).map { coreBase + $0 }
        let residentCosts = Dictionary(
            uniqueKeysWithValues:
                fillerKeys.map { ($0, fillerObjectCost) }
                + warmKeys.map { ($0, shape.warmObjectCost) }
                + coreKeys.map { ($0, shape.coreObjectCost) }
        )
        for key in seedOrder(
            topology: topology,
            fillerKeys: fillerKeys,
            warmKeys: warmKeys,
            coreKeys: coreKeys
        ) {
            cache.insert(key, for: key, cost: residentCosts[key]!)
        }
        precondition(cache.currentCost == costLimit)
        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var uniqueScanObjectClock = 0
        var scheduledSecondTouches: [Int: [Int]] = [:]
        var nextScanKey = scanBase
        var measuring = false

        var coreRequestBytes = 0
        var coreHitBytes = 0
        var coreMissBytes = 0
        var coreRefillBytes = 0
        var warmRequestBytes = 0
        var warmHitBytes = 0
        var warmMissBytes = 0
        var warmRefillBytes = 0
        var scanSecondRequestBytes = 0
        var scanSecondHitBytes = 0
        var scanSecondMissBytes = 0
        var scanSecondReinsertBytes = 0

        func performSecondTouch(_ key: Int) {
            if measuring { scanSecondRequestBytes += scanShape.objectCost }
            let hit: Bool
            switch behavior {
            case .passiveMembership:
                hit = cache.resourceProbeValueWithoutVisit(for: key) != nil
            case .visitNoReinsert, .requestReinsert:
                hit = cache.value(for: key) != nil
            }
            if hit {
                if measuring { scanSecondHitBytes += scanShape.objectCost }
                return
            }
            if measuring { scanSecondMissBytes += scanShape.objectCost }
            guard behavior == .requestReinsert else { return }
            cache.insert(key, for: key, cost: scanShape.objectCost)
            if measuring { scanSecondReinsertBytes += scanShape.objectCost }
        }

        let totalRounds = warmupRounds + measurementRounds
        for round in 0..<totalRounds {
            measuring = round >= warmupRounds
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    if measuring { coreRequestBytes += shape.coreObjectCost }
                    if cache.value(for: key) != nil {
                        if measuring { coreHitBytes += shape.coreObjectCost }
                    } else {
                        if measuring { coreMissBytes += shape.coreObjectCost }
                        cache.insert(key, for: key, cost: shape.coreObjectCost)
                        if measuring { coreRefillBytes += shape.coreObjectCost }
                    }
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    if measuring { warmRequestBytes += shape.warmObjectCost }
                    if cache.value(for: key) != nil {
                        if measuring { warmHitBytes += shape.warmObjectCost }
                    } else {
                        if measuring { warmMissBytes += shape.warmObjectCost }
                        cache.insert(key, for: key, cost: shape.warmObjectCost)
                        if measuring { warmRefillBytes += shape.warmObjectCost }
                    }
                }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                cache.insert(key, for: key, cost: scanShape.objectCost)
                uniqueScanObjectClock += 1

                if interveningObjects == 0 {
                    performSecondTouch(key)
                } else {
                    scheduledSecondTouches[
                        uniqueScanObjectClock + interveningObjects,
                        default: []
                    ].append(key)
                }
                if let dueKeys = scheduledSecondTouches.removeValue(
                    forKey: uniqueScanObjectClock
                ) {
                    for dueKey in dueKeys { performSecondTouch(dueKey) }
                }
            }
        }

        return SIEVESecondTouchSurvivalCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            interveningNewScanObjects: interveningObjects,
            interveningNewScanBytes: interveningObjects * scanShape.objectCost,
            behavior: behavior.rawValue,
            warmupRounds: warmupRounds,
            measurementRounds: measurementRounds,
            coreRequestBytes: coreRequestBytes,
            coreHitBytes: coreHitBytes,
            coreMissBytes: coreMissBytes,
            coreByteHitRatio: Double(coreHitBytes) / Double(max(1, coreRequestBytes)),
            coreRefillBytes: coreRefillBytes,
            warmRequestBytes: warmRequestBytes,
            warmHitBytes: warmHitBytes,
            warmMissBytes: warmMissBytes,
            warmByteHitRatio: Double(warmHitBytes) / Double(max(1, warmRequestBytes)),
            warmRefillBytes: warmRefillBytes,
            scanSecondRequestBytes: scanSecondRequestBytes,
            scanSecondHitBytes: scanSecondHitBytes,
            scanSecondMissBytes: scanSecondMissBytes,
            scanSecondByteHitRatio: Double(scanSecondHitBytes)
                / Double(max(1, scanSecondRequestBytes)),
            scanSecondReinsertBytes: scanSecondReinsertBytes,
            finalCost: cache.currentCost,
            finalCount: cache.count
        )
    }

    private static func seedOrder(
        topology: SIEVESecondTouchSurvivalTopology,
        fillerKeys: [Int],
        warmKeys: [Int],
        coreKeys: [Int]
    ) -> [Int] {
        let all = fillerKeys + warmKeys + coreKeys
        switch topology {
        case .fillerWarmCore:
            return all
        case .shuffle73:
            return shuffled(all, seed: 73)
        }
    }

    private static func shuffled(_ input: [Int], seed: UInt64) -> [Int] {
        var result = input
        var state = seed
        guard result.count > 1 else { return result }
        for upper in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let index = Int(state % UInt64(upper + 1))
            result.swapAt(upper, index)
        }
        return result
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
