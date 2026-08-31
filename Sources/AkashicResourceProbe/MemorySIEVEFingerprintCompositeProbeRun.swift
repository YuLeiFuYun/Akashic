import AkashicMemory
import Foundation

enum MemorySIEVEFingerprintCompositeProbe {
    private static let costLimit = 1_024
    private static let fillerObjectCount = 128
    private static let fillerObjectCost = 4
    private static let fillerBase = 0
    private static let warmBase = 100_000
    private static let coreBase = 200_000
    private static let naturalScanBase = 1_000_000
    private static let collisionScanBase = 10_000_000
    private static let coreObjectCount = 64
    private static let warmObjectCount = 64
    private static let hotObjectCost = 4
    private static let coreReuseStride = 4
    private static let warmReuseStride = 2
    private static let prePollutionRounds = 64
    private static let recoveryRounds = 128
    private static let finalWindowRounds = 16
    private static let ghostCapacities = [64, 256]
    private static let fingerprintBits = [8, 12, 16]
    private static let scanShapes = [
        SIEVEFingerprintCompositeScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVEFingerprintCompositeScanShape(objectCost: 64, objectsPerRound: 4),
    ]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(coreObjectCount * hotObjectCost == 256)
        precondition(warmObjectCount * hotObjectCost == 256)
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })

        var cases: [SIEVEFingerprintCompositeCase] = []
        for topology in SIEVEFingerprintCompositeTopology.allCases {
            for scanShape in scanShapes {
                for postMode in SIEVEFingerprintCompositePostMode.allCases {
                    for collisionMode in SIEVEFingerprintCompositeCollisionMode.allCases {
                        for promotionMode in SIEVEFingerprintCompositePromotion.allCases {
                            for capacity in ghostCapacities {
                                for bits in fingerprintBits {
                                    cases.append(
                                        runCase(
                                            topology: topology,
                                            scanShape: scanShape,
                                            postMode: postMode,
                                            collisionMode: collisionMode,
                                            promotionMode: promotionMode,
                                            ghostCapacity: capacity,
                                            fingerprintBits: bits
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        precondition(cases.count == 288)

        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }
        let allGhostEntryBoundsPreserved = cases.allSatisfy {
            $0.maximumGhostOccupiedEntries <= $0.ghostCapacityEntries
        }
        let forcedCollisionDelayedCasesBypassProbation = cases
            .filter {
                $0.collisionMode == SIEVEFingerprintCompositeCollisionMode.coreAligned16.rawValue
                    && $0.promotionMode == SIEVEFingerprintCompositePromotion.delayedOne.rawValue
            }
            .contains { $0.falsePositiveBypassedProbationBytes > 0 }

        let report = SIEVEFingerprintCompositeReport(
            schemaVersion: 1,
            costLimit: costLimit,
            prePollutionRounds: prePollutionRounds,
            recoveryRounds: recoveryRounds,
            finalWindowRounds: finalWindowRounds,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            promotionModes: SIEVEFingerprintCompositePromotion.allCases.map(\.rawValue),
            ghostCapacitiesEntries: ghostCapacities,
            fingerprintWidthsBits: fingerprintBits,
            postModes: SIEVEFingerprintCompositePostMode.allCases.map(\.rawValue),
            collisionModes: SIEVEFingerprintCompositeCollisionMode.allCases.map(\.rawValue),
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            cases: cases,
            allResidentCostsWithinLimit: allResidentCostsWithinLimit,
            allGhostEntryBoundsPreserved: allGhostEntryBoundsPreserved,
            forcedCollisionDelayedCasesBypassProbation: forcedCollisionDelayedCasesBypassProbation,
            claims: .init(
                cachePolicyMechanismEvaluated: true,
                productionPolicyRecommendation: false,
                formalPerformance: false,
                fullMemoryFootprintQualified: false,
                fingerprintHashQualityQualified: false,
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
              forcedCollisionDelayedCasesBypassProbation
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        topology: SIEVEFingerprintCompositeTopology,
        scanShape: SIEVEFingerprintCompositeScanShape,
        postMode: SIEVEFingerprintCompositePostMode,
        collisionMode: SIEVEFingerprintCompositeCollisionMode,
        promotionMode: SIEVEFingerprintCompositePromotion,
        ghostCapacity: Int,
        fingerprintBits: Int
    ) -> SIEVEFingerprintCompositeCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        let fillerKeys = (0..<fillerObjectCount).map { fillerBase + $0 }
        let warmKeys = (0..<warmObjectCount).map { warmBase + $0 }
        let coreKeys = (0..<coreObjectCount).map { coreBase + $0 }
        let seedCosts = Dictionary(
            uniqueKeysWithValues:
                fillerKeys.map { ($0, fillerObjectCost) }
                + warmKeys.map { ($0, hotObjectCost) }
                + coreKeys.map { ($0, hotObjectCost) }
        )
        for key in seedOrder(
            topology: topology,
            fillerKeys: fillerKeys,
            warmKeys: warmKeys,
            coreKeys: coreKeys
        ) {
            cache.insert(key, for: key, cost: seedCosts[key]!)
        }
        precondition(cache.currentCost == costLimit)

        var nextNaturalScanKey = naturalScanBase
        var nextCollisionOrdinal = 0
        func nextScanKey() -> Int {
            switch collisionMode {
            case .naturalSequential:
                defer { nextNaturalScanKey += 1 }
                return nextNaturalScanKey
            case .coreAligned16:
                let alignedCore = coreBase + (nextCollisionOrdinal % coreObjectCount)
                let generation = 1 + (nextCollisionOrdinal / coreObjectCount)
                nextCollisionOrdinal += 1
                // Preserve the core key's low 16 bits while moving the key into a disjoint range.
                return collisionScanBase + generation * 65_536 + (alignedCore & 0xFFFF)
            }
        }

        var preCoreRequest = 0
        var preCoreHit = 0
        var preWarmRequest = 0
        var preWarmHit = 0
        for round in 0..<prePollutionRounds {
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    preCoreRequest += hotObjectCost
                    if cache.value(for: key) != nil { preCoreHit += hotObjectCost }
                    else { cache.insert(key, for: key, cost: hotObjectCost) }
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    preWarmRequest += hotObjectCost
                    if cache.value(for: key) != nil { preWarmHit += hotObjectCost }
                    else { cache.insert(key, for: key, cost: hotObjectCost) }
                }
            }
            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey()
                cache.insert(key, for: key, cost: scanShape.objectCost)
                precondition(cache.value(for: key) == key)
            }
        }

        var ghost = SIEVEFingerprintCompositeGhost(
            capacity: ghostCapacity,
            fingerprintBits: fingerprintBits
        )
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
        var trueHistoryPromotionBytes = 0
        var falsePositivePromotionBytes = 0
        var scanFirstFalsePositivePromotionBytes = 0
        var scanLaterFalsePositivePromotionBytes = 0
        var hotFalsePositivePromotionBytes = 0
        var falsePositiveBypassedProbationBytes = 0
        var scanSecondRequestBytes = 0
        var scanSecondHitBytes = 0
        var scanSecondMissBytes = 0

        func insertMiss(
            _ key: Int,
            cost: Int,
            isScanFirst: Bool,
            isHot: Bool
        ) -> SIEVEFingerprintCompositeGhost.Match {
            let match = ghost.consume(key)
            let victims = cache.resourceProbeEvictionForecast(incomingCost: cost)
            for victim in victims {
                probationHits.removeValue(forKey: victim.key)
                ghost.recordEviction(victim.key)
            }
            cache.insert(key, for: key, cost: cost)
            if match.matched {
                precondition(cache.resourceProbeMarkVisited(for: key))
                probationHits.removeValue(forKey: key)
                if match.exactIdentity {
                    trueHistoryPromotionBytes += cost
                } else {
                    falsePositivePromotionBytes += cost
                    if isHot { hotFalsePositivePromotionBytes += cost }
                    else if isScanFirst { scanFirstFalsePositivePromotionBytes += cost }
                    else { scanLaterFalsePositivePromotionBytes += cost }
                    if promotionMode == .delayedOne {
                        falsePositiveBypassedProbationBytes += cost
                    }
                }
            } else if promotionMode == .delayedOne {
                probationHits[key] = 0
                maximumProbationEntries = max(maximumProbationEntries, probationHits.count)
            }
            return match
        }

        func request(
            _ key: Int,
            cost: Int,
            isHot: Bool,
            isScanFirst: Bool = false
        ) -> Bool {
            if promotionMode == .delayedOne, let probation = probationHits[key] {
                if probation == 0 {
                    if cache.resourceProbeValueWithoutVisit(for: key) != nil {
                        probationHits[key] = 1
                        return true
                    }
                    probationHits.removeValue(forKey: key)
                } else {
                    if cache.value(for: key) != nil {
                        probationHits.removeValue(forKey: key)
                        return true
                    }
                    probationHits.removeValue(forKey: key)
                }
            } else if cache.value(for: key) != nil {
                return true
            }
            _ = insertMiss(key, cost: cost, isScanFirst: isScanFirst, isHot: isHot)
            return false
        }

        for round in 0..<recoveryRounds {
            let finalWindow = round >= recoveryRounds - finalWindowRounds
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    recoveryCoreRequest += hotObjectCost
                    if finalWindow { finalCoreRequest += hotObjectCost }
                    if request(key, cost: hotObjectCost, isHot: true) {
                        recoveryCoreHit += hotObjectCost
                        if finalWindow { finalCoreHit += hotObjectCost }
                    }
                }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    recoveryWarmRequest += hotObjectCost
                    if finalWindow { finalWarmRequest += hotObjectCost }
                    if request(key, cost: hotObjectCost, isHot: true) {
                        recoveryWarmHit += hotObjectCost
                        if finalWindow { finalWarmHit += hotObjectCost }
                    }
                }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey()
                _ = request(key, cost: scanShape.objectCost, isHot: false, isScanFirst: true)
                uniqueScanObjectClock += 1
                if let gap = postMode.secondTouchGapObjects {
                    if gap == 0 {
                        scanSecondRequestBytes += scanShape.objectCost
                        if request(key, cost: scanShape.objectCost, isHot: false) {
                            scanSecondHitBytes += scanShape.objectCost
                        } else {
                            scanSecondMissBytes += scanShape.objectCost
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
                        if request(dueKey, cost: scanShape.objectCost, isHot: false) {
                            scanSecondHitBytes += scanShape.objectCost
                        } else {
                            scanSecondMissBytes += scanShape.objectCost
                        }
                    }
                }
            }
        }

        return SIEVEFingerprintCompositeCase(
            topology: topology.rawValue,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            postMode: postMode.rawValue,
            collisionMode: collisionMode.rawValue,
            promotionMode: promotionMode.rawValue,
            ghostCapacityEntries: ghostCapacity,
            fingerprintBits: fingerprintBits,
            nominalFingerprintPayloadCapacityBytes:
                ghostCapacity * ((fingerprintBits + 7) / 8),
            maximumGhostOccupiedEntries: ghost.maximumOccupiedCount,
            maximumProbationEntries: maximumProbationEntries,
            prePollutionCoreByteHitRatio: ratio(preCoreHit, preCoreRequest),
            prePollutionWarmByteHitRatio: ratio(preWarmHit, preWarmRequest),
            recoveryCoreByteHitRatio: ratio(recoveryCoreHit, recoveryCoreRequest),
            recoveryWarmByteHitRatio: ratio(recoveryWarmHit, recoveryWarmRequest),
            finalWindowCoreByteHitRatio: ratio(finalCoreHit, finalCoreRequest),
            finalWindowWarmByteHitRatio: ratio(finalWarmHit, finalWarmRequest),
            trueHistoryPromotionBytes: trueHistoryPromotionBytes,
            falsePositivePromotionBytes: falsePositivePromotionBytes,
            scanFirstFalsePositivePromotionBytes: scanFirstFalsePositivePromotionBytes,
            scanLaterFalsePositivePromotionBytes: scanLaterFalsePositivePromotionBytes,
            hotFalsePositivePromotionBytes: hotFalsePositivePromotionBytes,
            falsePositiveBypassedProbationBytes: falsePositiveBypassedProbationBytes,
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
        topology: SIEVEFingerprintCompositeTopology,
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
