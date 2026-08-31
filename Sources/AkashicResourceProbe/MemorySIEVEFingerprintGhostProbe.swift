import AkashicMemory
import Foundation

enum SIEVEFingerprintGhostTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

enum SIEVEFingerprintGhostPostMode: String, Codable, CaseIterable {
    case oneTouch = "one-touch-scan"
    case delayedSecond32 = "second-touch-gap-32-objects"
    case delayedSecond128 = "second-touch-gap-128-objects"

    var secondTouchGapObjects: Int? {
        switch self {
        case .oneTouch: nil
        case .delayedSecond32: 32
        case .delayedSecond128: 128
        }
    }
}

enum SIEVEFingerprintGhostCollisionMode: String, Codable, CaseIterable {
    case naturalSequential = "natural-sequential"
    /// New scan identities are chosen to have the same low 16 input bits as rotating core keys.
    /// The probe fingerprint uses odd multiplication followed by a low-bit mask, so equality of
    /// the low 16 input bits guarantees a collision at every tested width <= 16 bits.
    case coreAligned16 = "core-aligned-low16"
}

struct SIEVEFingerprintGhostScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int
    var bytesPerRound: Int { objectCost * objectsPerRound }
}

/// Research-only compact-history model.
///
/// Policy state stores only fingerprints. `shadowKeys` is instrumentation that lets the report
/// classify each fingerprint membership result as a true identity match or a collision. Shadow
/// keys are deliberately excluded from the candidate's nominal resource payload claim.
struct SIEVEFingerprintGhost {
    struct Match {
        let matched: Bool
        let exactIdentity: Bool
    }

    private let capacity: Int
    private let fingerprintBits: Int
    private let fingerprintMask: UInt64
    private var fingerprints: [UInt16?]
    private var shadowKeys: [Int?]
    private var cursor = 0
    private(set) var occupiedCount = 0
    private(set) var maximumOccupiedCount = 0

    init(capacity: Int, fingerprintBits: Int) {
        precondition(capacity > 0)
        precondition([4, 8, 12, 16].contains(fingerprintBits))
        self.capacity = capacity
        self.fingerprintBits = fingerprintBits
        fingerprintMask = (UInt64(1) << UInt64(fingerprintBits)) - 1
        fingerprints = Array(repeating: nil, count: capacity)
        shadowKeys = Array(repeating: nil, count: capacity)
    }

    var nominalFingerprintPayloadCapacityBytes: Int {
        capacity * ((fingerprintBits + 7) / 8)
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
        // Odd multiplication is bijective modulo 2^n. It gives a deterministic compact fingerprint
        // while preserving the deliberately constructed low-16 collision control.
        let raw = UInt64(bitPattern: Int64(key)) &* 0x9E37_79B9_7F4A_7C15
        return UInt16(truncatingIfNeeded: raw & fingerprintMask)
    }
}

struct SIEVEFingerprintGhostCase: Codable {
    let topology: String
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let postMode: String
    let collisionMode: String
    let ghostCapacityEntries: Int
    let fingerprintBits: Int
    let nominalFingerprintPayloadCapacityBytes: Int
    let maximumGhostOccupiedEntries: Int

    let prePollutionCoreByteHitRatio: Double
    let prePollutionWarmByteHitRatio: Double
    let recoveryCoreByteHitRatio: Double
    let recoveryWarmByteHitRatio: Double
    let finalWindowCoreByteHitRatio: Double
    let finalWindowWarmByteHitRatio: Double

    let trueHistoryPromotionCount: Int
    let falsePositivePromotionCount: Int
    let trueHistoryPromotionBytes: Int
    let falsePositivePromotionBytes: Int
    let scanFirstRequestFalsePositivePromotionBytes: Int
    let scanLaterRequestFalsePositivePromotionBytes: Int
    let hotFalsePositivePromotionBytes: Int
    let scanSecondRequestBytes: Int
    let scanSecondHitBytes: Int
    let scanSecondMissBytes: Int
    let scanSecondByteHitRatio: Double?
    let finalCost: Int
    let finalCount: Int
}

struct SIEVEFingerprintGhostReport: Codable {
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
    let coreReuseStride: Int
    let warmReuseStride: Int
    let prePollutionRounds: Int
    let recoveryRounds: Int
    let finalWindowRounds: Int
    let ghostCapacitiesEntries: [Int]
    let fingerprintWidthsBits: [Int]
    let topologies: [String]
    let postModes: [String]
    let collisionModes: [String]
    let scanShapes: [[String: Int]]
    let cases: [SIEVEFingerprintGhostCase]
    let allResidentCostsWithinLimit: Bool
    let allGhostEntryBoundsPreserved: Bool
    let forcedCollisionCasesObserveFalsePositivePromotion: Bool
    let claims: Claims
}
