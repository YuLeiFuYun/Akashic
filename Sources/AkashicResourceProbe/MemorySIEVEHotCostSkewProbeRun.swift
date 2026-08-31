import AkashicMemory
import Foundation

enum MemorySIEVEHotCostSkewProbe {
    private static let costLimit = 1_024
    private static let fillerObjectCount = 128
    private static let fillerObjectCost = 4
    private static let rounds = 64
    private static let fillerBase = 0
    private static let warmBase = 100_000
    private static let coreBase = 200_000
    private static let scanBase = 1_000_000

    private static let residentShapes = [
        SIEVEHotCostShape(
            name: "uniform-4",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVEHotCostShape(
            name: "medium-16",
            coreObjectCount: 16,
            coreObjectCost: 16,
            warmObjectCount: 16,
            warmObjectCost: 16
        ),
        SIEVEHotCostShape(
            name: "large-core-64",
            coreObjectCount: 4,
            coreObjectCost: 64,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVEHotCostShape(
            name: "large-warm-64",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 4,
            warmObjectCost: 64
        ),
    ]

    private static let coreReuseStrides = [1, 4, 16, 32]
    private static let warmReuseStrides = [2, 8, 32]
    private static let scanShapes = [
        SIEVEHotCostScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVEHotCostScanShape(objectCost: 64, objectsPerRound: 4),
    ]
    private static let scanTouchesAfterInsert = [0, 1]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })

        var cases: [SIEVEHotCostCase] = []
        for shape in residentShapes {
            for topology in SIEVEHotCostSeedOrder.allCases {
                for coreReuseStride in coreReuseStrides {
                    for warmReuseStride in warmReuseStrides {
                        for scanShape in scanShapes {
                            for scanTouches in scanTouchesAfterInsert {
                                cases.append(
                                    runCase(
                                        shape: shape,
                                        topology: topology,
                                        coreReuseStride: coreReuseStride,
                                        warmReuseStride: warmReuseStride,
                                        scanShape: scanShape,
                                        scanTouchesAfterInsert: scanTouches
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        let spreads = SIEVEHotCostSeedOrder.allCases.flatMap { topology in
            coreReuseStrides.flatMap { coreReuseStride in
                warmReuseStrides.flatMap { warmReuseStride in
                    scanShapes.flatMap { scanShape in
                        scanTouchesAfterInsert.map { scanTouches in
                            spread(
                                cases: cases,
                                topology: topology,
                                coreReuseStride: coreReuseStride,
                                warmReuseStride: warmReuseStride,
                                scanShape: scanShape,
                                scanTouchesAfterInsert: scanTouches
                            )
                        }
                    }
                }
            }
        }
        let maximumCoreSpread = spreads.map(\.coreByteHitRatioSpread).max() ?? 0
        let maximumWarmSpread = spreads.map(\.warmByteHitRatioSpread).max() ?? 0
        let report = SIEVEHotCostReport(
            schemaVersion: 1,
            costLimit: costLimit,
            fillerObjectCount: fillerObjectCount,
            fillerObjectCost: fillerObjectCost,
            fillerBytes: fillerObjectCount * fillerObjectCost,
            residentShapes: residentShapes.map {
                [
                    "coreObjectCount": $0.coreObjectCount,
                    "coreObjectCost": $0.coreObjectCost,
                    "coreBytes": $0.coreBytes,
                    "warmObjectCount": $0.warmObjectCount,
                    "warmObjectCost": $0.warmObjectCost,
                    "warmBytes": $0.warmBytes,
                ]
            },
            topologies: SIEVEHotCostSeedOrder.allCases.map(\.rawValue),
            coreReuseStrides: coreReuseStrides,
            warmReuseStrides: warmReuseStrides,
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            scanTouchesAfterInsert: scanTouchesAfterInsert,
            rounds: rounds,
            cases: cases,
            spreads: spreads,
            coreMissCaseCount: cases.count(where: { $0.coreMissBytes > 0 }),
            warmMissCaseCount: cases.count(where: { $0.warmMissBytes > 0 }),
            maximumCoreByteHitRatioSpread: maximumCoreSpread,
            maximumWarmByteHitRatioSpread: maximumWarmSpread,
            costGranularitySensitivityObserved: maximumCoreSpread > 0 || maximumWarmSpread > 0,
            allForecastsMatchedFinalResidents: cases.allSatisfy(\.forecastMatchedFinalResidents),
            allShadowCostsExact: cases.allSatisfy(\.shadowCostExact),
            noIncomingScanAppearedInOwnForecast: cases.allSatisfy {
                !$0.incomingScanEverAppearedInOwnForecast
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
        guard report.allForecastsMatchedFinalResidents,
            report.allShadowCostsExact,
            report.noIncomingScanAppearedInOwnForecast
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        shape: SIEVEHotCostShape,
        topology: SIEVEHotCostSeedOrder,
        coreReuseStride: Int,
        warmReuseStride: Int,
        scanShape: SIEVEHotCostScanShape,
        scanTouchesAfterInsert: Int
    ) -> SIEVEHotCostCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        var expectedResident: [Int: Int] = [:]
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
            let cost = residentCosts[key]!
            cache.insert(key, for: key, cost: cost)
            expectedResident[key] = cost
        }
        precondition(cache.currentCost == costLimit)

        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var coreRequestBytes = 0
        var coreHitBytes = 0
        var coreMissBytes = 0
        var coreRefillBytes = 0
        var warmRequestBytes = 0
        var warmHitBytes = 0
        var warmMissBytes = 0
        var warmRefillBytes = 0
        var cumulativeCoreVictimBytesFromScan = 0
        var cumulativeWarmVictimBytesFromScan = 0
        var cumulativeFillerVictimBytesFromScan = 0
        var cumulativePriorScanVictimBytesFromScan = 0
        var incomingScanEverAppearedInOwnForecast = false
        var nextScanKey = scanBase

        for round in 0..<rounds {
            if round % coreReuseStride == 0 {
                for key in coreKeys {
                    coreRequestBytes += shape.coreObjectCost
                    if cache.value(for: key) != nil {
                        coreHitBytes += shape.coreObjectCost
                    } else {
                        coreMissBytes += shape.coreObjectCost
                        refill(
                            key: key,
                            cost: shape.coreObjectCost,
                            cache: cache,
                            expectedResident: &expectedResident
                        )
                        coreRefillBytes += shape.coreObjectCost
                    }
                }
            }

            if round % warmReuseStride == 0 {
                for key in warmKeys {
                    warmRequestBytes += shape.warmObjectCost
                    if cache.value(for: key) != nil {
                        warmHitBytes += shape.warmObjectCost
                    } else {
                        warmMissBytes += shape.warmObjectCost
                        refill(
                            key: key,
                            cost: shape.warmObjectCost,
                            cache: cache,
                            expectedResident: &expectedResident
                        )
                        warmRefillBytes += shape.warmObjectCost
                    }
                }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                let victims = cache.resourceProbeEvictionForecast(incomingCost: scanShape.objectCost)
                if victims.contains(where: { $0.key == key }) {
                    incomingScanEverAppearedInOwnForecast = true
                }
                cumulativeCoreVictimBytesFromScan += victimBytes(victims, matching: .core)
                cumulativeWarmVictimBytesFromScan += victimBytes(victims, matching: .warm)
                cumulativeFillerVictimBytesFromScan += victimBytes(victims, matching: .filler)
                cumulativePriorScanVictimBytesFromScan += victimBytes(victims, matching: .scan)
                applyVictims(victims, to: &expectedResident)
                expectedResident[key] = scanShape.objectCost
                cache.insert(key, for: key, cost: scanShape.objectCost)
                for _ in 0..<scanTouchesAfterInsert {
                    precondition(cache.value(for: key) == key)
                }
            }
        }

        let actualResident = inspectResidents(
            cache: cache,
            shape: shape,
            fillerKeys: fillerKeys,
            warmKeys: warmKeys,
            coreKeys: coreKeys,
            nextScanKey: nextScanKey,
            scanObjectCost: scanShape.objectCost
        )
        let shadowCost = expectedResident.values.reduce(0, +)
        return SIEVEHotCostCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            scanBytesPerRound: scanShape.bytesPerRound,
            scanTouchesAfterInsert: scanTouchesAfterInsert,
            scanBytesBetweenCoreSweeps: scanShape.bytesPerRound * coreReuseStride,
            scanBytesBetweenWarmSweeps: scanShape.bytesPerRound * warmReuseStride,
            coreObjectCount: shape.coreObjectCount,
            coreObjectCost: shape.coreObjectCost,
            coreBytes: shape.coreBytes,
            warmObjectCount: shape.warmObjectCount,
            warmObjectCost: shape.warmObjectCost,
            warmBytes: shape.warmBytes,
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
            cumulativeCoreVictimBytesFromScan: cumulativeCoreVictimBytesFromScan,
            cumulativeWarmVictimBytesFromScan: cumulativeWarmVictimBytesFromScan,
            cumulativeFillerVictimBytesFromScan: cumulativeFillerVictimBytesFromScan,
            cumulativePriorScanVictimBytesFromScan: cumulativePriorScanVictimBytesFromScan,
            finalCoreResidentBytes: residentBytes(actualResident, matching: .core),
            finalWarmResidentBytes: residentBytes(actualResident, matching: .warm),
            finalFillerResidentBytes: residentBytes(actualResident, matching: .filler),
            finalScanResidentBytes: residentBytes(actualResident, matching: .scan),
            finalCost: cache.currentCost,
            finalCount: cache.count,
            forecastMatchedFinalResidents: actualResident == expectedResident,
            shadowCostExact: shadowCost == cache.currentCost,
            incomingScanEverAppearedInOwnForecast: incomingScanEverAppearedInOwnForecast
        )
    }

    private static func spread(
        cases: [SIEVEHotCostCase],
        topology: SIEVEHotCostSeedOrder,
        coreReuseStride: Int,
        warmReuseStride: Int,
        scanShape: SIEVEHotCostScanShape,
        scanTouchesAfterInsert: Int
    ) -> SIEVEHotCostSpread {
        let rows = cases.filter {
            $0.topology == topology.rawValue
                && $0.coreReuseStride == coreReuseStride
                && $0.warmReuseStride == warmReuseStride
                && $0.scanObjectCost == scanShape.objectCost
                && $0.scanObjectsPerRound == scanShape.objectsPerRound
                && $0.scanTouchesAfterInsert == scanTouchesAfterInsert
        }
        precondition(rows.count == residentShapes.count)
        let minimumCore = rows.min { $0.coreByteHitRatio < $1.coreByteHitRatio }!
        let maximumCore = rows.max { $0.coreByteHitRatio < $1.coreByteHitRatio }!
        let minimumWarm = rows.min { $0.warmByteHitRatio < $1.warmByteHitRatio }!
        let maximumWarm = rows.max { $0.warmByteHitRatio < $1.warmByteHitRatio }!
        return SIEVEHotCostSpread(
            topology: topology.rawValue,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            scanObjectCost: scanShape.objectCost,
            scanBytesPerRound: scanShape.bytesPerRound,
            scanTouchesAfterInsert: scanTouchesAfterInsert,
            minimumCoreByteHitRatio: minimumCore.coreByteHitRatio,
            maximumCoreByteHitRatio: maximumCore.coreByteHitRatio,
            coreByteHitRatioSpread: maximumCore.coreByteHitRatio - minimumCore.coreByteHitRatio,
            minimumWarmByteHitRatio: minimumWarm.warmByteHitRatio,
            maximumWarmByteHitRatio: maximumWarm.warmByteHitRatio,
            warmByteHitRatioSpread: maximumWarm.warmByteHitRatio - minimumWarm.warmByteHitRatio,
            minimumCoreShape: minimumCore.residentShape,
            maximumCoreShape: maximumCore.residentShape,
            minimumWarmShape: minimumWarm.residentShape,
            maximumWarmShape: maximumWarm.residentShape
        )
    }

    private static func refill(
        key: Int,
        cost: Int,
        cache: MemoryCache<Int, Int>,
        expectedResident: inout [Int: Int]
    ) {
        let victims = cache.resourceProbeEvictionForecast(incomingCost: cost)
        applyVictims(victims, to: &expectedResident)
        expectedResident[key] = cost
        cache.insert(key, for: key, cost: cost)
    }

    private static func seedOrder(
        topology: SIEVEHotCostSeedOrder,
        fillerKeys: [Int],
        warmKeys: [Int],
        coreKeys: [Int]
    ) -> [Int] {
        let all = fillerKeys + warmKeys + coreKeys
        switch topology {
        case .fillerWarmCore:
            return all
        case .coreWarmFiller:
            return coreKeys + warmKeys + fillerKeys
        case .shuffle17:
            return shuffled(all, seed: 17)
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
        matching identity: SIEVEHotCostIdentityClass
    ) -> Int {
        victims.reduce(0) { partial, victim in
            partial + (identityClass(for: victim.key) == identity ? victim.cost : 0)
        }
    }

    private static func inspectResidents(
        cache: MemoryCache<Int, Int>,
        shape: SIEVEHotCostShape,
        fillerKeys: [Int],
        warmKeys: [Int],
        coreKeys: [Int],
        nextScanKey: Int,
        scanObjectCost: Int
    ) -> [Int: Int] {
        var resident: [Int: Int] = [:]
        for key in fillerKeys {
            if cache.value(for: key) != nil { resident[key] = fillerObjectCost }
        }
        for key in warmKeys {
            if cache.value(for: key) != nil { resident[key] = shape.warmObjectCost }
        }
        for key in coreKeys {
            if cache.value(for: key) != nil { resident[key] = shape.coreObjectCost }
        }
        for key in scanBase..<nextScanKey {
            if cache.value(for: key) != nil { resident[key] = scanObjectCost }
        }
        return resident
    }

    private static func residentBytes(
        _ resident: [Int: Int],
        matching identity: SIEVEHotCostIdentityClass
    ) -> Int {
        resident.reduce(0) { partial, pair in
            partial + (identityClass(for: pair.key) == identity ? pair.value : 0)
        }
    }

    private static func identityClass(for key: Int) -> SIEVEHotCostIdentityClass {
        if key >= scanBase { return .scan }
        if key >= coreBase { return .core }
        if key >= warmBase { return .warm }
        return .filler
    }
}
