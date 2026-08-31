import AkashicMemory
import Foundation

private enum SIEVETopologyIdentityClass: String, Codable {
    case filler
    case warm
    case core
    case scan
}

private enum SIEVETopologySeedOrder: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case coreWarmFiller = "core-warm-filler"
    case interleaved
    case shuffle17 = "shuffle-17"
    case shuffle73 = "shuffle-73"
}

private struct SIEVETopologyScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

private struct SIEVETopologySkewCase: Codable {
    let topology: String
    let warmReuseStride: Int
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let scanBytesPerRound: Int
    let scanBytesBetweenWarmSweeps: Int
    let rounds: Int
    let coreRequests: Int
    let coreHits: Int
    let coreMisses: Int
    let coreHitRatio: Double
    let firstCoreMissRound: Int?
    let coreRefillBytes: Int
    let warmRequests: Int
    let warmHits: Int
    let warmMisses: Int
    let warmHitRatio: Double
    let firstWarmMissRound: Int?
    let warmRefillBytes: Int
    let offeredScanObjects: Int
    let offeredScanBytes: Int
    let scanInsertionsEvictingCore: Int
    let scanInsertionsEvictingWarm: Int
    let scanInsertionsEvictingFiller: Int
    let scanInsertionsEvictingPriorScan: Int
    let cumulativeCoreVictimBytesFromScan: Int
    let cumulativeWarmVictimBytesFromScan: Int
    let cumulativeFillerVictimBytesFromScan: Int
    let cumulativePriorScanVictimBytesFromScan: Int
    let maximumCoreVictimBytesInOneScanInsertion: Int
    let maximumWarmVictimBytesInOneScanInsertion: Int
    let finalCoreResidentBytes: Int
    let finalWarmResidentBytes: Int
    let finalFillerResidentBytes: Int
    let finalScanResidentBytes: Int
    let finalCost: Int
    let finalCount: Int
    let maximumObservedCost: Int
    let maximumObservedCount: Int
    let shadowResidentIdentityExact: Bool
    let shadowCostExact: Bool
    let incomingScanEverAppearedInOwnForecast: Bool
}

private struct SIEVETopologySkewReport: Codable {
    struct Claims: Codable {
        let admissionPolicyEvaluated: Bool
        let formalPerformance: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let coreObjectCount: Int
    let warmObjectCount: Int
    let fillerObjectCount: Int
    let residentObjectCost: Int
    let rounds: Int
    let topologies: [String]
    let warmReuseStrides: [Int]
    let scanShapes: [[String: Int]]
    let cases: [SIEVETopologySkewCase]
    let allShadowResidentIdentitiesExact: Bool
    let allShadowCostsExact: Bool
    let noIncomingScanAppearedInOwnForecast: Bool
    let coreMissCaseCount: Int
    let warmMissCaseCount: Int
    let minimumCoreHitRatio: Double
    let minimumWarmHitRatio: Double
    let claims: Claims
}

enum MemorySIEVETopologySkewProbe {
    private static let costLimit = 1_024
    private static let residentObjectCost = 4
    private static let fillerObjectCount = 128
    private static let warmObjectCount = 64
    private static let coreObjectCount = 64
    private static let rounds = 64
    private static let fillerBase = 0
    private static let warmBase = 100_000
    private static let coreBase = 200_000
    private static let scanBase = 1_000_000

    private static let warmReuseStrides = [2, 4, 8]
    private static let scanShapes = [
        SIEVETopologyScanShape(objectCost: 4, objectsPerRound: 16),
        SIEVETopologyScanShape(objectCost: 64, objectsPerRound: 1),
        SIEVETopologyScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVETopologyScanShape(objectCost: 64, objectsPerRound: 4),
    ]

    static func run() throws {
        var cases: [SIEVETopologySkewCase] = []
        for topology in SIEVETopologySeedOrder.allCases {
            for warmReuseStride in warmReuseStrides {
                for scanShape in scanShapes {
                    cases.append(
                        runCase(
                            topology: topology,
                            warmReuseStride: warmReuseStride,
                            scanShape: scanShape
                        )
                    )
                }
            }
        }

        let report = SIEVETopologySkewReport(
            schemaVersion: 1,
            costLimit: costLimit,
            coreObjectCount: coreObjectCount,
            warmObjectCount: warmObjectCount,
            fillerObjectCount: fillerObjectCount,
            residentObjectCost: residentObjectCost,
            rounds: rounds,
            topologies: SIEVETopologySeedOrder.allCases.map(\.rawValue),
            warmReuseStrides: warmReuseStrides,
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            cases: cases,
            allShadowResidentIdentitiesExact: cases.allSatisfy(\.shadowResidentIdentityExact),
            allShadowCostsExact: cases.allSatisfy(\.shadowCostExact),
            noIncomingScanAppearedInOwnForecast: cases.allSatisfy {
                !$0.incomingScanEverAppearedInOwnForecast
            },
            coreMissCaseCount: cases.count(where: { $0.coreMisses > 0 }),
            warmMissCaseCount: cases.count(where: { $0.warmMisses > 0 }),
            minimumCoreHitRatio: cases.map(\.coreHitRatio).min() ?? 0,
            minimumWarmHitRatio: cases.map(\.warmHitRatio).min() ?? 0,
            claims: .init(
                admissionPolicyEvaluated: false,
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
        guard report.allShadowResidentIdentitiesExact,
            report.allShadowCostsExact,
            report.noIncomingScanAppearedInOwnForecast
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        topology: SIEVETopologySeedOrder,
        warmReuseStride: Int,
        scanShape: SIEVETopologyScanShape
    ) -> SIEVETopologySkewCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        var expectedResident: [Int: Int] = [:]
        for key in seedOrder(topology) {
            cache.insert(key, for: key, cost: residentObjectCost)
            expectedResident[key] = residentObjectCost
        }
        precondition(cache.currentCost == costLimit)
        precondition(cache.count == fillerObjectCount + warmObjectCount + coreObjectCount)

        for offset in 0..<coreObjectCount {
            let key = coreBase + offset
            precondition(cache.value(for: key) == key)
        }
        for offset in 0..<warmObjectCount {
            let key = warmBase + offset
            precondition(cache.value(for: key) == key)
        }

        var coreRequests = 0
        var coreHits = 0
        var coreMisses = 0
        var firstCoreMissRound: Int?
        var coreRefillBytes = 0
        var warmRequests = 0
        var warmHits = 0
        var warmMisses = 0
        var firstWarmMissRound: Int?
        var warmRefillBytes = 0
        var offeredScanObjects = 0
        var offeredScanBytes = 0
        var scanInsertionsEvictingCore = 0
        var scanInsertionsEvictingWarm = 0
        var scanInsertionsEvictingFiller = 0
        var scanInsertionsEvictingPriorScan = 0
        var cumulativeCoreVictimBytesFromScan = 0
        var cumulativeWarmVictimBytesFromScan = 0
        var cumulativeFillerVictimBytesFromScan = 0
        var cumulativePriorScanVictimBytesFromScan = 0
        var maximumCoreVictimBytesInOneScanInsertion = 0
        var maximumWarmVictimBytesInOneScanInsertion = 0
        var maximumObservedCost = cache.currentCost
        var maximumObservedCount = cache.count
        var incomingScanEverAppearedInOwnForecast = false
        var nextScanKey = scanBase

        for round in 0..<rounds {
            for offset in 0..<coreObjectCount {
                let key = coreBase + offset
                coreRequests += 1
                if cache.value(for: key) != nil {
                    coreHits += 1
                } else {
                    coreMisses += 1
                    if firstCoreMissRound == nil { firstCoreMissRound = round }
                    refill(
                        key: key,
                        cache: cache,
                        expectedResident: &expectedResident
                    )
                    coreRefillBytes += residentObjectCost
                }
            }

            if round % warmReuseStride == 0 {
                for offset in 0..<warmObjectCount {
                    let key = warmBase + offset
                    warmRequests += 1
                    if cache.value(for: key) != nil {
                        warmHits += 1
                    } else {
                        warmMisses += 1
                        if firstWarmMissRound == nil { firstWarmMissRound = round }
                        refill(
                            key: key,
                            cache: cache,
                            expectedResident: &expectedResident
                        )
                        warmRefillBytes += residentObjectCost
                    }
                }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                let victims = cache.resourceProbeEvictionForecast(incomingCost: scanShape.objectCost)
                let coreVictimBytes = victimBytes(victims, matching: .core)
                let warmVictimBytes = victimBytes(victims, matching: .warm)
                let fillerVictimBytes = victimBytes(victims, matching: .filler)
                let priorScanVictimBytes = victimBytes(victims, matching: .scan)
                if coreVictimBytes > 0 { scanInsertionsEvictingCore += 1 }
                if warmVictimBytes > 0 { scanInsertionsEvictingWarm += 1 }
                if fillerVictimBytes > 0 { scanInsertionsEvictingFiller += 1 }
                if priorScanVictimBytes > 0 { scanInsertionsEvictingPriorScan += 1 }
                cumulativeCoreVictimBytesFromScan += coreVictimBytes
                cumulativeWarmVictimBytesFromScan += warmVictimBytes
                cumulativeFillerVictimBytesFromScan += fillerVictimBytes
                cumulativePriorScanVictimBytesFromScan += priorScanVictimBytes
                maximumCoreVictimBytesInOneScanInsertion = max(
                    maximumCoreVictimBytesInOneScanInsertion,
                    coreVictimBytes
                )
                maximumWarmVictimBytesInOneScanInsertion = max(
                    maximumWarmVictimBytesInOneScanInsertion,
                    warmVictimBytes
                )
                if victims.contains(where: { $0.key == key }) {
                    incomingScanEverAppearedInOwnForecast = true
                }
                applyVictims(victims, to: &expectedResident)
                expectedResident[key] = scanShape.objectCost
                cache.insert(key, for: key, cost: scanShape.objectCost)
                offeredScanObjects += 1
                offeredScanBytes += scanShape.objectCost
                maximumObservedCost = max(maximumObservedCost, cache.currentCost)
                maximumObservedCount = max(maximumObservedCount, cache.count)
            }
        }

        let actualResident = inspectResidents(
            cache: cache,
            nextScanKey: nextScanKey,
            scanObjectCost: scanShape.objectCost
        )
        let finalCoreBytes = residentBytes(actualResident, matching: .core)
        let finalWarmBytes = residentBytes(actualResident, matching: .warm)
        let finalFillerBytes = residentBytes(actualResident, matching: .filler)
        let finalScanBytes = residentBytes(actualResident, matching: .scan)
        let shadowCost = expectedResident.values.reduce(0, +)

        return SIEVETopologySkewCase(
            topology: topology.rawValue,
            warmReuseStride: warmReuseStride,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            scanBytesPerRound: scanShape.bytesPerRound,
            scanBytesBetweenWarmSweeps: scanShape.bytesPerRound * warmReuseStride,
            rounds: rounds,
            coreRequests: coreRequests,
            coreHits: coreHits,
            coreMisses: coreMisses,
            coreHitRatio: Double(coreHits) / Double(max(1, coreRequests)),
            firstCoreMissRound: firstCoreMissRound,
            coreRefillBytes: coreRefillBytes,
            warmRequests: warmRequests,
            warmHits: warmHits,
            warmMisses: warmMisses,
            warmHitRatio: Double(warmHits) / Double(max(1, warmRequests)),
            firstWarmMissRound: firstWarmMissRound,
            warmRefillBytes: warmRefillBytes,
            offeredScanObjects: offeredScanObjects,
            offeredScanBytes: offeredScanBytes,
            scanInsertionsEvictingCore: scanInsertionsEvictingCore,
            scanInsertionsEvictingWarm: scanInsertionsEvictingWarm,
            scanInsertionsEvictingFiller: scanInsertionsEvictingFiller,
            scanInsertionsEvictingPriorScan: scanInsertionsEvictingPriorScan,
            cumulativeCoreVictimBytesFromScan: cumulativeCoreVictimBytesFromScan,
            cumulativeWarmVictimBytesFromScan: cumulativeWarmVictimBytesFromScan,
            cumulativeFillerVictimBytesFromScan: cumulativeFillerVictimBytesFromScan,
            cumulativePriorScanVictimBytesFromScan: cumulativePriorScanVictimBytesFromScan,
            maximumCoreVictimBytesInOneScanInsertion: maximumCoreVictimBytesInOneScanInsertion,
            maximumWarmVictimBytesInOneScanInsertion: maximumWarmVictimBytesInOneScanInsertion,
            finalCoreResidentBytes: finalCoreBytes,
            finalWarmResidentBytes: finalWarmBytes,
            finalFillerResidentBytes: finalFillerBytes,
            finalScanResidentBytes: finalScanBytes,
            finalCost: cache.currentCost,
            finalCount: cache.count,
            maximumObservedCost: maximumObservedCost,
            maximumObservedCount: maximumObservedCount,
            shadowResidentIdentityExact: actualResident == expectedResident,
            shadowCostExact: shadowCost == cache.currentCost,
            incomingScanEverAppearedInOwnForecast: incomingScanEverAppearedInOwnForecast
        )
    }

    private static func refill(
        key: Int,
        cache: MemoryCache<Int, Int>,
        expectedResident: inout [Int: Int]
    ) {
        let victims = cache.resourceProbeEvictionForecast(incomingCost: residentObjectCost)
        applyVictims(victims, to: &expectedResident)
        expectedResident[key] = residentObjectCost
        cache.insert(key, for: key, cost: residentObjectCost)
    }

    private static func seedOrder(_ topology: SIEVETopologySeedOrder) -> [Int] {
        let filler = (0..<fillerObjectCount).map { fillerBase + $0 }
        let warm = (0..<warmObjectCount).map { warmBase + $0 }
        let core = (0..<coreObjectCount).map { coreBase + $0 }
        switch topology {
        case .fillerWarmCore:
            return filler + warm + core
        case .coreWarmFiller:
            return core + warm + filler
        case .interleaved:
            var result: [Int] = []
            result.reserveCapacity(256)
            for index in 0..<64 {
                result.append(filler[index])
                result.append(warm[index])
                result.append(filler[index + 64])
                result.append(core[index])
            }
            return result
        case .shuffle17:
            return shuffled(filler + warm + core, seed: 17)
        case .shuffle73:
            return shuffled(filler + warm + core, seed: 73)
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

    private static func applyVictims(
        _ victims: [MemoryCacheEvictionVictim<Int>],
        to expectedResident: inout [Int: Int]
    ) {
        for victim in victims {
            precondition(expectedResident[victim.key] == victim.cost)
            expectedResident.removeValue(forKey: victim.key)
        }
    }

    private static func victimBytes(
        _ victims: [MemoryCacheEvictionVictim<Int>],
        matching identity: SIEVETopologyIdentityClass
    ) -> Int {
        victims.reduce(0) { partial, victim in
            partial + (identityClass(for: victim.key) == identity ? victim.cost : 0)
        }
    }

    private static func inspectResidents(
        cache: MemoryCache<Int, Int>,
        nextScanKey: Int,
        scanObjectCost: Int
    ) -> [Int: Int] {
        var resident: [Int: Int] = [:]
        for offset in 0..<fillerObjectCount {
            let key = fillerBase + offset
            if cache.value(for: key) != nil { resident[key] = residentObjectCost }
        }
        for offset in 0..<warmObjectCount {
            let key = warmBase + offset
            if cache.value(for: key) != nil { resident[key] = residentObjectCost }
        }
        for offset in 0..<coreObjectCount {
            let key = coreBase + offset
            if cache.value(for: key) != nil { resident[key] = residentObjectCost }
        }
        for key in scanBase..<nextScanKey {
            if cache.value(for: key) != nil { resident[key] = scanObjectCost }
        }
        return resident
    }

    private static func residentBytes(
        _ resident: [Int: Int],
        matching identity: SIEVETopologyIdentityClass
    ) -> Int {
        resident.reduce(0) { partial, pair in
            partial + (identityClass(for: pair.key) == identity ? pair.value : 0)
        }
    }

    private static func identityClass(for key: Int) -> SIEVETopologyIdentityClass {
        if key >= scanBase { return .scan }
        if key >= coreBase { return .core }
        if key >= warmBase { return .warm }
        return .filler
    }
}
