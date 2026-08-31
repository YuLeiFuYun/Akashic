import AkashicMemory
import Foundation

enum MemorySIEVEFingerprintGhostProbe {
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
    private static let ghostCapacities = [64, 128, 256]
    private static let fingerprintBits = [4, 8, 12, 16]
    private static let scanShapes = [
        SIEVEFingerprintGhostScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVEFingerprintGhostScanShape(objectCost: 64, objectsPerRound: 4),
    ]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(coreObjectCount * hotObjectCost == 256)
        precondition(warmObjectCount * hotObjectCost == 256)
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })

        var cases: [SIEVEFingerprintGhostCase] = []
        for topology in SIEVEFingerprintGhostTopology.allCases {
            for scanShape in scanShapes {
                for postMode in SIEVEFingerprintGhostPostMode.allCases {
                    for collisionMode in SIEVEFingerprintGhostCollisionMode.allCases {
                        for capacity in ghostCapacities {
                            for bits in fingerprintBits {
                                cases.append(
                                    runCase(
                                        topology: topology,
                                        scanShape: scanShape,
                                        postMode: postMode,
                                        collisionMode: collisionMode,
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
        precondition(cases.count == 288)

        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }
        let allGhostEntryBoundsPreserved = cases.allSatisfy {
            $0.maximumGhostOccupiedEntries <= $0.ghostCapacityEntries
        }
        let forcedCollisionCasesObserveFalsePositivePromotion = cases
            .filter { $0.collisionMode == SIEVEFingerprintGhostCollisionMode.coreAligned16.rawValue }
            .contains { $0.falsePositivePromotionCount > 0 }

        let report = SIEVEFingerprintGhostReport(
            schemaVersion: 1,
            costLimit: costLimit,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            prePollutionRounds: prePollutionRounds,
            recoveryRounds: recoveryRounds,
            finalWindowRounds: finalWindowRounds,
            ghostCapacitiesEntries: ghostCapacities,
            fingerprintWidthsBits: fingerprintBits,
            topologies: SIEVEFingerprintGhostTopology.allCases.map(\.rawValue),
            postModes: SIEVEFingerprintGhostPostMode.allCases.map(\.rawValue),
            collisionModes: SIEVEFingerprintGhostCollisionMode.allCases.map(\.rawValue),
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
            forcedCollisionCasesObserveFalsePositivePromotion:
                forcedCollisionCasesObserveFalsePositivePromotion,
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
              forcedCollisionCasesObserveFalsePositivePromotion
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        topology: SIEVEFingerprintGhostTopology,
        scanShape: SIEVEFingerprintGhostScanShape,
        postMode: SIEVEFingerprintGhostPostMode,
        collisionMode: SIEVEFingerprintGhostCollisionMode,
        ghostCapacity: Int,
        fingerprintBits: Int
    ) -> SIEVEFingerprintGhostCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        let fillerKeys = (0..<fillerObjectCount).map { fillerBase + $0 }
        let warmKeys = (0..<warmObjectCount).map { warmBase + $0 }
        let coreKeys = (0..<coreObjectCount).map { coreBase + $0 }
        let costs = Dictionary(
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
            cache.insert(key, for: key, cost: costs[key]!)
        }
        precondition(cache.currentCost == costLimit)
        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var naturalScanKey = naturalScanBase
        var scanSerial = 0
        func nextScanIdentity() -> Int {
            defer { scanSerial += 1 }
            switch collisionMode {
            case .naturalSequential:
                defer { naturalScanKey += 1 }
                return naturalScanKey
            case .coreAligned16:
                let target = coreKeys[scanSerial % coreKeys.count]
                let modulus = 1 << 16
                let base = collisionScanBase + scanSerial * modulus
                let baseResidue = base & (modulus - 1)
                let targetResidue = target & (modulus - 1)
                let delta = (targetResidue - baseResidue + modulus) & (modulus - 1)
                let key = base + delta
                precondition((key & (modulus - 1)) == targetResidue)
                return key
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
                let key = nextScanIdentity()
                cache.insert(key, for: key, cost: scanShape.objectCost)
                precondition(cache.value(for: key) == key)
            }
        }

        // The approximate policy starts empty after the common poisoned prefix so every width and
        // capacity must earn its repair evidence during the same recovery trace.
        var ghost = SIEVEFingerprintGhost(
            capacity: ghostCapacity,
            fingerprintBits: fingerprintBits
        )
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
        var trueHistoryPromotionCount = 0
        var falsePositivePromotionCount = 0
        var trueHistoryPromotionBytes = 0
        var falsePositivePromotionBytes = 0
        var scanFirstRequestFalsePositivePromotionBytes = 0
        var scanLaterRequestFalsePositivePromotionBytes = 0
        var hotFalsePositivePromotionBytes = 0
        var scanSecondRequestBytes = 0
        var scanSecondHitBytes = 0
        var scanSecondMissBytes = 0

        func insertRecordingVictims(_ key: Int, cost: Int) {
            for victim in cache.resourceProbeEvictionForecast(incomingCost: cost) {
                ghost.recordEviction(victim.key)
            }
            cache.insert(key, for: key, cost: cost)
        }

        func promoteFromHistoryIfMatched(
            _ key: Int,
            cost: Int,
            scanFirstRequest: Bool,
            hotRequest: Bool
        ) {
            let match = ghost.consume(key)
            guard match.matched else { return }
            precondition(cache.resourceProbeMarkVisited(for: key))
            if match.exactIdentity {
                trueHistoryPromotionCount += 1
                trueHistoryPromotionBytes += cost
            } else {
                falsePositivePromotionCount += 1
                falsePositivePromotionBytes += cost
                if hotRequest {
                    hotFalsePositivePromotionBytes += cost
                } else if scanFirstRequest {
                    scanFirstRequestFalsePositivePromotionBytes += cost
                } else {
                    scanLaterRequestFalsePositivePromotionBytes += cost
                }
            }
        }

        func requestHot(_ key: Int, finalWindow: Bool, isCore: Bool) {
            if isCore {
                recoveryCoreRequest += hotObjectCost
                if finalWindow { finalCoreRequest += hotObjectCost }
            } else {
                recoveryWarmRequest += hotObjectCost
                if finalWindow { finalWarmRequest += hotObjectCost }
            }
            if cache.value(for: key) != nil {
                if isCore {
                    recoveryCoreHit += hotObjectCost
                    if finalWindow { finalCoreHit += hotObjectCost }
                } else {
                    recoveryWarmHit += hotObjectCost
                    if finalWindow { finalWarmHit += hotObjectCost }
                }
                return
            }
            let match = ghost.consume(key)
            insertRecordingVictims(key, cost: hotObjectCost)
            if match.matched {
                precondition(cache.resourceProbeMarkVisited(for: key))
                if match.exactIdentity {
                    trueHistoryPromotionCount += 1
                    trueHistoryPromotionBytes += hotObjectCost
                } else {
                    falsePositivePromotionCount += 1
                    falsePositivePromotionBytes += hotObjectCost
                    hotFalsePositivePromotionBytes += hotObjectCost
                }
            }
        }

        func firstScanRequest(_ key: Int) {
            precondition(cache.resourceProbeValueWithoutVisit(for: key) == nil)
            let match = ghost.consume(key)
            insertRecordingVictims(key, cost: scanShape.objectCost)
            guard match.matched else { return }
            precondition(cache.resourceProbeMarkVisited(for: key))
            // The identity is globally fresh by construction, so a true exact match here would be
            // a probe bug; any membership result is a fingerprint collision.
            precondition(!match.exactIdentity)
            falsePositivePromotionCount += 1
            falsePositivePromotionBytes += scanShape.objectCost
            scanFirstRequestFalsePositivePromotionBytes += scanShape.objectCost
        }

        func laterScanRequest(_ key: Int) {
            scanSecondRequestBytes += scanShape.objectCost
            if cache.value(for: key) != nil {
                scanSecondHitBytes += scanShape.objectCost
                return
            }
            scanSecondMissBytes += scanShape.objectCost
            let match = ghost.consume(key)
            insertRecordingVictims(key, cost: scanShape.objectCost)
            if match.matched {
                precondition(cache.resourceProbeMarkVisited(for: key))
                if match.exactIdentity {
                    trueHistoryPromotionCount += 1
                    trueHistoryPromotionBytes += scanShape.objectCost
                } else {
                    falsePositivePromotionCount += 1
                    falsePositivePromotionBytes += scanShape.objectCost
                    scanLaterRequestFalsePositivePromotionBytes += scanShape.objectCost
                }
            }
        }

        for round in 0..<recoveryRounds {
            let finalWindow = round >= recoveryRounds - finalWindowRounds
            if round % coreReuseStride == 0 {
                for key in coreKeys { requestHot(key, finalWindow: finalWindow, isCore: true) }
            }
            if round % warmReuseStride == 0 {
                for key in warmKeys { requestHot(key, finalWindow: finalWindow, isCore: false) }
            }
            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanIdentity()
                firstScanRequest(key)
                uniqueScanObjectClock += 1
                if let gap = postMode.secondTouchGapObjects {
                    scheduledSecondTouches[uniqueScanObjectClock + gap, default: []].append(key)
                }
                if let due = scheduledSecondTouches.removeValue(forKey: uniqueScanObjectClock) {
                    for dueKey in due { laterScanRequest(dueKey) }
                }
            }
        }

        return SIEVEFingerprintGhostCase(
            topology: topology.rawValue,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            postMode: postMode.rawValue,
            collisionMode: collisionMode.rawValue,
            ghostCapacityEntries: ghostCapacity,
            fingerprintBits: fingerprintBits,
            nominalFingerprintPayloadCapacityBytes: ghost.nominalFingerprintPayloadCapacityBytes,
            maximumGhostOccupiedEntries: ghost.maximumOccupiedCount,
            prePollutionCoreByteHitRatio: ratio(preCoreHit, preCoreRequest),
            prePollutionWarmByteHitRatio: ratio(preWarmHit, preWarmRequest),
            recoveryCoreByteHitRatio: ratio(recoveryCoreHit, recoveryCoreRequest),
            recoveryWarmByteHitRatio: ratio(recoveryWarmHit, recoveryWarmRequest),
            finalWindowCoreByteHitRatio: ratio(finalCoreHit, finalCoreRequest),
            finalWindowWarmByteHitRatio: ratio(finalWarmHit, finalWarmRequest),
            trueHistoryPromotionCount: trueHistoryPromotionCount,
            falsePositivePromotionCount: falsePositivePromotionCount,
            trueHistoryPromotionBytes: trueHistoryPromotionBytes,
            falsePositivePromotionBytes: falsePositivePromotionBytes,
            scanFirstRequestFalsePositivePromotionBytes: scanFirstRequestFalsePositivePromotionBytes,
            scanLaterRequestFalsePositivePromotionBytes: scanLaterRequestFalsePositivePromotionBytes,
            hotFalsePositivePromotionBytes: hotFalsePositivePromotionBytes,
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
        topology: SIEVEFingerprintGhostTopology,
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
