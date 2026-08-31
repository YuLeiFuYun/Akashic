import AkashicMemory
import Foundation

private enum SIEVEInterleavedIdentityClass: String, Codable {
    case filler
    case hot
    case scan
}

private struct SIEVEInterleavedCase: Codable {
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let scanBytesPerRound: Int
    let hotReuseStride: Int
    let rounds: Int
    let scheduledHotRequests: Int
    let hotHits: Int
    let hotMisses: Int
    let hotHitRatio: Double
    let firstHotMissRound: Int?
    let hotRefillBytes: Int
    let offeredScanObjects: Int
    let offeredScanBytes: Int
    let scanInsertionsEvictingHot: Int
    let cumulativeHotVictimBytesFromScan: Int
    let cumulativeFillerVictimBytesFromScan: Int
    let cumulativePriorScanVictimBytesFromScan: Int
    let maximumHotVictimBytesInOneScanInsertion: Int
    let finalHotResidentBytes: Int
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

private struct SIEVEInterleavedScanReport: Codable {
    struct Claims: Codable {
        let admissionPolicyEvaluated: Bool
        let formalPerformance: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let foveaAuthoritySemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let hotObjectCount: Int
    let hotObjectCost: Int
    let hotWorkingSetBytes: Int
    let fillerObjectCount: Int
    let fillerObjectCost: Int
    let fillerBytes: Int
    let cases: [SIEVEInterleavedCase]
    let allShadowResidentIdentitiesExact: Bool
    let allShadowCostsExact: Bool
    let noIncomingScanAppearedInOwnForecast: Bool
    let minimumHotHitRatio: Double
    let maximumHotHitRatio: Double
    let claims: Claims
}

enum MemorySIEVEInterleavedScanProbe {
    private static let costLimit = 1_024
    private static let hotObjectCount = 128
    private static let hotObjectCost = 4
    private static let fillerObjectCount = 128
    private static let fillerObjectCost = 4
    private static let rounds = 64
    private static let fillerBase = 0
    private static let hotBase = 100_000
    private static let scanBase = 1_000_000

    static func run() throws {
        let scanCosts = [4, 16, 64, 128]
        let scanCounts = [1, 4, 16, 64]
        let reuseStrides = [1, 2, 4, 8]
        var cases: [SIEVEInterleavedCase] = []
        for scanCost in scanCosts {
            for scanCount in scanCounts {
                for reuseStride in reuseStrides {
                    cases.append(
                        runCase(
                            scanObjectCost: scanCost,
                            scanObjectsPerRound: scanCount,
                            hotReuseStride: reuseStride
                        )
                    )
                }
            }
        }

        let report = SIEVEInterleavedScanReport(
            schemaVersion: 1,
            costLimit: costLimit,
            hotObjectCount: hotObjectCount,
            hotObjectCost: hotObjectCost,
            hotWorkingSetBytes: hotObjectCount * hotObjectCost,
            fillerObjectCount: fillerObjectCount,
            fillerObjectCost: fillerObjectCost,
            fillerBytes: fillerObjectCount * fillerObjectCost,
            cases: cases,
            allShadowResidentIdentitiesExact: cases.allSatisfy(\.shadowResidentIdentityExact),
            allShadowCostsExact: cases.allSatisfy(\.shadowCostExact),
            noIncomingScanAppearedInOwnForecast: cases.allSatisfy {
                !$0.incomingScanEverAppearedInOwnForecast
            },
            minimumHotHitRatio: cases.map(\.hotHitRatio).min() ?? 0,
            maximumHotHitRatio: cases.map(\.hotHitRatio).max() ?? 0,
            claims: .init(
                admissionPolicyEvaluated: false,
                formalPerformance: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                foveaAuthoritySemantics: false
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
        scanObjectCost: Int,
        scanObjectsPerRound: Int,
        hotReuseStride: Int
    ) -> SIEVEInterleavedCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        var expectedResident: [Int: Int] = [:]
        for offset in 0..<fillerObjectCount {
            let key = fillerBase + offset
            cache.insert(key, for: key, cost: fillerObjectCost)
            expectedResident[key] = fillerObjectCost
        }
        for offset in 0..<hotObjectCount {
            let key = hotBase + offset
            cache.insert(key, for: key, cost: hotObjectCost)
            expectedResident[key] = hotObjectCost
        }
        precondition(cache.currentCost == costLimit)
        precondition(cache.count == fillerObjectCount + hotObjectCount)
        for offset in 0..<hotObjectCount {
            let key = hotBase + offset
            precondition(cache.value(for: key) == key)
        }

        var scheduledHotRequests = 0
        var hotHits = 0
        var hotMisses = 0
        var firstHotMissRound: Int?
        var hotRefillBytes = 0
        var offeredScanObjects = 0
        var offeredScanBytes = 0
        var scanInsertionsEvictingHot = 0
        var cumulativeHotVictimBytesFromScan = 0
        var cumulativeFillerVictimBytesFromScan = 0
        var cumulativePriorScanVictimBytesFromScan = 0
        var maximumHotVictimBytesInOneScanInsertion = 0
        var incomingScanEverAppearedInOwnForecast = false
        var maximumObservedCost = cache.currentCost
        var maximumObservedCount = cache.count
        var nextScanKey = scanBase

        for round in 0..<rounds {
            if round % hotReuseStride == 0 {
                for offset in 0..<hotObjectCount {
                    let key = hotBase + offset
                    scheduledHotRequests += 1
                    if cache.value(for: key) != nil {
                        hotHits += 1
                    } else {
                        hotMisses += 1
                        if firstHotMissRound == nil { firstHotMissRound = round }
                        let victims = cache.resourceProbeEvictionForecast(incomingCost: hotObjectCost)
                        applyVictims(victims, to: &expectedResident)
                        expectedResident[key] = hotObjectCost
                        cache.insert(key, for: key, cost: hotObjectCost)
                        hotRefillBytes += hotObjectCost
                    }
                    maximumObservedCost = max(maximumObservedCost, cache.currentCost)
                    maximumObservedCount = max(maximumObservedCount, cache.count)
                }
            }

            for _ in 0..<scanObjectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                let victims = cache.resourceProbeEvictionForecast(incomingCost: scanObjectCost)
                let hotVictimBytes = victims.reduce(0) { partial, victim in
                    partial + (identityClass(for: victim.key) == .hot ? victim.cost : 0)
                }
                let fillerVictimBytes = victims.reduce(0) { partial, victim in
                    partial + (identityClass(for: victim.key) == .filler ? victim.cost : 0)
                }
                let priorScanVictimBytes = victims.reduce(0) { partial, victim in
                    partial + (identityClass(for: victim.key) == .scan ? victim.cost : 0)
                }
                if victims.contains(where: { $0.key == key }) {
                    incomingScanEverAppearedInOwnForecast = true
                }
                if hotVictimBytes > 0 { scanInsertionsEvictingHot += 1 }
                cumulativeHotVictimBytesFromScan += hotVictimBytes
                cumulativeFillerVictimBytesFromScan += fillerVictimBytes
                cumulativePriorScanVictimBytesFromScan += priorScanVictimBytes
                maximumHotVictimBytesInOneScanInsertion = max(
                    maximumHotVictimBytesInOneScanInsertion,
                    hotVictimBytes
                )
                applyVictims(victims, to: &expectedResident)
                expectedResident[key] = scanObjectCost
                cache.insert(key, for: key, cost: scanObjectCost)
                offeredScanObjects += 1
                offeredScanBytes += scanObjectCost
                maximumObservedCost = max(maximumObservedCost, cache.currentCost)
                maximumObservedCount = max(maximumObservedCount, cache.count)
            }
        }

        var actualResident: [Int: Int] = [:]
        for offset in 0..<fillerObjectCount {
            let key = fillerBase + offset
            if cache.value(for: key) != nil { actualResident[key] = fillerObjectCost }
        }
        for offset in 0..<hotObjectCount {
            let key = hotBase + offset
            if cache.value(for: key) != nil { actualResident[key] = hotObjectCost }
        }
        for key in scanBase..<nextScanKey {
            if cache.value(for: key) != nil { actualResident[key] = scanObjectCost }
        }
        let finalHotBytes = actualResident.reduce(0) { partial, pair in
            partial + (identityClass(for: pair.key) == .hot ? pair.value : 0)
        }
        let finalFillerBytes = actualResident.reduce(0) { partial, pair in
            partial + (identityClass(for: pair.key) == .filler ? pair.value : 0)
        }
        let finalScanBytes = actualResident.reduce(0) { partial, pair in
            partial + (identityClass(for: pair.key) == .scan ? pair.value : 0)
        }
        let shadowCost = expectedResident.values.reduce(0, +)

        return SIEVEInterleavedCase(
            scanObjectCost: scanObjectCost,
            scanObjectsPerRound: scanObjectsPerRound,
            scanBytesPerRound: scanObjectCost * scanObjectsPerRound,
            hotReuseStride: hotReuseStride,
            rounds: rounds,
            scheduledHotRequests: scheduledHotRequests,
            hotHits: hotHits,
            hotMisses: hotMisses,
            hotHitRatio: Double(hotHits) / Double(max(1, scheduledHotRequests)),
            firstHotMissRound: firstHotMissRound,
            hotRefillBytes: hotRefillBytes,
            offeredScanObjects: offeredScanObjects,
            offeredScanBytes: offeredScanBytes,
            scanInsertionsEvictingHot: scanInsertionsEvictingHot,
            cumulativeHotVictimBytesFromScan: cumulativeHotVictimBytesFromScan,
            cumulativeFillerVictimBytesFromScan: cumulativeFillerVictimBytesFromScan,
            cumulativePriorScanVictimBytesFromScan: cumulativePriorScanVictimBytesFromScan,
            maximumHotVictimBytesInOneScanInsertion: maximumHotVictimBytesInOneScanInsertion,
            finalHotResidentBytes: finalHotBytes,
            finalFillerResidentBytes: finalFillerBytes,
            finalScanResidentBytes: finalScanBytes,
            finalCost: cache.currentCost,
            finalCount: cache.count,
            maximumObservedCost: maximumObservedCost,
            maximumObservedCount: maximumObservedCount,
            shadowResidentIdentityExact: actualResident == expectedResident,
            shadowCostExact: cache.currentCost == shadowCost,
            incomingScanEverAppearedInOwnForecast: incomingScanEverAppearedInOwnForecast
        )
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

    private static func identityClass(for key: Int) -> SIEVEInterleavedIdentityClass {
        if key >= scanBase { return .scan }
        if key >= hotBase { return .hot }
        return .filler
    }
}
