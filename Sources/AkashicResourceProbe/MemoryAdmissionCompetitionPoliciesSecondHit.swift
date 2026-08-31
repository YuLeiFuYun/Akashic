import AkashicMemory
import Foundation

final class HandRevokedSecondHitCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let secondHitBudget: Int
    private let cache: MemoryCache<Int, Int>
    private var probationHits: [Int: UInt8] = [:]
    private var provisionalProtectedCost: [Int: Int] = [:]
    private var protectedSecondHitBytes = 0
    private(set) var maximumProtectedSecondHitBytes = 0
    private(set) var maximumResidentCost = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0
    private(set) var provisionalRevocations = 0
    private(set) var provisionalConfirmations = 0

    init(limit: Int, secondHitBudget: Int) {
        precondition(secondHitBudget >= 0 && secondHitBudget <= limit)
        self.limit = limit
        self.secondHitBudget = secondHitBudget
        cache = MemoryCache(costLimit: limit)
        name = "hand-revoked-second-hit-b\(secondHitBudget)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical state payload only. Dictionary allocator/table footprint is intentionally excluded.
    var metadataBytes: Int { probationHits.count + provisionalProtectedCost.count * 2 }
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
        if let protectedCost = provisionalProtectedCost[request.key] {
            let hit = cache.value(for: request.key) != nil
            releaseProtectedBudget(for: request.key, expectedCost: protectedCost)
            if hit {
                provisionalConfirmations += 1
                return true
            }
        }

        if let hits = probationHits[request.key] {
            if hits == 0 {
                if cache.resourceProbeValueWithoutVisit(for: request.key) != nil {
                    if request.cost <= secondHitBudget,
                       protectedSecondHitBytes <= secondHitBudget - request.cost,
                       cache.resourceProbeMarkVisited(for: request.key)
                    {
                        probationHits.removeValue(forKey: request.key)
                        provisionalProtectedCost[request.key] = request.cost
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

        insertProbationary(request)
        maximumResidentCost = max(maximumResidentCost, cache.currentCost)
        return false
    }

    private func insertProbationary(_ request: AdmissionCompetitionRequest) {
        guard request.cost <= limit else { return }

        // First simulate the exact production hand path without mutation. A provisional second-hit
        // lease ends at the first hand encounter that would otherwise consume its visited bit and
        // grant an extra second chance. Established/non-provisional visited entries are untouched.
        let trace = cache.resourceProbeEvictionTrace(incomingCost: request.cost)
        for key in trace.clearedVisitedKeys {
            guard let cost = provisionalProtectedCost[key] else { continue }
            precondition(cache.resourceProbeClearVisited(for: key))
            releaseProtectedBudget(for: key, expectedCost: cost)
            provisionalRevocations += 1
        }

        // Revoking a provisional second-chance can change the victim set, so recompute from the
        // actual post-revocation state before synchronizing auxiliary metadata and inserting.
        let victims = cache.resourceProbeEvictionForecast(incomingCost: request.cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        for victim in victims { removeAuxiliaryState(for: victim.key) }
        cache.insert(request.key, for: request.key, cost: request.cost)
        probationHits[request.key] = 0
    }

    private func removeAuxiliaryState(for key: Int) {
        probationHits.removeValue(forKey: key)
        if let cost = provisionalProtectedCost[key] {
            releaseProtectedBudget(for: key, expectedCost: cost)
        }
    }

    private func releaseProtectedBudget(for key: Int, expectedCost: Int) {
        guard let removed = provisionalProtectedCost.removeValue(forKey: key) else { return }
        precondition(removed == expectedCost)
        protectedSecondHitBytes -= removed
        precondition(protectedSecondHitBytes >= 0)
    }
}

/// Research-only challenger for the hand-coupled lease model above. The batch variant revokes every
/// provisional key named by one pre-mutation shadow trace. This fixed-point variant revokes only the
/// first provisional key the current hand would consume, then recomputes the path from the mutated
/// state. Repeating until no provisional clear remains gives the minimal revocation set for this
/// insertion under the stated "lease ends at first hand encounter" semantics.
final class FixedPointHandRevokedSecondHitCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let secondHitBudget: Int
    private let cache: MemoryCache<Int, Int>
    private var probationHits: [Int: UInt8] = [:]
    private var provisionalProtectedCost: [Int: Int] = [:]
    private var protectedSecondHitBytes = 0
    private(set) var maximumProtectedSecondHitBytes = 0
    private(set) var maximumResidentCost = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0
    private(set) var provisionalRevocations = 0
    private(set) var provisionalConfirmations = 0

    init(limit: Int, secondHitBudget: Int) {
        precondition(secondHitBudget >= 0 && secondHitBudget <= limit)
        self.limit = limit
        self.secondHitBudget = secondHitBudget
        cache = MemoryCache(costLimit: limit)
        name = "hand-fixedpoint-revoked-second-hit-b\(secondHitBudget)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical state payload only. Dictionary allocator/table footprint is intentionally excluded.
    var metadataBytes: Int { probationHits.count + provisionalProtectedCost.count * 2 }
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
        if let protectedCost = provisionalProtectedCost[request.key] {
            let hit = cache.value(for: request.key) != nil
            releaseProtectedBudget(for: request.key, expectedCost: protectedCost)
            if hit {
                provisionalConfirmations += 1
                return true
            }
        }

        if let hits = probationHits[request.key] {
            if hits == 0 {
                if cache.resourceProbeValueWithoutVisit(for: request.key) != nil {
                    if request.cost <= secondHitBudget,
                       protectedSecondHitBytes <= secondHitBudget - request.cost,
                       cache.resourceProbeMarkVisited(for: request.key)
                    {
                        probationHits.removeValue(forKey: request.key)
                        provisionalProtectedCost[request.key] = request.cost
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

        insertProbationary(request)
        maximumResidentCost = max(maximumResidentCost, cache.currentCost)
        return false
    }

    private func insertProbationary(_ request: AdmissionCompetitionRequest) {
        guard request.cost <= limit else { return }

        while true {
            let trace = cache.resourceProbeEvictionTrace(incomingCost: request.cost)
            guard let key = trace.clearedVisitedKeys.first(where: {
                provisionalProtectedCost[$0] != nil
            }), let cost = provisionalProtectedCost[key]
            else { break }

            precondition(cache.resourceProbeClearVisited(for: key))
            releaseProtectedBudget(for: key, expectedCost: cost)
            provisionalRevocations += 1
        }

        let victims = cache.resourceProbeEvictionForecast(incomingCost: request.cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        for victim in victims { removeAuxiliaryState(for: victim.key) }
        cache.insert(request.key, for: request.key, cost: request.cost)
        probationHits[request.key] = 0
    }

    private func removeAuxiliaryState(for key: Int) {
        probationHits.removeValue(forKey: key)
        if let cost = provisionalProtectedCost[key] {
            releaseProtectedBudget(for: key, expectedCost: cost)
        }
    }

    private func releaseProtectedBudget(for key: Int, expectedCost: Int) {
        guard let removed = provisionalProtectedCost.removeValue(forKey: key) else { return }
        precondition(removed == expectedCost)
        protectedSecondHitBytes -= removed
        precondition(protectedSecondHitBytes >= 0)
    }
}

struct ExpiringSecondHitProtection {
    let cost: Int
    let expiryPressure: Int
}

final class ExpiringSecondHitCompetitionPolicy: AdmissionCompetitionPolicy {
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

    init(limit: Int, secondHitBudget: Int, pressureTTL: Int) {
        precondition(secondHitBudget >= 0 && secondHitBudget <= limit)
        precondition(pressureTTL >= 0)
        self.limit = limit
        self.secondHitBudget = secondHitBudget
        self.pressureTTL = pressureTTL
        cache = MemoryCache(costLimit: limit)
        name = "expiring-second-hit-b\(secondHitBudget)-p\(pressureTTL)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical payload only. Dictionary allocator/table footprint is intentionally not claimed.
    var metadataBytes: Int {
        probationHits.count + provisionalProtection.count * 3
    }
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
            if hit { return true }
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
            _ = cache.resourceProbeClearVisited(for: key)
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

/// Research-only physical-residency counterpart to `ExpiringSecondHitCompetitionPolicy`.
///
/// The bit-expiry policy only clears a provisional key's SIEVE visited bit. Once the hand has
/// already consumed that bit and moved past the key, later bit expiry need not bound the key's
/// physical residency. This challenger makes the stronger resource contract explicit: when the
/// pressure lease expires, a still-resident provisional key is physically removed before the
/// incoming miss is inserted. That can bound speculative resident bytes, but it can also destroy
/// a future third hit and cannot retroactively undo collateral eviction already caused when the
/// second chance was consumed. It is therefore a falsification control, not a production policy.
