import AkashicMemory
import Foundation

private enum SIEVECompositeRepairTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

private enum SIEVECompositeRepairPromotion: String, Codable, CaseIterable {
    case normal = "normal-resident-hit"
    case delayedOne = "delayed-resident-promotion-1"
}

private enum SIEVECompositeRepairPostMode: String, Codable, CaseIterable {
    case oneTouch = "one-touch-scan"
    case immediateSecond = "immediate-second-touch"
    case delayedSecond32 = "second-touch-gap-32-objects"
    case delayedSecond128 = "second-touch-gap-128-objects"

    var secondTouchGapObjects: Int? {
        switch self {
        case .oneTouch: nil
        case .immediateSecond: 0
        case .delayedSecond32: 32
        case .delayedSecond128: 128
        }
    }
}

private struct SIEVECompositeRepairResidentShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int
    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

private struct SIEVECompositeRepairScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int
    var bytesPerRound: Int { objectCost * objectsPerRound }
}

private struct SIEVECompositeRepairGhost {
    private let capacity: Int
    private var slots: [Int?]
    private var positions: [Int: Int] = [:]
    private var cursor = 0
    private(set) var maximumEntryCount = 0

    init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    var entryCount: Int { positions.count }
    var keyPayloadCapacityBytes: Int { capacity * MemoryLayout<Int>.stride }

    mutating func recordEviction(_ key: Int) {
        guard capacity > 0 else { return }
        if let previous = positions.removeValue(forKey: key) { slots[previous] = nil }
        if let displaced = slots[cursor], positions[displaced] == cursor {
            positions.removeValue(forKey: displaced)
        }
        slots[cursor] = key
        positions[key] = cursor
        cursor += 1
        if cursor == capacity { cursor = 0 }
        maximumEntryCount = max(maximumEntryCount, positions.count)
        precondition(positions.count <= capacity)
    }

    mutating func consume(_ key: Int) -> Bool {
        guard let index = positions.removeValue(forKey: key) else { return false }
        if slots[index] == key { slots[index] = nil }
        return true
    }
}

private struct SIEVECompositeRepairCase: Codable {
    let residentShape: String
    let topology: String
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let postMode: String
    let promotionMode: String
    let ghostCapacityEntries: Int
    let ghostKeyPayloadCapacityBytes: Int
    let maximumGhostEntries: Int
    let maximumProbationEntries: Int

    let prePollutionCoreByteHitRatio: Double
    let prePollutionWarmByteHitRatio: Double
    let recoveryCoreByteHitRatio: Double
    let recoveryWarmByteHitRatio: Double
    let finalWindowCoreByteHitRatio: Double
    let finalWindowWarmByteHitRatio: Double
    let hotGhostPromotedRefillBytes: Int
    let scanGhostPromotedRefillBytes: Int
    let scanSecondRequestBytes: Int
    let scanSecondHitBytes: Int
    let scanSecondMissBytes: Int
    let scanSecondByteHitRatio: Double?
    let finalCost: Int
    let finalCount: Int
}

private struct SIEVECompositeRepairReport: Codable {
    struct Claims: Codable {
        let cachePolicyMechanismEvaluated: Bool
        let productionPolicyRecommendation: Bool
        let formalPerformance: Bool
        let fullMemoryFootprintQualified: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let prePollutionRounds: Int
    let recoveryRounds: Int
    let finalWindowRounds: Int
    let coreReuseStride: Int
    let warmReuseStride: Int
    let promotionModes: [String]
    let ghostCapacitiesEntries: [Int]
    let postModes: [String]
    let cases: [SIEVECompositeRepairCase]
    let allResidentCostsWithinLimit: Bool
    let allGhostEntryBoundsPreserved: Bool
    let claims: Claims
}

enum MemorySIEVECompositeRepairProbe {
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
    private static let recoveryRounds = 128
    private static let finalWindowRounds = 16
    private static let ghostCapacities = [0, 32, 64, 128, 256]
    private static let residentShapes = [
        SIEVECompositeRepairResidentShape(
            name: "uniform-4", coreObjectCount: 64, coreObjectCost: 4,
            warmObjectCount: 64, warmObjectCost: 4
        ),
        SIEVECompositeRepairResidentShape(
            name: "medium-16", coreObjectCount: 16, coreObjectCost: 16,
            warmObjectCount: 16, warmObjectCost: 16
        ),
        SIEVECompositeRepairResidentShape(
            name: "large-core-64", coreObjectCount: 4, coreObjectCost: 64,
            warmObjectCount: 64, warmObjectCost: 4
        ),
        SIEVECompositeRepairResidentShape(
            name: "large-warm-64", coreObjectCount: 64, coreObjectCost: 4,
            warmObjectCount: 4, warmObjectCost: 64
        ),
    ]
    private static let scanShapes = [
        SIEVECompositeRepairScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVECompositeRepairScanShape(objectCost: 64, objectsPerRound: 4),
    ]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })

        var cases: [SIEVECompositeRepairCase] = []
        for shape in residentShapes {
            for topology in SIEVECompositeRepairTopology.allCases {
                for scanShape in scanShapes {
                    for postMode in SIEVECompositeRepairPostMode.allCases {
                        for promotionMode in SIEVECompositeRepairPromotion.allCases {
                            for ghostCapacity in ghostCapacities {
                                cases.append(
                                    runCase(
                                        shape: shape,
                                        topology: topology,
                                        scanShape: scanShape,
                                        postMode: postMode,
                                        promotionMode: promotionMode,
                                        ghostCapacity: ghostCapacity
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        precondition(cases.count == 640)

        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }
        let allGhostEntryBoundsPreserved = cases.allSatisfy {
            $0.maximumGhostEntries <= $0.ghostCapacityEntries
        }
        let report = SIEVECompositeRepairReport(
            schemaVersion: 1,
            costLimit: costLimit,
            prePollutionRounds: prePollutionRounds,
            recoveryRounds: recoveryRounds,
            finalWindowRounds: finalWindowRounds,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            promotionModes: SIEVECompositeRepairPromotion.allCases.map(\.rawValue),
            ghostCapacitiesEntries: ghostCapacities,
            postModes: SIEVECompositeRepairPostMode.allCases.map(\.rawValue),
            cases: cases,
            allResidentCostsWithinLimit: allResidentCostsWithinLimit,
            allGhostEntryBoundsPreserved: allGhostEntryBoundsPreserved,
            claims: .init(
                cachePolicyMechanismEvaluated: true,
                productionPolicyRecommendation: false,
                formalPerformance: false,
                fullMemoryFootprintQualified: false,
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
        guard allResidentCostsWithinLimit, allGhostEntryBoundsPreserved else {
            throw ProbeError.resourceSampleFailed
        }
    }

    private static func runCase(
        shape: SIEVECompositeRepairResidentShape,
        topology: SIEVECompositeRepairTopology,
        scanShape: SIEVECompositeRepairScanShape,
        postMode: SIEVECompositeRepairPostMode,
        promotionMode: SIEVECompositeRepairPromotion,
        ghostCapacity: Int
    ) -> SIEVECompositeRepairCase {
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

        var ghost = SIEVECompositeRepairGhost(capacity: ghostCapacity)
        var probationHits: [Int: UInt8] = [:]
        var maximumProbationEntries = 0
        var scheduledSecondTouches: [Int: [Int]] = [:]
        var uniqueScanObjectClock = 0
        var recoveryCoreRequest = 0
        var recoveryCoreHit = 0
        var recoveryWarmRequest = 0
        var recoveryWarmHit = 0
        var finalCoreRequest = 0
        var finalCoreHit = 0
        var finalWarmRequest = 0
        var finalWarmHit = 0
        var hotGhostPromotedRefillBytes = 0
        var scanGhostPromotedRefillBytes = 0
        var scanSecondRequestBytes = 0
        var scanSecondHitBytes = 0
        var scanSecondMissBytes = 0

        func insertMiss(_ key: Int, cost: Int) -> Bool {
            let ghostHit = ghost.consume(key)
            let victims = cache.resourceProbeEvictionForecast(incomingCost: cost)
            for victim in victims {
                probationHits.removeValue(forKey: victim.key)
                ghost.recordEviction(victim.key)
            }
            cache.insert(key, for: key, cost: cost)
            if ghostHit {
                precondition(cache.resourceProbeMarkVisited(for: key))
                probationHits.removeValue(forKey: key)
            } else if promotionMode == .delayedOne {
                probationHits[key] = 0
                maximumProbationEntries = max(maximumProbationEntries, probationHits.count)
            }
            return ghostHit
        }

        func request(_ key: Int, cost: Int) -> (hit: Bool, ghostPromoted: Bool) {
            if promotionMode == .delayedOne, let probation = probationHits[key] {
                if probation == 0 {
                    if cache.resourceProbeValueWithoutVisit(for: key) != nil {
                        probationHits[key] = 1
                        return (true, false)
                    }
                    probationHits.removeValue(forKey: key)
                } else {
                    if cache.value(for: key) != nil {
                        probationHits.removeValue(forKey: key)
                        return (true, false)
                    }
                    probationHits.removeValue(forKey: key)
                }
            } else if cache.value(for: key) != nil {
                return (true, false)
            }
            return (false, insertMiss(key, cost: cost))
        }

        for round in 0..<recoveryRounds {
            let finalWindow = round >= recoveryRounds - finalWindowRounds
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    recoveryCoreRequest += shape.coreObjectCost
                    if finalWindow { finalCoreRequest += shape.coreObjectCost }
                    let result = request(key, cost: shape.coreObjectCost)
                    if result.hit {
                        recoveryCoreHit += shape.coreObjectCost
                        if finalWindow { finalCoreHit += shape.coreObjectCost }
                    } else if result.ghostPromoted {
                        hotGhostPromotedRefillBytes += shape.coreObjectCost
                    }
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    recoveryWarmRequest += shape.warmObjectCost
                    if finalWindow { finalWarmRequest += shape.warmObjectCost }
                    let result = request(key, cost: shape.warmObjectCost)
                    if result.hit {
                        recoveryWarmHit += shape.warmObjectCost
                        if finalWindow { finalWarmHit += shape.warmObjectCost }
                    } else if result.ghostPromoted {
                        hotGhostPromotedRefillBytes += shape.warmObjectCost
                    }
                }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                _ = insertMiss(key, cost: scanShape.objectCost)
                uniqueScanObjectClock += 1
                if let gap = postMode.secondTouchGapObjects {
                    if gap == 0 {
                        scanSecondRequestBytes += scanShape.objectCost
                        let result = request(key, cost: scanShape.objectCost)
                        if result.hit { scanSecondHitBytes += scanShape.objectCost }
                        else {
                            scanSecondMissBytes += scanShape.objectCost
                            if result.ghostPromoted { scanGhostPromotedRefillBytes += scanShape.objectCost }
                        }
                    } else {
                        scheduledSecondTouches[
                            uniqueScanObjectClock + gap,
                            default: []
                        ].append(key)
                    }
                }
                if let due = scheduledSecondTouches.removeValue(forKey: uniqueScanObjectClock) {
                    for dueKey in due {
                        scanSecondRequestBytes += scanShape.objectCost
                        let result = request(dueKey, cost: scanShape.objectCost)
                        if result.hit { scanSecondHitBytes += scanShape.objectCost }
                        else {
                            scanSecondMissBytes += scanShape.objectCost
                            if result.ghostPromoted {
                                scanGhostPromotedRefillBytes += scanShape.objectCost
                            }
                        }
                    }
                }
            }
        }

        return SIEVECompositeRepairCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            postMode: postMode.rawValue,
            promotionMode: promotionMode.rawValue,
            ghostCapacityEntries: ghostCapacity,
            ghostKeyPayloadCapacityBytes: ghost.keyPayloadCapacityBytes,
            maximumGhostEntries: ghost.maximumEntryCount,
            maximumProbationEntries: maximumProbationEntries,
            prePollutionCoreByteHitRatio: ratio(preCoreHit, preCoreRequest),
            prePollutionWarmByteHitRatio: ratio(preWarmHit, preWarmRequest),
            recoveryCoreByteHitRatio: ratio(recoveryCoreHit, recoveryCoreRequest),
            recoveryWarmByteHitRatio: ratio(recoveryWarmHit, recoveryWarmRequest),
            finalWindowCoreByteHitRatio: ratio(finalCoreHit, finalCoreRequest),
            finalWindowWarmByteHitRatio: ratio(finalWarmHit, finalWarmRequest),
            hotGhostPromotedRefillBytes: hotGhostPromotedRefillBytes,
            scanGhostPromotedRefillBytes: scanGhostPromotedRefillBytes,
            scanSecondRequestBytes: scanSecondRequestBytes,
            scanSecondHitBytes: scanSecondHitBytes,
            scanSecondMissBytes: scanSecondMissBytes,
            scanSecondByteHitRatio: scanSecondRequestBytes > 0
                ? ratio(scanSecondHitBytes, scanSecondRequestBytes) : nil,
            finalCost: cache.currentCost,
            finalCount: cache.count
        )
    }

    private static func ratio(_ hit: Int, _ request: Int) -> Double {
        Double(hit) / Double(max(1, request))
    }

    private static func seedOrder(
        topology: SIEVECompositeRepairTopology,
        fillerKeys: [Int],
        warmKeys: [Int],
        coreKeys: [Int]
    ) -> [Int] {
        let all = fillerKeys + warmKeys + coreKeys
        switch topology {
        case .fillerWarmCore: return all
        case .shuffle73: return shuffled(all, seed: 73)
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
