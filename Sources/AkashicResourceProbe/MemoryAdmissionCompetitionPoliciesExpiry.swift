import AkashicMemory
import Foundation

final class PhysicalExpirySecondHitCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let secondHitBudget: Int
    private let pressureTTL: Int
    private let cache: MemoryCache<Int, Int>
    private var probationHits: [Int: UInt8] = [:]
    private var provisionalProtection: [Int: ExpiringSecondHitProtection] = [:]
    private var protectedSecondHitBytes = 0
    private var pressureVolume = 0
    private(set) var maximumProtectedSecondHitBytes = 0
    private(set) var maximumResidentCost = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0
    private(set) var provisionalRevocations = 0
    private(set) var provisionalConfirmations = 0

    init(limit: Int, secondHitBudget: Int, pressureTTL: Int) {
        precondition(secondHitBudget >= 0 && secondHitBudget <= limit)
        precondition(pressureTTL >= 0)
        self.limit = limit
        self.secondHitBudget = secondHitBudget
        self.pressureTTL = pressureTTL
        cache = MemoryCache(costLimit: limit)
        name = "physical-expiring-second-hit-b\(secondHitBudget)-p\(pressureTTL)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical payload only. Dictionary allocator/table footprint is intentionally excluded.
    var metadataBytes: Int { probationHits.count + provisionalProtection.count * 3 }
    var agingPasses: Int { 0 }
    var maximumCounter: Int { probationHits.values.map(Int.init).max() ?? 0 }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        for request in requests {
            cache.insert(request.key, for: request.key, cost: request.cost)
            if request.role == .core || request.role == .warm {
                precondition(cache.value(for: request.key) != nil)
            } else {
                probationHits[request.key] = 0
            }
        }
        precondition(cache.currentCost == limit)
        maximumResidentCost = cache.currentCost
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        if let protection = provisionalProtection[request.key] {
            let hit = cache.value(for: request.key) != nil
            releaseProtectedBudget(for: request.key, expected: protection)
            if hit {
                provisionalConfirmations += 1
                return true
            }
        }

        if let hits = probationHits[request.key] {
            if hits == 0 {
                if cache.resourceProbeValueWithoutVisit(for: request.key) != nil {
                    if pressureTTL > 0,
                       request.cost <= secondHitBudget,
                       protectedSecondHitBytes <= secondHitBudget - request.cost,
                       cache.resourceProbeMarkVisited(for: request.key)
                    {
                        probationHits.removeValue(forKey: request.key)
                        let expiry = pressureVolume > Int.max - pressureTTL
                            ? Int.max
                            : pressureVolume + pressureTTL
                        provisionalProtection[request.key] = ExpiringSecondHitProtection(
                            cost: request.cost,
                            expiryPressure: expiry
                        )
                        protectedSecondHitBytes += request.cost
                        maximumProtectedSecondHitBytes = max(
                            maximumProtectedSecondHitBytes,
                            protectedSecondHitBytes
                        )
                        precondition(protectedSecondHitBytes <= secondHitBudget)
                    } else {
                        probationHits[request.key] = 1
                    }
                    return true
                }
                probationHits.removeValue(forKey: request.key)
            } else {
                if cache.value(for: request.key) != nil {
                    probationHits.removeValue(forKey: request.key)
                    return true
                }
                probationHits.removeValue(forKey: request.key)
            }
        } else if cache.value(for: request.key) != nil {
            return true
        }

        advancePressureBeforeInsertion(cost: request.cost)
        insertProbationary(request)
        maximumResidentCost = max(maximumResidentCost, cache.currentCost)
        return false
    }

    private func advancePressureBeforeInsertion(cost: Int) {
        guard cost <= limit else { return }
        let delta = max(1, cost)
        pressureVolume = pressureVolume > Int.max - delta ? Int.max : pressureVolume + delta
        let expired = provisionalProtection.compactMap { key, protection in
            protection.expiryPressure <= pressureVolume ? (key, protection) : nil
        }
        for (key, protection) in expired {
            if cache.resourceProbeValueWithoutVisit(for: key) != nil {
                cache.remove(key)
                provisionalRevocations += 1
            }
            releaseProtectedBudget(for: key, expected: protection)
        }
    }

    private func insertProbationary(_ request: AdmissionCompetitionRequest) {
        guard request.cost <= limit else { return }
        let victims = cache.resourceProbeEvictionForecast(incomingCost: request.cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        for victim in victims { removeAuxiliaryState(for: victim.key) }
        cache.insert(request.key, for: request.key, cost: request.cost)
        probationHits[request.key] = 0
    }

    private func removeAuxiliaryState(for key: Int) {
        probationHits.removeValue(forKey: key)
        if let protection = provisionalProtection[key] {
            releaseProtectedBudget(for: key, expected: protection)
        }
    }

    private func releaseProtectedBudget(
        for key: Int,
        expected: ExpiringSecondHitProtection
    ) {
        guard let removed = provisionalProtection.removeValue(forKey: key) else { return }
        precondition(removed.cost == expected.cost)
        precondition(removed.expiryPressure == expected.expiryPressure)
        protectedSecondHitBytes -= removed.cost
        precondition(protectedSecondHitBytes >= 0)
    }
}

final class CohortPromotionCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let pendingLimit: Int
    private let quietEstablishedHitsRequired: Int
    private let cache: MemoryCache<Int, Int>
    private var probationHits: [Int: UInt8] = [:]
    private var pendingPromotion: [Int] = []
    private var suppressCohort = false
    private var quietEstablishedHits = 0
    private(set) var maximumResidentCost = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(limit: Int, pendingLimit: Int, quietEstablishedHitsRequired: Int) {
        precondition(pendingLimit > 0)
        precondition(quietEstablishedHitsRequired > 0)
        self.limit = limit
        self.pendingLimit = pendingLimit
        self.quietEstablishedHitsRequired = quietEstablishedHitsRequired
        cache = MemoryCache(costLimit: limit)
        name = "cohort-p\(pendingLimit)-q\(quietEstablishedHitsRequired)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical resident-state bytes only; Dictionary/Array allocation is not claimed.
    var metadataBytes: Int { probationHits.count + pendingPromotion.count }
    var agingPasses: Int { 0 }
    var maximumCounter: Int { probationHits.values.map(Int.init).max() ?? 0 }
    var maximumProtectedSecondHitBytes: Int { 0 }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        for request in requests {
            cache.insert(request.key, for: request.key, cost: request.cost)
            if request.role == .core || request.role == .warm {
                precondition(cache.value(for: request.key) != nil)
            } else {
                probationHits[request.key] = 0
            }
        }
        precondition(cache.currentCost == limit)
        maximumResidentCost = cache.currentCost
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        if let hits = probationHits[request.key] {
            if hits == 0 {
                if cache.resourceProbeValueWithoutVisit(for: request.key) != nil {
                    probationHits[request.key] = 1
                    observeProbationarySecondHit(request.key)
                    return true
                }
                removeAuxiliaryState(for: request.key)
            } else {
                if cache.value(for: request.key) != nil {
                    removeAuxiliaryState(for: request.key)
                    observeEstablishedHit()
                    return true
                }
                removeAuxiliaryState(for: request.key)
            }
        } else if cache.value(for: request.key) != nil {
            observeEstablishedHit()
            return true
        }

        insertProbationary(request)
        maximumResidentCost = max(maximumResidentCost, cache.currentCost)
        return false
    }

    private func observeProbationarySecondHit(_ key: Int) {
        quietEstablishedHits = 0
        guard !suppressCohort else { return }
        pendingPromotion.append(key)
        if pendingPromotion.count > pendingLimit {
            pendingPromotion.removeAll(keepingCapacity: true)
            suppressCohort = true
        }
    }

    private func observeEstablishedHit() {
        if suppressCohort {
            quietEstablishedHits += 1
            if quietEstablishedHits >= quietEstablishedHitsRequired {
                suppressCohort = false
                quietEstablishedHits = 0
            }
            return
        }
        guard !pendingPromotion.isEmpty else {
            quietEstablishedHits = 0
            return
        }
        quietEstablishedHits += 1
        guard quietEstablishedHits >= quietEstablishedHitsRequired else { return }
        for key in pendingPromotion {
            if cache.resourceProbeMarkVisited(for: key) {
                probationHits.removeValue(forKey: key)
            }
        }
        pendingPromotion.removeAll(keepingCapacity: true)
        quietEstablishedHits = 0
    }

    private func insertProbationary(_ request: AdmissionCompetitionRequest) {
        guard request.cost <= limit else { return }
        let victims = cache.resourceProbeEvictionForecast(incomingCost: request.cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        for victim in victims { removeAuxiliaryState(for: victim.key) }
        cache.insert(request.key, for: request.key, cost: request.cost)
        probationHits[request.key] = 0
    }

    private func removeAuxiliaryState(for key: Int) {
        probationHits.removeValue(forKey: key)
        if let index = pendingPromotion.firstIndex(of: key) {
            pendingPromotion.remove(at: index)
        }
    }
}

final class ExactTwoHitCompetitionPolicy: AdmissionCompetitionPolicy {
    let name = "exact-two-hit-gate"
    private let limit: Int
    private let cache: MemoryCache<Int, Int>
    private var observations: [Int: Int] = [:]
    private(set) var maximumResidentCost = 0

    init(limit: Int) {
        self.limit = limit
        cache = MemoryCache(costLimit: limit)
    }

    var currentCost: Int { cache.currentCost }
    var metadataBytes: Int { observations.count * MemoryLayout<Int>.stride * 2 }
    var agingPasses: Int { 0 }
    var maximumCounter: Int { observations.values.max() ?? 0 }
    var maximumVictimCount: Int { 0 }
    var maximumVictimCost: Int { 0 }
    var maximumProtectedSecondHitBytes: Int { 0 }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        for request in requests {
            cache.insert(request.key, for: request.key, cost: request.cost)
            observations[request.key] = 2
        }
        precondition(cache.currentCost == limit)
        maximumResidentCost = cache.currentCost
        for request in requests where request.role == .core || request.role == .warm {
            precondition(cache.value(for: request.key) != nil)
        }
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        observations[request.key, default: 0] += 1
        if cache.value(for: request.key) != nil {
            maximumResidentCost = max(maximumResidentCost, cache.currentCost)
            return true
        }
        if observations[request.key, default: 0] >= 2 {
            cache.insert(request.key, for: request.key, cost: request.cost)
        }
        maximumResidentCost = max(maximumResidentCost, cache.currentCost)
        return false
    }
}

struct AdmissionCompetitionWindowEntry {
    let value: Int
    let cost: Int
}

struct AdmissionCompetitionSketch {
    static let rows = 4
    private static let seeds: [UInt64] = [
        0x9e3779b97f4a7c15,
        0xbf58476d1ce4e5b9,
        0x94d049bb133111eb,
        0xd6e8feb86659fd93,
    ]

    let width: Int
    private(set) var counters: [UInt8]
    private(set) var maximumCounter: UInt8 = 0

    init(width: Int) {
        precondition(width > 0)
        self.width = width
        counters = Array(repeating: 0, count: Self.rows * width)
    }

    mutating func increment(_ key: Int) {
        for row in 0..<Self.rows {
            let offset = row * width + index(key, row: row)
            if counters[offset] < UInt8.max { counters[offset] &+= 1 }
            maximumCounter = max(maximumCounter, counters[offset])
        }
    }

    func estimate(_ key: Int) -> Int {
        var result = Int.max
        for row in 0..<Self.rows {
            result = min(result, Int(counters[row * width + index(key, row: row)]))
        }
        return result == Int.max ? 0 : result
    }

    mutating func halve() {
        for index in counters.indices { counters[index] >>= 1 }
    }

    func position(_ key: Int, row: Int) -> Int { index(key, row: row) }

    private func index(_ key: Int, row: Int) -> Int {
        let raw = UInt64(bitPattern: Int64(key)) ^ Self.seeds[row]
        var value = raw &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return Int(value % UInt64(width))
    }
}
