import AkashicMemory
import Foundation

private struct SIEVEBytePartitionInsertion: Codable {
    let index: Int
    let incomingCost: Int
    let hotVictimCount: Int
    let hotVictimBytes: Int
    let priorColdVictimCount: Int
    let priorColdVictimBytes: Int
    let incomingAppearedInOwnForecast: Bool
    let beforeCost: Int
    let forecastVictimBytes: Int
    let afterCost: Int
}

private struct SIEVEBytePartitionCase: Codable {
    let totalOfferedColdBytes: Int
    let coldObjectCount: Int
    let coldObjectCost: Int
    let hotResidentCount: Int
    let hotResidentBytes: Int
    let coldResidentCount: Int
    let coldResidentBytes: Int
    let hotByteSurvival: Double
    let finalCost: Int
    let finalCount: Int
    let forecastMatchedFinalResidents: Bool
    let allInsertionCostTransitionsExact: Bool
    let incomingEverAppearedInOwnForecast: Bool
    let insertions: [SIEVEBytePartitionInsertion]
}

private struct SIEVEBytePartitionSpread: Codable {
    let totalOfferedColdBytes: Int
    let minimumHotByteSurvival: Double
    let maximumHotByteSurvival: Double
    let survivalSpread: Double
    let minimumSurvivalObjectCount: Int
    let maximumSurvivalObjectCount: Int
}

private struct SIEVEBytePartitionReport: Codable {
    struct Claims: Codable {
        let productionAdmissionRecommendation: Bool
        let formalPerformance: Bool
        let shardedConcurrencyQualified: Bool
        let foveaAuthoritySemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let hotObjectCount: Int
    let hotObjectCost: Int
    let hotBytesBefore: Int
    let cases: [SIEVEBytePartitionCase]
    let spreads: [SIEVEBytePartitionSpread]
    let direct128HotByteSurvival: Double
    let direct256HotByteSurvival: Double
    let modelSingleLarge128HotByteSurvival: Double
    let modelSingleLarge256HotByteSurvival: Double
    let currentSwiftFalsifiesSingleLargeModelWitness: Bool
    let partitionSensitivityObserved: Bool
    let allForecastsMatchedFinalResidents: Bool
    let allInsertionCostTransitionsExact: Bool
    let noIncomingAppearedInOwnForecast: Bool
    let claims: Claims
}

enum MemorySIEVEBytePartitionProbe {
    private static let costLimit = 1_024
    private static let hotObjectCount = 256
    private static let hotObjectCost = 4
    private static let coldKeyBase = 100_000

    static func run() throws {
        let totalColdBytes = [128, 256, 512, 1_024]
        let objectCounts = [1, 2, 4, 8, 16, 32]
        var cases: [SIEVEBytePartitionCase] = []
        for total in totalColdBytes {
            for count in objectCounts where total % count == 0 {
                cases.append(runCase(totalOfferedColdBytes: total, coldObjectCount: count))
            }
        }

        let spreads = totalColdBytes.map { total -> SIEVEBytePartitionSpread in
            let rows = cases.filter { $0.totalOfferedColdBytes == total }
            let minimum = rows.min { lhs, rhs in lhs.hotByteSurvival < rhs.hotByteSurvival }!
            let maximum = rows.max { lhs, rhs in lhs.hotByteSurvival < rhs.hotByteSurvival }!
            return SIEVEBytePartitionSpread(
                totalOfferedColdBytes: total,
                minimumHotByteSurvival: minimum.hotByteSurvival,
                maximumHotByteSurvival: maximum.hotByteSurvival,
                survivalSpread: maximum.hotByteSurvival - minimum.hotByteSurvival,
                minimumSurvivalObjectCount: minimum.coldObjectCount,
                maximumSurvivalObjectCount: maximum.coldObjectCount
            )
        }

        let direct128 = cases.first {
            $0.totalOfferedColdBytes == 128 && $0.coldObjectCount == 1
        }!
        let direct256 = cases.first {
            $0.totalOfferedColdBytes == 256 && $0.coldObjectCount == 1
        }!
        let report = SIEVEBytePartitionReport(
            schemaVersion: 1,
            costLimit: costLimit,
            hotObjectCount: hotObjectCount,
            hotObjectCost: hotObjectCost,
            hotBytesBefore: hotObjectCount * hotObjectCost,
            cases: cases,
            spreads: spreads,
            direct128HotByteSurvival: direct128.hotByteSurvival,
            direct256HotByteSurvival: direct256.hotByteSurvival,
            modelSingleLarge128HotByteSurvival: 1.0,
            modelSingleLarge256HotByteSurvival: 1.0,
            currentSwiftFalsifiesSingleLargeModelWitness:
                direct128.hotByteSurvival < 1.0 || direct256.hotByteSurvival < 1.0,
            partitionSensitivityObserved: spreads.contains { $0.survivalSpread > 0 },
            allForecastsMatchedFinalResidents: cases.allSatisfy(\.forecastMatchedFinalResidents),
            allInsertionCostTransitionsExact: cases.allSatisfy(\.allInsertionCostTransitionsExact),
            noIncomingAppearedInOwnForecast: cases.allSatisfy {
                !$0.incomingEverAppearedInOwnForecast
            },
            claims: .init(
                productionAdmissionRecommendation: false,
                formalPerformance: false,
                shardedConcurrencyQualified: false,
                foveaAuthoritySemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))

        guard report.allForecastsMatchedFinalResidents,
            report.allInsertionCostTransitionsExact,
            report.noIncomingAppearedInOwnForecast
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        totalOfferedColdBytes: Int,
        coldObjectCount: Int
    ) -> SIEVEBytePartitionCase {
        precondition(totalOfferedColdBytes % coldObjectCount == 0)
        let coldObjectCost = totalOfferedColdBytes / coldObjectCount
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        var expectedResident: [Int: Int] = [:]

        for key in 0..<hotObjectCount {
            cache.insert(key, for: key, cost: hotObjectCost)
            expectedResident[key] = hotObjectCost
        }
        precondition(cache.currentCost == costLimit)
        for key in 0..<hotObjectCount {
            precondition(cache.value(for: key) == key)
        }

        var insertions: [SIEVEBytePartitionInsertion] = []
        var allTransitionsExact = true
        var incomingEverForecast = false

        for index in 0..<coldObjectCount {
            let key = coldKeyBase + index
            let beforeCost = cache.currentCost
            let victims = cache.resourceProbeEvictionForecast(incomingCost: coldObjectCost)
            let incomingInForecast = victims.contains { $0.key == key }
            incomingEverForecast = incomingEverForecast || incomingInForecast
            let hotVictims = victims.filter { $0.key >= 0 && $0.key < hotObjectCount }
            let coldVictims = victims.filter { $0.key >= coldKeyBase }
            let victimBytes = victims.reduce(0) { $0 + $1.cost }
            for victim in victims { expectedResident.removeValue(forKey: victim.key) }
            expectedResident[key] = coldObjectCost

            cache.insert(key, for: key, cost: coldObjectCost)
            let afterCost = cache.currentCost
            let expectedAfter = beforeCost - victimBytes + coldObjectCost
            allTransitionsExact = allTransitionsExact && afterCost == expectedAfter
            insertions.append(
                SIEVEBytePartitionInsertion(
                    index: index,
                    incomingCost: coldObjectCost,
                    hotVictimCount: hotVictims.count,
                    hotVictimBytes: hotVictims.reduce(0) { $0 + $1.cost },
                    priorColdVictimCount: coldVictims.count,
                    priorColdVictimBytes: coldVictims.reduce(0) { $0 + $1.cost },
                    incomingAppearedInOwnForecast: incomingInForecast,
                    beforeCost: beforeCost,
                    forecastVictimBytes: victimBytes,
                    afterCost: afterCost
                )
            )
        }

        var actualResident: [Int: Int] = [:]
        for key in 0..<hotObjectCount {
            if cache.value(for: key) != nil { actualResident[key] = hotObjectCost }
        }
        for index in 0..<coldObjectCount {
            let key = coldKeyBase + index
            if cache.value(for: key) != nil { actualResident[key] = coldObjectCost }
        }
        let hotResidentCount = actualResident.keys.filter { $0 < hotObjectCount }.count
        let coldResidentCount = actualResident.keys.filter { $0 >= coldKeyBase }.count
        let hotResidentBytes = hotResidentCount * hotObjectCost
        let coldResidentBytes = coldResidentCount * coldObjectCost

        return SIEVEBytePartitionCase(
            totalOfferedColdBytes: totalOfferedColdBytes,
            coldObjectCount: coldObjectCount,
            coldObjectCost: coldObjectCost,
            hotResidentCount: hotResidentCount,
            hotResidentBytes: hotResidentBytes,
            coldResidentCount: coldResidentCount,
            coldResidentBytes: coldResidentBytes,
            hotByteSurvival: Double(hotResidentBytes) / Double(costLimit),
            finalCost: cache.currentCost,
            finalCount: cache.count,
            forecastMatchedFinalResidents: actualResident == expectedResident,
            allInsertionCostTransitionsExact: allTransitionsExact,
            incomingEverAppearedInOwnForecast: incomingEverForecast,
            insertions: insertions
        )
    }
}
