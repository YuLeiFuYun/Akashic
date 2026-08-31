import AkashicMemory
import Foundation

enum SIEVESecondTouchIdentityClass: String, Codable {
    case filler
    case warm
    case core
    case scan
}

enum SIEVESecondTouchSeedOrder: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case coreWarmFiller = "core-warm-filler"
    case shuffle17 = "shuffle-17"
    case shuffle73 = "shuffle-73"
}

struct SIEVESecondTouchResidentShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int

    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

struct SIEVESecondTouchScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

struct SIEVESecondTouchMode: Sendable {
    let name: String
    /// Bytes from later first-time scan insertions that must occur after this key's first insertion
    /// before its second request is issued. Second-request reinsertion bytes are intentionally not
    /// part of this clock; this is a unique-new-scan-pressure distance, not total cache churn.
    let interveningNewScanBytes: Int?
}

struct SIEVESecondTouchCase: Codable {
    let residentShape: String
    let topology: String
    let coreReuseStride: Int
    let warmReuseStride: Int
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let scanFirstTouchBytesPerRound: Int
    let secondTouchMode: String
    let scanSecondTouchInterveningNewScanBytes: Int?
    let scanSecondTouchInterveningNewScanCacheTurns: Double?
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
    let scanSecondByteHitRatio: Double?
    let shadowProofTracked: Bool
    let cumulativeCoreVictimBytesFromScanFirstInsert: Int?
    let cumulativeWarmVictimBytesFromScanFirstInsert: Int?
    let cumulativeFillerVictimBytesFromScanFirstInsert: Int?
    let cumulativePriorScanVictimBytesFromScanFirstInsert: Int?
    let cumulativeCoreVictimBytesFromScanSecondMiss: Int?
    let cumulativeWarmVictimBytesFromScanSecondMiss: Int?
    let cumulativeFillerVictimBytesFromScanSecondMiss: Int?
    let cumulativePriorScanVictimBytesFromScanSecondMiss: Int?
    let finalCoreResidentBytes: Int
    let finalWarmResidentBytes: Int
    let finalFillerResidentBytes: Int
    let finalScanResidentBytes: Int
    let finalCost: Int
    let finalCount: Int
    let forecastMatchedFinalResidents: Bool?
    let shadowCostExact: Bool?
    let incomingScanEverAppearedInOwnForecast: Bool?
}

struct SIEVESecondTouchDistanceSummary: Codable {
    let secondTouchMode: String
    let scanSecondTouchInterveningNewScanBytes: Int?
    let caseCount: Int
    let coreMissCaseCount: Int
    let warmMissCaseCount: Int
    let minimumCoreByteHitRatio: Double
    let minimumWarmByteHitRatio: Double
    let minimumScanSecondByteHitRatio: Double?
    let maximumScanSecondByteHitRatio: Double?
    let maximumCoreRefillBytes: Int
    let maximumWarmRefillBytes: Int
}

struct SIEVESecondTouchReport: Codable {
    struct Claims: Codable {
        let cachePolicyEvaluated: Bool
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
    let fillerObjectCount: Int
    let fillerObjectCost: Int
    let fillerBytes: Int
    let residentShapeNames: [String]
    let topologies: [String]
    let coreReuseStrides: [Int]
    let warmReuseStrides: [Int]
    let scanShapes: [[String: Int]]
    let secondTouchModes: [String]
    let warmupRounds: Int
    let measurementRounds: Int
    let cases: [SIEVESecondTouchCase]
    let shadowProofCases: [SIEVESecondTouchCase]
    let distanceSummaries: [SIEVESecondTouchDistanceSummary]
    let shadowProofCaseCount: Int
    let allMeasurementVolumesBalanced: Bool
    let allForecastsMatchedFinalResidents: Bool
    let allShadowCostsExact: Bool
    let noIncomingScanAppearedInOwnForecast: Bool
    let claims: Claims
}
enum MemorySIEVESecondTouchDistanceProbe {
    static let costLimit = 1_024
    static let fillerObjectCount = 128
    static let fillerObjectCost = 4
    static let warmupRounds = 64
    static let measurementRounds = 64
    static let fillerBase = 0
    static let warmBase = 100_000
    static let coreBase = 200_000
    static let scanBase = 1_000_000

    static let residentShapes = [
        SIEVESecondTouchResidentShape(
            name: "uniform-4",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVESecondTouchResidentShape(
            name: "medium-16",
            coreObjectCount: 16,
            coreObjectCost: 16,
            warmObjectCount: 16,
            warmObjectCost: 16
        ),
        SIEVESecondTouchResidentShape(
            name: "large-core-64",
            coreObjectCount: 4,
            coreObjectCost: 64,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVESecondTouchResidentShape(
            name: "large-warm-64",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 4,
            warmObjectCost: 64
        ),
    ]
    static let coreReuseStrides = [1, 4, 16, 32]
    static let warmReuseStrides = [2, 8, 32]
    static let scanShapes = [
        SIEVESecondTouchScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVESecondTouchScanShape(objectCost: 64, objectsPerRound: 4),
    ]
    static let secondTouchModes = [
        SIEVESecondTouchMode(
            name: "none",
            interveningNewScanBytes: nil
        ),
        SIEVESecondTouchMode(
            name: "gap-0-bytes",
            interveningNewScanBytes: 0
        ),
        SIEVESecondTouchMode(
            name: "gap-64-bytes",
            interveningNewScanBytes: 64
        ),
        SIEVESecondTouchMode(
            name: "gap-128-bytes",
            interveningNewScanBytes: 128
        ),
        SIEVESecondTouchMode(
            name: "gap-256-bytes",
            interveningNewScanBytes: 256
        ),
        SIEVESecondTouchMode(
            name: "gap-512-bytes",
            interveningNewScanBytes: 512
        ),
        SIEVESecondTouchMode(
            name: "gap-1024-bytes",
            interveningNewScanBytes: 1_024
        ),
        SIEVESecondTouchMode(
            name: "gap-2048-bytes",
            interveningNewScanBytes: 2_048
        ),
        SIEVESecondTouchMode(
            name: "gap-4096-bytes",
            interveningNewScanBytes: 4_096
        ),
    ]
    static let shadowProofShapeNames: Set<String> = ["uniform-4", "large-warm-64"]
    static let shadowProofTopologies: [SIEVESecondTouchSeedOrder] = [
        .fillerWarmCore, .shuffle73,
    ]
    static let shadowProofCoreReuseStride = 4
    static let shadowProofWarmReuseStride = 2

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })
        precondition(warmupRounds.isMultiple(of: 32))
        precondition(secondTouchModes.allSatisfy { mode in
            guard let bytes = mode.interveningNewScanBytes else { return true }
            return bytes >= 0
                && scanShapes.allSatisfy { bytes.isMultiple(of: $0.objectCost) }
                && bytes <= warmupRounds * 256
        })

        var cases: [SIEVESecondTouchCase] = []
        for shape in residentShapes {
            for topology in SIEVESecondTouchSeedOrder.allCases {
                for coreReuseStride in coreReuseStrides {
                    for warmReuseStride in warmReuseStrides {
                        for scanShape in scanShapes {
                            for mode in secondTouchModes {
                                cases.append(
                                    runCase(
                                        shape: shape,
                                        topology: topology,
                                        coreReuseStride: coreReuseStride,
                                        warmReuseStride: warmReuseStride,
                                        scanShape: scanShape,
                                        mode: mode,
                                        trackShadow: false
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        var shadowProofCases: [SIEVESecondTouchCase] = []
        for shape in residentShapes where shadowProofShapeNames.contains(shape.name) {
            for topology in shadowProofTopologies {
                for scanShape in scanShapes {
                    for mode in secondTouchModes {
                        shadowProofCases.append(
                            runCase(
                                shape: shape,
                                topology: topology,
                                coreReuseStride: shadowProofCoreReuseStride,
                                warmReuseStride: shadowProofWarmReuseStride,
                                scanShape: scanShape,
                                mode: mode,
                                trackShadow: true
                            )
                        )
                    }
                }
            }
        }

        precondition(cases.count == 3_456)
        precondition(shadowProofCases.count == 72)
        let expectedSecondRequestBytes = measurementRounds * 256
        let allMeasurementVolumesBalanced = cases.allSatisfy { row in
            let expectedCoreBytes = (measurementRounds / row.coreReuseStride) * 256
            let expectedWarmBytes = (measurementRounds / row.warmReuseStride) * 256
            let expectedScanSecondBytes = row.secondTouchMode == "none"
                ? 0 : expectedSecondRequestBytes
            return row.coreRequestBytes == expectedCoreBytes
                && row.warmRequestBytes == expectedWarmBytes
                && row.scanSecondRequestBytes == expectedScanSecondBytes
                && row.scanSecondHitBytes + row.scanSecondMissBytes == row.scanSecondRequestBytes
        }

        let distanceSummaries = secondTouchModes.map { summarize(cases: cases, mode: $0) }
        let report = SIEVESecondTouchReport(
            schemaVersion: 2,
            costLimit: costLimit,
            fillerObjectCount: fillerObjectCount,
            fillerObjectCost: fillerObjectCost,
            fillerBytes: fillerObjectCount * fillerObjectCost,
            residentShapeNames: residentShapes.map(\.name),
            topologies: SIEVESecondTouchSeedOrder.allCases.map(\.rawValue),
            coreReuseStrides: coreReuseStrides,
            warmReuseStrides: warmReuseStrides,
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            secondTouchModes: secondTouchModes.map(\.name),
            warmupRounds: warmupRounds,
            measurementRounds: measurementRounds,
            cases: cases,
            shadowProofCases: shadowProofCases,
            distanceSummaries: distanceSummaries,
            shadowProofCaseCount: shadowProofCases.count,
            allMeasurementVolumesBalanced: allMeasurementVolumesBalanced,
            allForecastsMatchedFinalResidents: shadowProofCases.allSatisfy {
                $0.forecastMatchedFinalResidents == true
            },
            allShadowCostsExact: shadowProofCases.allSatisfy {
                $0.shadowCostExact == true
            },
            noIncomingScanAppearedInOwnForecast: shadowProofCases.allSatisfy {
                $0.incomingScanEverAppearedInOwnForecast == false
            },
            claims: .init(
                cachePolicyEvaluated: true,
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
        guard report.allMeasurementVolumesBalanced,
            report.allForecastsMatchedFinalResidents,
            report.allShadowCostsExact,
            report.noIncomingScanAppearedInOwnForecast
        else { throw ProbeError.resourceSampleFailed }
    }
}
