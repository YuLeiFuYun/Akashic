import AkashicMemory
import Foundation

enum SIEVEGhostRefillTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

enum SIEVEGhostRefillPostMode: String, Codable, CaseIterable {
    case hotOnly = "hot-only"
    case oneTouch = "one-touch-scan"
    case immediateSecond = "immediate-second-touch"
    case delayedSecond2 = "second-touch-gap-2-objects"
    case delayedSecond32 = "second-touch-gap-32-objects"
    case delayedSecond128 = "second-touch-gap-128-objects"

    var secondTouchGapObjects: Int? {
        switch self {
        case .hotOnly, .oneTouch:
            nil
        case .immediateSecond:
            0
        case .delayedSecond2:
            2
        case .delayedSecond32:
            32
        case .delayedSecond128:
            128
        }
    }
}

struct SIEVEGhostRefillResidentShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int

    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

struct SIEVEGhostRefillScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

/// Exact, bounded, insertion-order eviction history used only by this research probe.
///
/// `slots` and `positions` keep membership bounded by `capacity`. Removing an entry leaves a hole
/// until the ring cursor reaches it; this can reduce effective history length but can never exceed
/// the configured bound. Allocator/Dictionary overhead is deliberately not claimed by the probe.
struct SIEVERefillGhost {
    private let capacity: Int
    private var slots: [Int?]
    private var positions: [Int: Int] = [:]
    private var cursor = 0
    private(set) var maximumEntryCount = 0

    init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = capacity
        slots = Array(repeating: nil, count: capacity)
    }

    var entryCount: Int { positions.count }
    var keyPayloadCapacityBytes: Int { capacity * MemoryLayout<Int>.stride }

    mutating func recordEviction(_ key: Int) {
        guard capacity > 0 else { return }
        if let oldIndex = positions.removeValue(forKey: key) {
            slots[oldIndex] = nil
        }
        if let displaced = slots[cursor], positions[displaced] == cursor {
            positions.removeValue(forKey: displaced)
        }
        slots[cursor] = key
        positions[key] = cursor
        cursor += 1
        if cursor == capacity { cursor = 0 }
        maximumEntryCount = max(maximumEntryCount, positions.count)
        precondition(positions.count <= capacity)
    }

    mutating func consume(_ key: Int) -> Bool {
        guard let index = positions.removeValue(forKey: key) else { return false }
        if slots[index] == key { slots[index] = nil }
        return true
    }
}

struct SIEVEGhostRefillCase: Codable {
    let residentShape: String
    let topology: String
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let postMode: String
    let ghostCapacityEntries: Int
    let ghostKeyPayloadCapacityBytes: Int
    let maximumGhostEntries: Int
    let finalGhostEntries: Int

    let prePollutionCoreByteHitRatio: Double
    let prePollutionWarmByteHitRatio: Double
    let recoveryCoreByteHitRatio: Double
    let recoveryWarmByteHitRatio: Double
    let finalWindowCoreByteHitRatio: Double
    let finalWindowWarmByteHitRatio: Double
    let coreGhostPromotedRefillBytes: Int
    let warmGhostPromotedRefillBytes: Int
    let scanGhostPromotedRefillBytes: Int
    let scanSecondRequestBytes: Int
    let scanSecondHitBytes: Int
    let scanSecondMissBytes: Int
    let scanSecondByteHitRatio: Double?
    let finalCost: Int
    let finalCount: Int
}

struct SIEVEGhostRefillReport: Codable {
    struct Claims: Codable {
        let cachePolicyMechanismEvaluated: Bool
        let productionPolicyRecommendation: Bool
        let formalPerformance: Bool
        let fullMemoryFootprintQualified: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let coreReuseStride: Int
    let warmReuseStride: Int
    let prePollutionRounds: Int
    let recoveryRounds: Int
    let finalWindowRounds: Int
    let ghostCapacitiesEntries: [Int]
    let residentShapeNames: [String]
    let topologies: [String]
    let scanShapes: [[String: Int]]
    let postModes: [String]
    let cases: [SIEVEGhostRefillCase]
    let allResidentCostsWithinLimit: Bool
    let allGhostEntryBoundsPreserved: Bool
    let zeroCapacityGhostNeverPromotes: Bool
    let claims: Claims
}
