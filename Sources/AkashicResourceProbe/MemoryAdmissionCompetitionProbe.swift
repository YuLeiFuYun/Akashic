import AkashicMemory
import Foundation

enum AdmissionCompetitionRole: String, Codable, Sendable {
    case core
    case warm
    case anchor
    case holder
    case stream
    case burst
    case phaseA
    case phaseB
    case small
    case giant
}

struct AdmissionCompetitionRequest: Sendable {
    let key: Int
    let cost: Int
    let role: AdmissionCompetitionRole
    let measure: Bool

    init(key: Int, cost: Int, role: AdmissionCompetitionRole, measure: Bool = true) {
        self.key = key
        self.cost = cost
        self.role = role
        self.measure = measure
    }
}

struct AdmissionCompetitionMetric: Codable {
    var requests = 0
    var requestBytes = 0
    var hits = 0
    var hitBytes = 0

    var hitRatio: Double { Double(hits) / Double(max(1, requests)) }
    var byteHitRatio: Double { Double(hitBytes) / Double(max(1, requestBytes)) }

    mutating func record(hit: Bool, cost: Int) {
        requests += 1
        requestBytes += cost
        if hit {
            hits += 1
            hitBytes += cost
        }
    }
}

struct AdmissionCompetitionPolicyResult: Codable {
    let policy: String
    let workload: String
    let total: AdmissionCompetitionMetric
    let byRole: [String: AdmissionCompetitionMetric]
    let maximumResidentCost: Int
    let finalResidentCost: Int
    let metadataBytes: Int
    let agingPasses: Int
    let maximumCounter: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
    let maximumProtectedSecondHitBytes: Int
    let provisionalRevocations: Int
    let provisionalConfirmations: Int
    let fullVisitedEpochResets: Int
    let densityDeniedPromotions: Int
}

struct AdmissionCompetitionPair: Codable {
    let workload: String
    let policy: String
    let baselineCoreByteHitRatio: Double?
    let policyCoreByteHitRatio: Double?
    let baselineWarmByteHitRatio: Double?
    let policyWarmByteHitRatio: Double?
    let baselineStreamByteHitRatio: Double?
    let policyStreamByteHitRatio: Double?
    let baselineBurstByteHitRatio: Double?
    let policyBurstByteHitRatio: Double?
    let baselinePhaseBByteHitRatio: Double?
    let policyPhaseBByteHitRatio: Double?
    let totalByteHitRatioDelta: Double
}

struct AdmissionCompetitionCollision: Codable {
    let width: Int
    let target: Int
    let colliders: [Int]
    let exactTargetCount: Int
    let sketchTargetEstimate: Int
    let falseHotCreated: Bool
}

struct AdmissionCompetitionReport: Codable {
    struct Claims: Codable {
        let productionPolicyRecommendation: Bool
        let formalPerformance: Bool
        let memoryFootprintQualified: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let windowLimit: Int
    let workloads: [String]
    let policies: [String]
    let results: [AdmissionCompetitionPolicyResult]
    let comparisonsAgainstBaseline: [AdmissionCompetitionPair]
    let collisions: [AdmissionCompetitionCollision]
    let checks: [String: Bool]
    let claims: Claims
}

protocol AdmissionCompetitionPolicy: AnyObject {
    var name: String { get }
    var currentCost: Int { get }
    var maximumResidentCost: Int { get }
    var metadataBytes: Int { get }
    var agingPasses: Int { get }
    var maximumCounter: Int { get }
    var maximumVictimCount: Int { get }
    var maximumVictimCost: Int { get }
    var maximumProtectedSecondHitBytes: Int { get }
    var provisionalRevocations: Int { get }
    var provisionalConfirmations: Int { get }
    var fullVisitedEpochResets: Int { get }
    var densityDeniedPromotions: Int { get }

    func prepare(requests: [AdmissionCompetitionRequest])
    func seed(_ requests: [AdmissionCompetitionRequest])
    func request(_ request: AdmissionCompetitionRequest) -> Bool
}

extension AdmissionCompetitionPolicy {
    var provisionalRevocations: Int { 0 }
    var provisionalConfirmations: Int { 0 }
    var fullVisitedEpochResets: Int { 0 }
    var densityDeniedPromotions: Int { 0 }
    func prepare(requests: [AdmissionCompetitionRequest]) {}
}
enum MemoryAdmissionCompetitionProbe {}
