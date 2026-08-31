import AkashicMemory
import Foundation

private enum SIEVEHotRefillRecoveryMode: String, Codable, CaseIterable {
    case normal = "normal-unvisited-refill"
    case oracleVisited = "oracle-hot-refill-visited"
}

private enum SIEVEHotRefillPostScanMode: String, Codable, CaseIterable {
    case hotOnly = "hot-only"
    case oneTouch = "one-touch-scan"
    case delayedSecond128 = "second-touch-gap-128-objects"
}

private enum SIEVEHotRefillTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

private struct SIEVEHotRefillResidentShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int

    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

private struct SIEVEHotRefillScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

private struct SIEVEHotRefillRecoveryCase: Codable {
    let residentShape: String
    let topology: String
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let refillMode: String
    let postScanMode: String
    let prePollutionRounds: Int
    let postRecoveryRounds: Int
    let finalWindowRounds: Int

    let prePollutionCoreByteHitRatio: Double
    let prePollutionWarmByteHitRatio: Double
    let postCoreByteHitRatio: Double
    let postWarmByteHitRatio: Double
    let finalWindowCoreByteHitRatio: Double
    let finalWindowWarmByteHitRatio: Double
    let postCoreMissBytes: Int
    let postWarmMissBytes: Int
    let firstPostCoreMissRound: Int?
    let firstPostWarmMissRound: Int?
    let lastPostCoreMissRound: Int?
    let lastPostWarmMissRound: Int?
    let postSecondRequestBytes: Int
    let postSecondHitBytes: Int
    let postSecondMissBytes: Int
    let postSecondByteHitRatio: Double?
    let finalCost: Int
    let finalCount: Int
}

private struct SIEVEHotRefillRecoveryReport: Codable {
    struct Claims: Codable {
        let hotRefillRecoveryMechanismEvaluated: Bool
        let oracleProductionPolicy: Bool
        let wallClockPerformance: Bool
        let admissionRecommendation: Bool
        let diskSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let coreReuseStride: Int
    let warmReuseStride: Int
    let prePollutionRounds: Int
    let postRecoveryRounds: Int
    let finalWindowRounds: Int
    let delayedSecondGapObjects: Int
    let cases: [SIEVEHotRefillRecoveryCase]
    let allResidentCostsWithinLimit: Bool
    let hotOnlyAlwaysRecovers: Bool
    let oracleNeverWorseInFinalWindow: Bool
    let claims: Claims
}

enum MemorySIEVEHotRefillRecoveryProbe {
    private static let costLimit = 1_024
    private static let fillerObjectCount = 128
    private static let fillerObjectCost = 4
    private static let fillerBase = 0
    private static let warmBase = 100_000
    private static let coreBase = 200_000
    private static let scanBase = 1_000_000
    private static let coreReuseStride = 4
    private static let warmReuseStride = 2
    private static let prePollutionRounds = 64
    private static let postRecoveryRounds = 128
    private static let finalWindowRounds = 16
    private static let delayedSecondGapObjects = 128

    private static let residentShapes = [
        SIEVEHotRefillResidentShape(
            name: "uniform-4",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVEHotRefillResidentShape(
            name: "medium-16",
            coreObjectCount: 16,
            coreObjectCost: 16,
            warmObjectCount: 16,
            warmObjectCost: 16
        ),
        SIEVEHotRefillResidentShape(
            name: "large-core-64",
            coreObjectCount: 4,
            coreObjectCost: 64,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVEHotRefillResidentShape(
            name: "large-warm-64",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 4,
            warmObjectCost: 64
        ),
    ]
    private static let scanShapes = [
        SIEVEHotRefillScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVEHotRefillScanShape(objectCost: 64, objectsPerRound: 4),
    ]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })
        precondition(postRecoveryRounds.isMultiple(of: coreReuseStride))

        var cases: [SIEVEHotRefillRecoveryCase] = []
        for shape in residentShapes {
            for topology in SIEVEHotRefillTopology.allCases {
                for scanShape in scanShapes {
                    for postScanMode in SIEVEHotRefillPostScanMode.allCases {
                        for refillMode in SIEVEHotRefillRecoveryMode.allCases {
                            cases.append(
                                runCase(
                                    shape: shape,
                                    topology: topology,
                                    scanShape: scanShape,
                                    postScanMode: postScanMode,
                                    refillMode: refillMode
                                )
                            )
                        }
                    }
                }
            }
        }
        precondition(cases.count == 96)

        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }
        let hotOnlyAlwaysRecovers = cases
            .filter { $0.postScanMode == SIEVEHotRefillPostScanMode.hotOnly.rawValue }
            .allSatisfy {
                $0.finalWindowCoreByteHitRatio == 1 && $0.finalWindowWarmByteHitRatio == 1
            }

        func pairKey(_ row: SIEVEHotRefillRecoveryCase) -> String {
            [
                row.residentShape,
                row.topology,
                String(row.scanObjectCost),
                row.postScanMode,
            ].joined(separator: "|")
        }
        let grouped = Dictionary(grouping: cases, by: pairKey)
        let oracleNeverWorseInFinalWindow = grouped.values.allSatisfy { rows in
            guard
                let normal = rows.first(where: {
                    $0.refillMode == SIEVEHotRefillRecoveryMode.normal.rawValue
                }),
                let oracle = rows.first(where: {
                    $0.refillMode == SIEVEHotRefillRecoveryMode.oracleVisited.rawValue
                })
            else { return false }
            return oracle.finalWindowCoreByteHitRatio >= normal.finalWindowCoreByteHitRatio
                && oracle.finalWindowWarmByteHitRatio >= normal.finalWindowWarmByteHitRatio
        }

        let report = SIEVEHotRefillRecoveryReport(
            schemaVersion: 1,
            costLimit: costLimit,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            prePollutionRounds: prePollutionRounds,
            postRecoveryRounds: postRecoveryRounds,
            finalWindowRounds: finalWindowRounds,
            delayedSecondGapObjects: delayedSecondGapObjects,
            cases: cases,
            allResidentCostsWithinLimit: allResidentCostsWithinLimit,
            hotOnlyAlwaysRecovers: hotOnlyAlwaysRecovers,
            oracleNeverWorseInFinalWindow: oracleNeverWorseInFinalWindow,
            claims: .init(
                hotRefillRecoveryMechanismEvaluated: true,
                oracleProductionPolicy: false,
                wallClockPerformance: false,
                admissionRecommendation: false,
                diskSemantics: false,
                foveaBusinessSemantics: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allResidentCostsWithinLimit,
            hotOnlyAlwaysRecovers,
            oracleNeverWorseInFinalWindow
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        shape: SIEVEHotRefillResidentShape,
        topology: SIEVEHotRefillTopology,
        scanShape: SIEVEHotRefillScanShape,
        postScanMode: SIEVEHotRefillPostScanMode,
        refillMode: SIEVEHotRefillRecoveryMode
    ) -> SIEVEHotRefillRecoveryCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        let fillerKeys = (0..<fillerObjectCount).map { fillerBase + $0 }
        let warmKeys = (0..<shape.warmObjectCount).map { warmBase + $0 }
        let coreKeys = (0..<shape.coreObjectCount).map { coreBase + $0 }
        let costs = Dictionary(
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
            cache.insert(key, for: key, cost: costs[key]!)
        }
        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var nextScanKey = scanBase
        var preCoreRequest = 0
        var preCoreHit = 0
        var preWarmRequest = 0
        var preWarmHit = 0

        // Establish the polluted attractor with the known hostile immediate-second-touch phase.
        for round in 0..<prePollutionRounds {
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    preCoreRequest += shape.coreObjectCost
                    if cache.value(for: key) != nil { preCoreHit += shape.coreObjectCost }
                    else { cache.insert(key, for: key, cost: shape.coreObjectCost) }
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    preWarmRequest += shape.warmObjectCost
                    if cache.value(for: key) != nil { preWarmHit += shape.warmObjectCost }
                    else { cache.insert(key, for: key, cost: shape.warmObjectCost) }
                }
            }
            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                cache.insert(key, for: key, cost: scanShape.objectCost)
                precondition(cache.value(for: key) == key)
            }
        }

        var uniqueScanObjectClock = 0
        var scheduledSecondTouches: [Int: [Int]] = [:]
        var postCoreRequest = 0
        var postCoreHit = 0
        var postWarmRequest = 0
        var postWarmHit = 0
        var finalCoreRequest = 0
        var finalCoreHit = 0
        var finalWarmRequest = 0
        var finalWarmHit = 0
        var postCoreMissBytes = 0
        var postWarmMissBytes = 0
        var postCoreMissRounds: [Int] = []
        var postWarmMissRounds: [Int] = []
        var postSecondRequestBytes = 0
        var postSecondHitBytes = 0
        var postSecondMissBytes = 0

        func refillHot(key: Int, cost: Int) {
            cache.insert(key, for: key, cost: cost)
            if refillMode == .oracleVisited {
                precondition(cache.value(for: key) == key)
            }
        }

        func secondRequest(_ key: Int) {
            postSecondRequestBytes += scanShape.objectCost
            if cache.value(for: key) != nil {
                postSecondHitBytes += scanShape.objectCost
            } else {
                postSecondMissBytes += scanShape.objectCost
                cache.insert(key, for: key, cost: scanShape.objectCost)
            }
        }

        for round in 0..<postRecoveryRounds {
            let finalWindow = round >= postRecoveryRounds - finalWindowRounds
            if round % coreReuseStride == 0 {
                var serviceMissed = false
                for key in coreKeys {
                    postCoreRequest += shape.coreObjectCost
                    if finalWindow { finalCoreRequest += shape.coreObjectCost }
                    if cache.value(for: key) != nil {
                        postCoreHit += shape.coreObjectCost
                        if finalWindow { finalCoreHit += shape.coreObjectCost }
                    } else {
                        serviceMissed = true
                        postCoreMissBytes += shape.coreObjectCost
                        refillHot(key: key, cost: shape.coreObjectCost)
                    }
                }
                if serviceMissed { postCoreMissRounds.append(round) }
            }
            if round % warmReuseStride == 0 {
                var serviceMissed = false
                for key in warmKeys {
                    postWarmRequest += shape.warmObjectCost
                    if finalWindow { finalWarmRequest += shape.warmObjectCost }
                    if cache.value(for: key) != nil {
                        postWarmHit += shape.warmObjectCost
                        if finalWindow { finalWarmHit += shape.warmObjectCost }
                    } else {
                        serviceMissed = true
                        postWarmMissBytes += shape.warmObjectCost
                        refillHot(key: key, cost: shape.warmObjectCost)
                    }
                }
                if serviceMissed { postWarmMissRounds.append(round) }
            }

            guard postScanMode != .hotOnly else { continue }
            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                cache.insert(key, for: key, cost: scanShape.objectCost)
                uniqueScanObjectClock += 1
                if postScanMode == .delayedSecond128 {
                    scheduledSecondTouches[
                        uniqueScanObjectClock + delayedSecondGapObjects,
                        default: []
                    ].append(key)
                }
                if let due = scheduledSecondTouches.removeValue(forKey: uniqueScanObjectClock) {
                    for dueKey in due { secondRequest(dueKey) }
                }
            }
        }

        return SIEVEHotRefillRecoveryCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            refillMode: refillMode.rawValue,
            postScanMode: postScanMode.rawValue,
            prePollutionRounds: prePollutionRounds,
            postRecoveryRounds: postRecoveryRounds,
            finalWindowRounds: finalWindowRounds,
            prePollutionCoreByteHitRatio: ratio(preCoreHit, preCoreRequest),
            prePollutionWarmByteHitRatio: ratio(preWarmHit, preWarmRequest),
            postCoreByteHitRatio: ratio(postCoreHit, postCoreRequest),
            postWarmByteHitRatio: ratio(postWarmHit, postWarmRequest),
            finalWindowCoreByteHitRatio: ratio(finalCoreHit, finalCoreRequest),
            finalWindowWarmByteHitRatio: ratio(finalWarmHit, finalWarmRequest),
            postCoreMissBytes: postCoreMissBytes,
            postWarmMissBytes: postWarmMissBytes,
            firstPostCoreMissRound: postCoreMissRounds.first,
            firstPostWarmMissRound: postWarmMissRounds.first,
            lastPostCoreMissRound: postCoreMissRounds.last,
            lastPostWarmMissRound: postWarmMissRounds.last,
            postSecondRequestBytes: postSecondRequestBytes,
            postSecondHitBytes: postSecondHitBytes,
            postSecondMissBytes: postSecondMissBytes,
            postSecondByteHitRatio: postSecondRequestBytes > 0
                ? ratio(postSecondHitBytes, postSecondRequestBytes) : nil,
            finalCost: cache.currentCost,
            finalCount: cache.count
        )
    }

    private static func ratio(_ hit: Int, _ request: Int) -> Double {
        Double(hit) / Double(max(1, request))
    }

    private static func seedOrder(
        topology: SIEVEHotRefillTopology,
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
}
