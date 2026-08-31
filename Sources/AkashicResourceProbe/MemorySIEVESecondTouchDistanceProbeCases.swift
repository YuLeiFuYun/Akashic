import AkashicMemory
import Foundation

extension MemorySIEVESecondTouchDistanceProbe {
    static func runCase(
        shape: SIEVESecondTouchResidentShape,
        topology: SIEVESecondTouchSeedOrder,
        coreReuseStride: Int,
        warmReuseStride: Int,
        scanShape: SIEVESecondTouchScanShape,
        mode: SIEVESecondTouchMode,
        trackShadow: Bool
    ) -> SIEVESecondTouchCase {
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
            if trackShadow { expectedResident[key] = cost }
        }
        precondition(cache.currentCost == costLimit)
        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var scheduledSecondTouchesByScanByteClock: [Int: [Int]] = [:]
        var uniqueScanByteClock = 0
        var nextScanKey = scanBase
        var incomingScanEverAppearedInOwnForecast = false

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
        var cumulativeCoreVictimBytesFromScanFirstInsert = 0
        var cumulativeWarmVictimBytesFromScanFirstInsert = 0
        var cumulativeFillerVictimBytesFromScanFirstInsert = 0
        var cumulativePriorScanVictimBytesFromScanFirstInsert = 0
        var cumulativeCoreVictimBytesFromScanSecondMiss = 0
        var cumulativeWarmVictimBytesFromScanSecondMiss = 0
        var cumulativeFillerVictimBytesFromScanSecondMiss = 0
        var cumulativePriorScanVictimBytesFromScanSecondMiss = 0
        var measuring = false

        func recordVictims(_ victims: [MemoryCacheEvictionVictim<Int>], firstInsert: Bool) {
            guard measuring else { return }
            if firstInsert {
                cumulativeCoreVictimBytesFromScanFirstInsert += victimBytes(victims, matching: .core)
                cumulativeWarmVictimBytesFromScanFirstInsert += victimBytes(victims, matching: .warm)
                cumulativeFillerVictimBytesFromScanFirstInsert += victimBytes(victims, matching: .filler)
                cumulativePriorScanVictimBytesFromScanFirstInsert += victimBytes(victims, matching: .scan)
            } else {
                cumulativeCoreVictimBytesFromScanSecondMiss += victimBytes(victims, matching: .core)
                cumulativeWarmVictimBytesFromScanSecondMiss += victimBytes(victims, matching: .warm)
                cumulativeFillerVictimBytesFromScanSecondMiss += victimBytes(victims, matching: .filler)
                cumulativePriorScanVictimBytesFromScanSecondMiss += victimBytes(victims, matching: .scan)
            }
        }

        func performSecondTouch(_ key: Int) {
            if measuring { scanSecondRequestBytes += scanShape.objectCost }
            if cache.value(for: key) != nil {
                if measuring { scanSecondHitBytes += scanShape.objectCost }
                return
            }
            if measuring { scanSecondMissBytes += scanShape.objectCost }
            if trackShadow {
                let victims = cache.resourceProbeEvictionForecast(incomingCost: scanShape.objectCost)
                if victims.contains(where: { $0.key == key }) {
                    incomingScanEverAppearedInOwnForecast = true
                }
                recordVictims(victims, firstInsert: false)
                applyVictims(victims, to: &expectedResident)
                expectedResident[key] = scanShape.objectCost
            }
            cache.insert(key, for: key, cost: scanShape.objectCost)
        }

        let totalRounds = warmupRounds + measurementRounds
        for absoluteRound in 0..<totalRounds {
            measuring = absoluteRound >= warmupRounds

            if absoluteRound % coreReuseStride == 0 {
                for key in coreKeys {
                    if measuring { coreRequestBytes += shape.coreObjectCost }
                    if cache.value(for: key) != nil {
                        if measuring { coreHitBytes += shape.coreObjectCost }
                    } else {
                        if measuring { coreMissBytes += shape.coreObjectCost }
                        if trackShadow {
                            refill(
                                key: key,
                                cost: shape.coreObjectCost,
                                cache: cache,
                                expectedResident: &expectedResident
                            )
                        } else {
                            cache.insert(key, for: key, cost: shape.coreObjectCost)
                        }
                        if measuring { coreRefillBytes += shape.coreObjectCost }
                    }
                }
            }

            if absoluteRound % warmReuseStride == 0 {
                for key in warmKeys {
                    if measuring { warmRequestBytes += shape.warmObjectCost }
                    if cache.value(for: key) != nil {
                        if measuring { warmHitBytes += shape.warmObjectCost }
                    } else {
                        if measuring { warmMissBytes += shape.warmObjectCost }
                        if trackShadow {
                            refill(
                                key: key,
                                cost: shape.warmObjectCost,
                                cache: cache,
                                expectedResident: &expectedResident
                            )
                        } else {
                            cache.insert(key, for: key, cost: shape.warmObjectCost)
                        }
                        if measuring { warmRefillBytes += shape.warmObjectCost }
                    }
                }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                if trackShadow {
                    let victims = cache.resourceProbeEvictionForecast(incomingCost: scanShape.objectCost)
                    if victims.contains(where: { $0.key == key }) {
                        incomingScanEverAppearedInOwnForecast = true
                    }
                    recordVictims(victims, firstInsert: true)
                    applyVictims(victims, to: &expectedResident)
                    expectedResident[key] = scanShape.objectCost
                }
                cache.insert(key, for: key, cost: scanShape.objectCost)

                uniqueScanByteClock += scanShape.objectCost
                if let interveningNewScanBytes = mode.interveningNewScanBytes {
                    if interveningNewScanBytes == 0 {
                        performSecondTouch(key)
                    } else {
                        scheduledSecondTouchesByScanByteClock[
                            uniqueScanByteClock + interveningNewScanBytes,
                            default: []
                        ].append(key)
                    }
                }
                if let dueKeys = scheduledSecondTouchesByScanByteClock.removeValue(
                    forKey: uniqueScanByteClock
                ) {
                    for dueKey in dueKeys { performSecondTouch(dueKey) }
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
        let shadowCost = trackShadow ? expectedResident.values.reduce(0, +) : 0
        return SIEVESecondTouchCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            scanFirstTouchBytesPerRound: scanShape.bytesPerRound,
            secondTouchMode: mode.name,
            scanSecondTouchInterveningNewScanBytes: mode.interveningNewScanBytes,
            scanSecondTouchInterveningNewScanCacheTurns: mode.interveningNewScanBytes.map {
                Double($0) / Double(costLimit)
            },
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
            scanSecondByteHitRatio: scanSecondRequestBytes > 0
                ? Double(scanSecondHitBytes) / Double(scanSecondRequestBytes) : nil,
            shadowProofTracked: trackShadow,
            cumulativeCoreVictimBytesFromScanFirstInsert: trackShadow
                ? cumulativeCoreVictimBytesFromScanFirstInsert : nil,
            cumulativeWarmVictimBytesFromScanFirstInsert: trackShadow
                ? cumulativeWarmVictimBytesFromScanFirstInsert : nil,
            cumulativeFillerVictimBytesFromScanFirstInsert: trackShadow
                ? cumulativeFillerVictimBytesFromScanFirstInsert : nil,
            cumulativePriorScanVictimBytesFromScanFirstInsert: trackShadow
                ? cumulativePriorScanVictimBytesFromScanFirstInsert : nil,
            cumulativeCoreVictimBytesFromScanSecondMiss: trackShadow
                ? cumulativeCoreVictimBytesFromScanSecondMiss : nil,
            cumulativeWarmVictimBytesFromScanSecondMiss: trackShadow
                ? cumulativeWarmVictimBytesFromScanSecondMiss : nil,
            cumulativeFillerVictimBytesFromScanSecondMiss: trackShadow
                ? cumulativeFillerVictimBytesFromScanSecondMiss : nil,
            cumulativePriorScanVictimBytesFromScanSecondMiss: trackShadow
                ? cumulativePriorScanVictimBytesFromScanSecondMiss : nil,
            finalCoreResidentBytes: residentBytes(actualResident, matching: .core),
            finalWarmResidentBytes: residentBytes(actualResident, matching: .warm),
            finalFillerResidentBytes: residentBytes(actualResident, matching: .filler),
            finalScanResidentBytes: residentBytes(actualResident, matching: .scan),
            finalCost: cache.currentCost,
            finalCount: cache.count,
            forecastMatchedFinalResidents: trackShadow ? actualResident == expectedResident : nil,
            shadowCostExact: trackShadow ? shadowCost == cache.currentCost : nil,
            incomingScanEverAppearedInOwnForecast: trackShadow
                ? incomingScanEverAppearedInOwnForecast : nil
        )
    }

    static func summarize(
        cases: [SIEVESecondTouchCase],
        mode: SIEVESecondTouchMode
    ) -> SIEVESecondTouchDistanceSummary {
        let rows = cases.filter { $0.secondTouchMode == mode.name }
        precondition(!rows.isEmpty)
        let scanHitRatios = rows.compactMap(\.scanSecondByteHitRatio)
        return SIEVESecondTouchDistanceSummary(
            secondTouchMode: mode.name,
            scanSecondTouchInterveningNewScanBytes: mode.interveningNewScanBytes,
            caseCount: rows.count,
            coreMissCaseCount: rows.count(where: { $0.coreMissBytes > 0 }),
            warmMissCaseCount: rows.count(where: { $0.warmMissBytes > 0 }),
            minimumCoreByteHitRatio: rows.map(\.coreByteHitRatio).min() ?? 0,
            minimumWarmByteHitRatio: rows.map(\.warmByteHitRatio).min() ?? 0,
            minimumScanSecondByteHitRatio: scanHitRatios.min(),
            maximumScanSecondByteHitRatio: scanHitRatios.max(),
            maximumCoreRefillBytes: rows.map(\.coreRefillBytes).max() ?? 0,
            maximumWarmRefillBytes: rows.map(\.warmRefillBytes).max() ?? 0
        )
    }

    static func refill(
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

    static func seedOrder(
        topology: SIEVESecondTouchSeedOrder,
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

    static func shuffled(_ input: [Int], seed: UInt64) -> [Int] {
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

    static func applyVictims(
        _ victims: [MemoryCacheEvictionVictim<Int>],
        to expectedResident: inout [Int: Int]
    ) {
        for victim in victims {
            precondition(expectedResident[victim.key] == victim.cost)
            expectedResident.removeValue(forKey: victim.key)
        }
    }

    static func victimBytes(
        _ victims: [MemoryCacheEvictionVictim<Int>],
        matching identity: SIEVESecondTouchIdentityClass
    ) -> Int {
        victims.reduce(0) { partial, victim in
            partial + (identityClass(for: victim.key) == identity ? victim.cost : 0)
        }
    }

    static func inspectResidents(
        cache: MemoryCache<Int, Int>,
        shape: SIEVESecondTouchResidentShape,
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

    static func residentBytes(
        _ resident: [Int: Int],
        matching identity: SIEVESecondTouchIdentityClass
    ) -> Int {
        resident.reduce(0) { partial, pair in
            partial + (identityClass(for: pair.key) == identity ? pair.value : 0)
        }
    }

    static func identityClass(for key: Int) -> SIEVESecondTouchIdentityClass {
        if key >= scanBase { return .scan }
        if key >= coreBase { return .core }
        if key >= warmBase { return .warm }
        return .filler
    }
}
