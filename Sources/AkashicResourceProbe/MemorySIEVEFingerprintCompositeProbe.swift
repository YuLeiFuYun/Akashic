import AkashicMemory
import Foundation

enum SIEVEFingerprintCompositeTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

enum SIEVEFingerprintCompositePromotion: String, Codable, CaseIterable {
    case normal = "normal-resident-hit"
    case delayedOne = "delayed-resident-promotion-1"
}

enum SIEVEFingerprintCompositePostMode: String, Codable, CaseIterable {
    case oneTouch = "one-touch-scan"
    case immediateSecond = "immediate-second-touch"
    case delayedSecond32 = "second-touch-gap-32-objects"

    var secondTouchGapObjects: Int? {
        switch self {
        case .oneTouch: nil
        case .immediateSecond: 0
        case .delayedSecond32: 32
        }
    }
}

enum SIEVEFingerprintCompositeCollisionMode: String, Codable, CaseIterable {
    case naturalSequential = "natural-sequential"
    case coreAligned16 = "core-aligned-low16"
}

struct SIEVEFingerprintCompositeScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int
    var bytesPerRound: Int { objectCost * objectsPerRound }
}

/// Candidate state stores only compact fingerprints. `shadowKeys` exists solely to classify
/// membership results as true-history matches versus collisions in this mechanism probe.
struct SIEVEFingerprintCompositeGhost {
    struct Match {
        let matched: Bool
        let exactIdentity: Bool
    }

    private let capacity: Int
    private let fingerprintMask: UInt64
    private var fingerprints: [UInt16?]
    private var shadowKeys: [Int?]
    private var cursor = 0
    private(set) var occupiedCount = 0
    private(set) var maximumOccupiedCount = 0

    init(capacity: Int, fingerprintBits: Int) {
        precondition(capacity > 0)
        precondition([8, 12, 16].contains(fingerprintBits))
        self.capacity = capacity
        fingerprintMask = (UInt64(1) << UInt64(fingerprintBits)) - 1
        fingerprints = Array(repeating: nil, count: capacity)
        shadowKeys = Array(repeating: nil, count: capacity)
    }

    mutating func recordEviction(_ key: Int) {
        if fingerprints[cursor] == nil { occupiedCount += 1 }
        fingerprints[cursor] = fingerprint(key)
        shadowKeys[cursor] = key
        cursor += 1
        if cursor == capacity { cursor = 0 }
        maximumOccupiedCount = max(maximumOccupiedCount, occupiedCount)
        precondition(occupiedCount <= capacity)
    }

    mutating func consume(_ key: Int) -> Match {
        let target = fingerprint(key)
        guard let index = fingerprints.firstIndex(where: { $0 == target }) else {
            return Match(matched: false, exactIdentity: false)
        }
        let exact = shadowKeys[index] == key
        fingerprints[index] = nil
        shadowKeys[index] = nil
        occupiedCount -= 1
        precondition(occupiedCount >= 0)
        return Match(matched: true, exactIdentity: exact)
    }

    private func fingerprint(_ key: Int) -> UInt16 {
        let raw = UInt64(bitPattern: Int64(key)) &* 0x9E37_79B9_7F4A_7C15
        return UInt16(truncatingIfNeeded: raw & fingerprintMask)
    }
}

struct SIEVEFingerprintCompositeCase: Codable {
    let topology: String
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let postMode: String
    let collisionMode: String
    let promotionMode: String
    let ghostCapacityEntries: Int
    let fingerprintBits: Int
    let nominalFingerprintPayloadCapacityBytes: Int
    let maximumGhostOccupiedEntries: Int
    let maximumProbationEntries: Int

    let prePollutionCoreByteHitRatio: Double
    let prePollutionWarmByteHitRatio: Double
    let recoveryCoreByteHitRatio: Double
    let recoveryWarmByteHitRatio: Double
    let finalWindowCoreByteHitRatio: Double
    let finalWindowWarmByteHitRatio: Double

    let trueHistoryPromotionBytes: Int
    let falsePositivePromotionBytes: Int
    let scanFirstFalsePositivePromotionBytes: Int
    let scanLaterFalsePositivePromotionBytes: Int
    let hotFalsePositivePromotionBytes: Int
    let falsePositiveBypassedProbationBytes: Int
    let scanSecondRequestBytes: Int
    let scanSecondHitBytes: Int
    let scanSecondMissBytes: Int
    let scanSecondByteHitRatio: Double?
    let finalCost: Int
    let finalCount: Int
}

struct SIEVEFingerprintCompositeReport: Codable {
    struct Claims: Codable {
        let cachePolicyMechanismEvaluated: Bool
        let productionPolicyRecommendation: Bool
        let formalPerformance: Bool
        let fullMemoryFootprintQualified: Bool
        let fingerprintHashQualityQualified: Bool
        let shardedConcurrencyQualified: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let physicalDedupSemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let prePollutionRounds: Int
    let recoveryRounds: Int
    let finalWindowRounds: Int
    let coreReuseStride: Int
    let warmReuseStride: Int
    let promotionModes: [String]
    let ghostCapacitiesEntries: [Int]
    let fingerprintWidthsBits: [Int]
    let postModes: [String]
    let collisionModes: [String]
    let scanShapes: [[String: Int]]
    let cases: [SIEVEFingerprintCompositeCase]
    let allResidentCostsWithinLimit: Bool
    let allGhostEntryBoundsPreserved: Bool
    let forcedCollisionDelayedCasesBypassProbation: Bool
    let claims: Claims
}
