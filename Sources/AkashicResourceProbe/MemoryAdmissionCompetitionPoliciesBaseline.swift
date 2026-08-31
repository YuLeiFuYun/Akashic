import AkashicMemory
import Foundation

final class BaselineSIEVECompetitionPolicy: AdmissionCompetitionPolicy {
    let name = "baseline-sieve"
    private let limit: Int
    private let cache: MemoryCache<Int, Int>
    private(set) var maximumResidentCost = 0

    init(limit: Int) {
        self.limit = limit
        cache = MemoryCache(costLimit: limit)
    }

    var currentCost: Int { cache.currentCost }
    var metadataBytes: Int { 0 }
    var agingPasses: Int { 0 }
    var maximumCounter: Int { 0 }
    var maximumVictimCount: Int { 0 }
    var maximumVictimCost: Int { 0 }
    var maximumProtectedSecondHitBytes: Int { 0 }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        for request in requests {
            cache.insert(request.key, for: request.key, cost: request.cost)
        }
        precondition(cache.currentCost == limit)
        maximumResidentCost = cache.currentCost
        for request in requests where request.role == .core || request.role == .warm {
            precondition(cache.value(for: request.key) != nil)
        }
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        if cache.value(for: request.key) != nil {
            maximumResidentCost = max(maximumResidentCost, cache.currentCost)
            return true
        }
        cache.insert(request.key, for: request.key, cost: request.cost)
        maximumResidentCost = max(maximumResidentCost, cache.currentCost)
        return false
    }
}

final class DelayedPromotionCompetitionPolicy: AdmissionCompetitionPolicy {
    let name = "delayed-promotion-1"
    private let limit: Int
    private let cache: MemoryCache<Int, Int>
    /// Only resident probationary keys are retained here. Forecasted victims are removed before
    /// every insertion, so the research state is bounded by cache resident count rather than
    /// request-history cardinality.
    private var probationHits: [Int: UInt8] = [:]
    private(set) var maximumResidentCost = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(limit: Int) {
        self.limit = limit
        cache = MemoryCache(costLimit: limit)
    }

    var currentCost: Int { cache.currentCost }
    /// Logical state payload only; Dictionary allocator/metadata footprint is intentionally not
    /// claimed by this research probe.
    var metadataBytes: Int { probationHits.count }
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
        let victims = cache.resourceProbeEvictionForecast(incomingCost: request.cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        for victim in victims { probationHits.removeValue(forKey: victim.key) }
        cache.insert(request.key, for: request.key, cost: request.cost)
        probationHits[request.key] = 0
    }
}

final class BudgetedSecondHitCompetitionPolicy: AdmissionCompetitionPolicy {
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
    private(set) var fullVisitedEpochResets = 0

    init(limit: Int, secondHitBudget: Int) {
        precondition(secondHitBudget >= 0 && secondHitBudget <= limit)
        self.limit = limit
        self.secondHitBudget = secondHitBudget
        cache = MemoryCache(costLimit: limit)
        name = "budgeted-second-hit-b\(secondHitBudget)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical state payload only. The probe does not claim Dictionary allocator footprint.
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
            if hit { return true }
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
        let trace = cache.resourceProbeEvictionTrace(incomingCost: request.cost)
        fullVisitedEpochResets += trace.fullVisitedEpochResetCount
        let victims = trace.victims
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

final class DensityCappedSecondHitCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let secondHitBudget: Int
    private let unvisitedReserve: Int
    private let cache: MemoryCache<Int, Int>
    private var probationHits: [Int: UInt8] = [:]
    private var provisionalProtectedCost: [Int: Int] = [:]
    private var protectedSecondHitBytes = 0
    private(set) var maximumProtectedSecondHitBytes = 0
    private(set) var maximumResidentCost = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0
    private(set) var fullVisitedEpochResets = 0
    private(set) var densityDeniedPromotions = 0

    init(limit: Int, secondHitBudget: Int, unvisitedReserve: Int) {
        precondition(secondHitBudget >= 0 && secondHitBudget <= limit)
        precondition(unvisitedReserve >= 0 && unvisitedReserve < limit)
        self.limit = limit
        self.secondHitBudget = secondHitBudget
        self.unvisitedReserve = unvisitedReserve
        cache = MemoryCache(costLimit: limit)
        name = "density-capped-second-hit-b\(secondHitBudget)-r\(unvisitedReserve)"
    }

    var currentCost: Int { cache.currentCost }
    /// Logical payload only; Dictionary allocator/table footprint is intentionally excluded.
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
            if hit { return true }
        }

        if let hits = probationHits[request.key] {
            if hits == 0 {
                if cache.resourceProbeValueWithoutVisit(for: request.key) != nil {
                    let budgetAllows = request.cost <= secondHitBudget
                        && protectedSecondHitBytes <= secondHitBudget - request.cost
                    if budgetAllows {
                        let visitState = cache.resourceProbeVisitState()
                        precondition(visitState.unvisitedCost >= request.cost)
                        let remainingUnvisitedCost = visitState.unvisitedCost - request.cost
                        if remainingUnvisitedCost >= unvisitedReserve,
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
                            densityDeniedPromotions += 1
                            probationHits[request.key] = 1
                        }
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
        let trace = cache.resourceProbeEvictionTrace(incomingCost: request.cost)
        fullVisitedEpochResets += trace.fullVisitedEpochResetCount
        let victims = trace.victims
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        for victim in victims { removeAuxiliaryState(for: victim.key) }
        cache.insert(request.key, for: request.key, cost: request.cost)
        probationHits[request.key] = 0
    }

    private func removeAuxiliaryState(for key: Int) {
        probationHits.removeValue(forKey: key)
        if let protectedCost = provisionalProtectedCost[key] {
            releaseProtectedBudget(for: key, expectedCost: protectedCost)
        }
    }

    private func releaseProtectedBudget(for key: Int, expectedCost: Int) {
        guard let removed = provisionalProtectedCost.removeValue(forKey: key) else { return }
        precondition(removed == expectedCost)
        protectedSecondHitBytes -= removed
        precondition(protectedSecondHitBytes >= 0)
    }
}
