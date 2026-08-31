import AkashicMemory
import Foundation

enum MemorySIEVEGhostRefillProbe {
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

    private static let ghostCapacities = [0, 16, 32, 64, 128, 256, 512]
    private static let residentShapes = [
        SIEVEGhostRefillResidentShape(
            name: "uniform-4",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVEGhostRefillResidentShape(
            name: "medium-16",
            coreObjectCount: 16,
            coreObjectCost: 16,
            warmObjectCount: 16,
            warmObjectCost: 16
        ),
        SIEVEGhostRefillResidentShape(
            name: "large-core-64",
            coreObjectCount: 4,
            coreObjectCost: 64,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVEGhostRefillResidentShape(
            name: "large-warm-64",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 4,
            warmObjectCost: 64
        ),
    ]
    private static let scanShapes = [
        SIEVEGhostRefillScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVEGhostRefillScanShape(objectCost: 64, objectsPerRound: 4),
    ]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })
        precondition(recoveryRounds.isMultiple(of: coreReuseStride))

        var cases: [SIEVEGhostRefillCase] = []
        for shape in residentShapes {
            for topology in SIEVEGhostRefillTopology.allCases {
                for scanShape in scanShapes {
                    for postMode in SIEVEGhostRefillPostMode.allCases {
                        for ghostCapacity in ghostCapacities {
                            cases.append(
                                runCase(
                                    shape: shape,
                                    topology: topology,
                                    scanShape: scanShape,
                                    postMode: postMode,
                                    ghostCapacity: ghostCapacity
                                )
                            )
                        }
                    }
                }
            }
        }

        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }
        let allGhostEntryBoundsPreserved = cases.allSatisfy {
            $0.maximumGhostEntries <= $0.ghostCapacityEntries
                && $0.finalGhostEntries <= $0.ghostCapacityEntries
        }
        let zeroCapacityGhostNeverPromotes = cases
            .filter { $0.ghostCapacityEntries == 0 }
            .allSatisfy {
                $0.coreGhostPromotedRefillBytes == 0
                    && $0.warmGhostPromotedRefillBytes == 0
                    && $0.scanGhostPromotedRefillBytes == 0
            }

        let report = SIEVEGhostRefillReport(
            schemaVersion: 1,
            costLimit: costLimit,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            prePollutionRounds: prePollutionRounds,
            recoveryRounds: recoveryRounds,
            finalWindowRounds: finalWindowRounds,
            ghostCapacitiesEntries: ghostCapacities,
            residentShapeNames: residentShapes.map(\.name),
            topologies: SIEVEGhostRefillTopology.allCases.map(\.rawValue),
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            postModes: SIEVEGhostRefillPostMode.allCases.map(\.rawValue),
            cases: cases,
            allResidentCostsWithinLimit: allResidentCostsWithinLimit,
            allGhostEntryBoundsPreserved: allGhostEntryBoundsPreserved,
            zeroCapacityGhostNeverPromotes: zeroCapacityGhostNeverPromotes,
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
        guard allResidentCostsWithinLimit,
              allGhostEntryBoundsPreserved,
              zeroCapacityGhostNeverPromotes
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        shape: SIEVEGhostRefillResidentShape,
        topology: SIEVEGhostRefillTopology,
        scanShape: SIEVEGhostRefillScanShape,
        postMode: SIEVEGhostRefillPostMode,
        ghostCapacity: Int
    ) -> SIEVEGhostRefillCase {
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
        precondition(cache.currentCost == costLimit)
        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var nextScanKey = scanBase
        var preCoreRequestBytes = 0
        var preCoreHitBytes = 0
        var preWarmRequestBytes = 0
        var preWarmHitBytes = 0

        // Every case enters recovery from the same poisoned SIEVE state. The ghost is intentionally
        // absent in this phase so the experiment measures repair from eviction history accumulated
        // after the phase transition rather than prevention using preloaded oracle history.
        for round in 0..<prePollutionRounds {
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    preCoreRequestBytes += shape.coreObjectCost
                    if cache.value(for: key) != nil {
                        preCoreHitBytes += shape.coreObjectCost
                    } else {
                        cache.insert(key, for: key, cost: shape.coreObjectCost)
                    }
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    preWarmRequestBytes += shape.warmObjectCost
                    if cache.value(for: key) != nil {
                        preWarmHitBytes += shape.warmObjectCost
                    } else {
                        cache.insert(key, for: key, cost: shape.warmObjectCost)
                    }
                }
            }
            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                cache.insert(key, for: key, cost: scanShape.objectCost)
                precondition(cache.value(for: key) == key)
            }
        }

        var ghost = SIEVERefillGhost(capacity: ghostCapacity)
        var scheduledSecondTouches: [Int: [Int]] = [:]
        var uniqueScanObjectClock = 0
        var recoveryCoreRequestBytes = 0
        var recoveryCoreHitBytes = 0
        var recoveryWarmRequestBytes = 0
        var recoveryWarmHitBytes = 0
        var finalCoreRequestBytes = 0
        var finalCoreHitBytes = 0
        var finalWarmRequestBytes = 0
        var finalWarmHitBytes = 0
        var coreGhostPromotedRefillBytes = 0
        var warmGhostPromotedRefillBytes = 0
        var scanGhostPromotedRefillBytes = 0
        var scanSecondRequestBytes = 0
        var scanSecondHitBytes = 0
        var scanSecondMissBytes = 0

        func insertRecordingVictims(_ key: Int, cost: Int) {
            for victim in cache.resourceProbeEvictionForecast(incomingCost: cost) {
                ghost.recordEviction(victim.key)
            }
            cache.insert(key, for: key, cost: cost)
        }

        func requestHot(_ key: Int, cost: Int, isCore: Bool, finalWindow: Bool) {
            if isCore {
                recoveryCoreRequestBytes += cost
                if finalWindow { finalCoreRequestBytes += cost }
            } else {
                recoveryWarmRequestBytes += cost
                if finalWindow { finalWarmRequestBytes += cost }
            }

            if cache.value(for: key) != nil {
                if isCore {
                    recoveryCoreHitBytes += cost
                    if finalWindow { finalCoreHitBytes += cost }
                } else {
                    recoveryWarmHitBytes += cost
                    if finalWindow { finalWarmHitBytes += cost }
                }
                return
            }

            let ghostHit = ghost.consume(key)
            insertRecordingVictims(key, cost: cost)
            if ghostHit {
                precondition(cache.resourceProbeMarkVisited(for: key))
                if isCore { coreGhostPromotedRefillBytes += cost }
                else { warmGhostPromotedRefillBytes += cost }
            }
        }

        func requestScanSecond(_ key: Int) {
            scanSecondRequestBytes += scanShape.objectCost
            if cache.value(for: key) != nil {
                scanSecondHitBytes += scanShape.objectCost
                return
            }
            scanSecondMissBytes += scanShape.objectCost
            let ghostHit = ghost.consume(key)
            insertRecordingVictims(key, cost: scanShape.objectCost)
            if ghostHit {
                precondition(cache.resourceProbeMarkVisited(for: key))
                scanGhostPromotedRefillBytes += scanShape.objectCost
            }
        }

        for round in 0..<recoveryRounds {
            let finalWindow = round >= recoveryRounds - finalWindowRounds
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    requestHot(
                        key,
                        cost: shape.coreObjectCost,
                        isCore: true,
                        finalWindow: finalWindow
                    )
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    requestHot(
                        key,
                        cost: shape.warmObjectCost,
                        isCore: false,
                        finalWindow: finalWindow
                    )
                }
            }

            guard postMode != .hotOnly else { continue }
            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                insertRecordingVictims(key, cost: scanShape.objectCost)
                uniqueScanObjectClock += 1

                if let gap = postMode.secondTouchGapObjects {
                    if gap == 0 {
                        requestScanSecond(key)
                    } else {
                        scheduledSecondTouches[
                            uniqueScanObjectClock + gap,
                            default: []
                        ].append(key)
                    }
                }
                if let due = scheduledSecondTouches.removeValue(forKey: uniqueScanObjectClock) {
                    for dueKey in due { requestScanSecond(dueKey) }
                }
            }
        }

        return SIEVEGhostRefillCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            postMode: postMode.rawValue,
            ghostCapacityEntries: ghostCapacity,
            ghostKeyPayloadCapacityBytes: ghost.keyPayloadCapacityBytes,
            maximumGhostEntries: ghost.maximumEntryCount,
            finalGhostEntries: ghost.entryCount,
            prePollutionCoreByteHitRatio: ratio(preCoreHitBytes, preCoreRequestBytes),
            prePollutionWarmByteHitRatio: ratio(preWarmHitBytes, preWarmRequestBytes),
            recoveryCoreByteHitRatio: ratio(recoveryCoreHitBytes, recoveryCoreRequestBytes),
            recoveryWarmByteHitRatio: ratio(recoveryWarmHitBytes, recoveryWarmRequestBytes),
            finalWindowCoreByteHitRatio: ratio(finalCoreHitBytes, finalCoreRequestBytes),
            finalWindowWarmByteHitRatio: ratio(finalWarmHitBytes, finalWarmRequestBytes),
            coreGhostPromotedRefillBytes: coreGhostPromotedRefillBytes,
            warmGhostPromotedRefillBytes: warmGhostPromotedRefillBytes,
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

    private static func ratio(_ hitBytes: Int, _ requestBytes: Int) -> Double {
        Double(hitBytes) / Double(max(1, requestBytes))
    }

    private static func seedOrder(
        topology: SIEVEGhostRefillTopology,
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
