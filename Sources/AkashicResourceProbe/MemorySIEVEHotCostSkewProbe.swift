import AkashicMemory
import Foundation

enum SIEVEHotCostIdentityClass: String, Codable {
    case filler
    case warm
    case core
    case scan
}

enum SIEVEHotCostSeedOrder: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case coreWarmFiller = "core-warm-filler"
    case shuffle17 = "shuffle-17"
    case shuffle73 = "shuffle-73"
}

struct SIEVEHotCostShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int

    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

struct SIEVEHotCostScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

struct SIEVEHotCostCase: Codable {
    let residentShape: String
    let topology: String
    let coreReuseStride: Int
    let warmReuseStride: Int
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let scanBytesPerRound: Int
    let scanTouchesAfterInsert: Int
    let scanBytesBetweenCoreSweeps: Int
    let scanBytesBetweenWarmSweeps: Int
    let coreObjectCount: Int
    let coreObjectCost: Int
    let coreBytes: Int
    let warmObjectCount: Int
    let warmObjectCost: Int
    let warmBytes: Int
    let coreRequestBytes: Int
    let coreHitBytes: Int
    let coreMissBytes: Int
    let coreByteHitRatio: Double
    let coreRefillBytes: Int
    let warmRequestBytes: Int
    let warmHitBytes: Int
    let warmMissBytes: Int
    let warmByteHitRatio: Double
    let warmRefillBytes: Int
    let cumulativeCoreVictimBytesFromScan: Int
    let cumulativeWarmVictimBytesFromScan: Int
    let cumulativeFillerVictimBytesFromScan: Int
    let cumulativePriorScanVictimBytesFromScan: Int
    let finalCoreResidentBytes: Int
    let finalWarmResidentBytes: Int
    let finalFillerResidentBytes: Int
    let finalScanResidentBytes: Int
    let finalCost: Int
    let finalCount: Int
    let forecastMatchedFinalResidents: Bool
    let shadowCostExact: Bool
    let incomingScanEverAppearedInOwnForecast: Bool
}

struct SIEVEHotCostSpread: Codable {
    let topology: String
    let coreReuseStride: Int
    let warmReuseStride: Int
    let scanObjectCost: Int
    let scanBytesPerRound: Int
    let scanTouchesAfterInsert: Int
    let minimumCoreByteHitRatio: Double
    let maximumCoreByteHitRatio: Double
    let coreByteHitRatioSpread: Double
    let minimumWarmByteHitRatio: Double
    let maximumWarmByteHitRatio: Double
    let warmByteHitRatioSpread: Double
    let minimumCoreShape: String
    let maximumCoreShape: String
    let minimumWarmShape: String
    let maximumWarmShape: String
}

struct SIEVEHotCostReport: Codable {
    struct Claims: Codable {
        let cachePolicyEvaluated: Bool
        let productionPolicyRecommendation: Bool
        let formalPerformance: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let fillerObjectCount: Int
    let fillerObjectCost: Int
    let fillerBytes: Int
    let residentShapes: [[String: Int]]
    let topologies: [String]
    let coreReuseStrides: [Int]
    let warmReuseStrides: [Int]
    let scanShapes: [[String: Int]]
    let scanTouchesAfterInsert: [Int]
    let rounds: Int
    let cases: [SIEVEHotCostCase]
    let spreads: [SIEVEHotCostSpread]
    let coreMissCaseCount: Int
    let warmMissCaseCount: Int
    let maximumCoreByteHitRatioSpread: Double
    let maximumWarmByteHitRatioSpread: Double
    let costGranularitySensitivityObserved: Bool
    let allForecastsMatchedFinalResidents: Bool
    let allShadowCostsExact: Bool
    let noIncomingScanAppearedInOwnForecast: Bool
    let claims: Claims
}
