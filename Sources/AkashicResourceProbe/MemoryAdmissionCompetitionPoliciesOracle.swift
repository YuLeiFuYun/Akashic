import AkashicMemory
import Foundation

final class ExactFrequencyCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let windowLimit: Int
    private let main: MemoryCache<Int, Int>
    private var window: [Int: AdmissionCompetitionWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var exact: [Int: Int] = [:]
    private let agingVolume: Int
    private let byteWeightedEvidence: Bool
    private var observedVolume = 0

    private(set) var maximumResidentCost = 0
    private(set) var agingPasses = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(
        limit: Int,
        windowLimit: Int,
        agingVolume: Int,
        byteWeightedEvidence: Bool = false
    ) {
        precondition(windowLimit > 0 && windowLimit < limit)
        precondition(agingVolume > 0)
        self.limit = limit
        self.windowLimit = windowLimit
        self.agingVolume = agingVolume
        self.byteWeightedEvidence = byteWeightedEvidence
        main = MemoryCache(costLimit: limit - windowLimit)
        name = (byteWeightedEvidence ? "exact-byte" : "exact") + "-age\(agingVolume)"
    }

    var currentCost: Int { main.currentCost + windowCost }
    /// Exact history is an oracle/control rather than a bounded production candidate. This is
    /// only the logical key+counter payload; Dictionary allocator/metadata footprint is excluded.
    var metadataBytes: Int { exact.count * MemoryLayout<Int>.stride * 2 }
    var maximumCounter: Int { exact.values.max() ?? 0 }
    var maximumProtectedSecondHitBytes: Int { 0 }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        let mainLimit = limit - windowLimit
        var seededMain = 0
        for request in requests {
            observe(request)
            if seededMain + request.cost <= mainLimit {
                main.insert(request.key, for: request.key, cost: request.cost)
                seededMain += request.cost
            } else {
                insertIntoWindow(request)
            }
        }
        precondition(currentCost == limit)
        maximumResidentCost = currentCost
        for request in requests where request.role == .core || request.role == .warm {
            precondition(value(for: request.key) != nil)
        }
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        ageIfNeeded()
        observe(request)
        let hit = value(for: request.key) != nil
        if !hit {
            if request.cost <= windowLimit {
                insertIntoWindow(request)
            } else {
                considerMain(key: request.key, value: request.key, cost: request.cost)
            }
        }
        observedVolume += min(max(request.cost, 1), limit)
        maximumResidentCost = max(maximumResidentCost, currentCost)
        precondition(currentCost <= limit)
        return hit
    }

    private func ageIfNeeded() {
        while observedVolume >= agingVolume {
            exact = exact.reduce(into: [:]) { output, item in
                let value = item.value / 2
                if value > 0 { output[item.key] = value }
            }
            observedVolume -= agingVolume
            agingPasses += 1
        }
    }

    private func observe(_ request: AdmissionCompetitionRequest) {
        exact[request.key, default: 0] += 1
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: AdmissionCompetitionRequest) {
        if let existing = window.removeValue(forKey: request.key) {
            windowCost -= existing.cost
            windowOrder.removeAll { $0 == request.key }
        }
        while windowCost > windowLimit - request.cost, let oldest = windowOrder.first {
            windowOrder.removeFirst()
            guard let evicted = window.removeValue(forKey: oldest) else { continue }
            windowCost -= evicted.cost
            considerMain(key: oldest, value: evicted.value, cost: evicted.cost)
        }
        window[request.key] = AdmissionCompetitionWindowEntry(value: request.key, cost: request.cost)
        windowOrder.append(request.key)
        windowCost += request.cost
    }

    private func considerMain(key: Int, value: Int, cost: Int) {
        guard cost <= limit - windowLimit else { return }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        guard !victims.isEmpty else {
            main.insert(value, for: key, cost: cost)
            return
        }
        let candidateFrequency = exact[key, default: 0]
        let candidateEvidence = byteWeightedEvidence
            ? candidateFrequency * cost
            : candidateFrequency
        let victimEvidence = victims.reduce(0) { partial, victim in
            let frequency = exact[victim.key, default: 0]
            return partial + (byteWeightedEvidence ? frequency * victim.cost : frequency)
        }
        if candidateEvidence > victimEvidence {
            main.insert(value, for: key, cost: cost)
        }
    }
}

final class FutureOracleCompetitionPolicy: AdmissionCompetitionPolicy {
    let name = "future-oracle-byte"
    private let limit: Int
    private let windowLimit: Int
    private let main: MemoryCache<Int, Int>
    private var window: [Int: AdmissionCompetitionWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var remainingRequests: [Int: Int] = [:]
    private(set) var maximumResidentCost = 0
    private(set) var maximumCounter = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(limit: Int, windowLimit: Int) {
        precondition(windowLimit > 0 && windowLimit < limit)
        self.limit = limit
        self.windowLimit = windowLimit
        main = MemoryCache(costLimit: limit - windowLimit)
    }

    var currentCost: Int { main.currentCost + windowCost }
    /// Full remaining-trace identities are deliberately unbounded oracle state. The byte count is
    /// logical key+counter payload only, not a production memory-footprint claim.
    var metadataBytes: Int { remainingRequests.count * MemoryLayout<Int>.stride * 2 }
    var agingPasses: Int { 0 }
    var maximumProtectedSecondHitBytes: Int { 0 }

    func prepare(requests: [AdmissionCompetitionRequest]) {
        remainingRequests.removeAll(keepingCapacity: true)
        for request in requests {
            remainingRequests[request.key, default: 0] += 1
        }
        maximumCounter = remainingRequests.values.max() ?? 0
    }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        let mainLimit = limit - windowLimit
        var seededMain = 0
        for request in requests {
            if seededMain + request.cost <= mainLimit {
                main.insert(request.key, for: request.key, cost: request.cost)
                seededMain += request.cost
            } else {
                insertIntoWindow(request)
            }
        }
        precondition(currentCost == limit)
        maximumResidentCost = currentCost
        for request in requests where request.role == .core || request.role == .warm {
            precondition(value(for: request.key) != nil)
        }
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        consumeCurrentRequest(request.key)
        let hit = value(for: request.key) != nil
        if !hit {
            if request.cost <= windowLimit {
                insertIntoWindow(request)
            } else {
                considerMain(key: request.key, value: request.key, cost: request.cost)
            }
        }
        maximumResidentCost = max(maximumResidentCost, currentCost)
        precondition(currentCost <= limit)
        return hit
    }

    private func consumeCurrentRequest(_ key: Int) {
        guard let count = remainingRequests[key] else { return }
        if count <= 1 {
            remainingRequests.removeValue(forKey: key)
        } else {
            remainingRequests[key] = count - 1
        }
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: AdmissionCompetitionRequest) {
        if let existing = window.removeValue(forKey: request.key) {
            windowCost -= existing.cost
            windowOrder.removeAll { $0 == request.key }
        }
        while windowCost > windowLimit - request.cost, let oldest = windowOrder.first {
            windowOrder.removeFirst()
            guard let evicted = window.removeValue(forKey: oldest) else { continue }
            windowCost -= evicted.cost
            considerMain(key: oldest, value: evicted.value, cost: evicted.cost)
        }
        window[request.key] = AdmissionCompetitionWindowEntry(value: request.key, cost: request.cost)
        windowOrder.append(request.key)
        windowCost += request.cost
    }

    private func considerMain(key: Int, value: Int, cost: Int) {
        guard cost <= limit - windowLimit else { return }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        guard !victims.isEmpty else {
            main.insert(value, for: key, cost: cost)
            return
        }
        let candidateFutureByteUtility = remainingRequests[key, default: 0] * cost
        let victimFutureByteUtility = victims.reduce(0) { partial, victim in
            partial + remainingRequests[victim.key, default: 0] * victim.cost
        }
        if candidateFutureByteUtility > victimFutureByteUtility {
            main.insert(value, for: key, cost: cost)
        }
    }
}

/// Perfect-future control that moves the same future-byte replacement decision to first-miss
/// arrival instead of waiting for the probation window to evict the candidate. Direct-main
/// insertions remain normal unvisited SIEVE entries; this intentionally does not use lookahead to
/// mutate resident visited state, so a remaining loss can be attributed to resident replacement
/// dynamics rather than the timing of admission evidence alone.
final class FutureArrivalOracleCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let windowLimit: Int
    private let suppressFinalVisit: Bool
    private let main: MemoryCache<Int, Int>
    private var window: [Int: AdmissionCompetitionWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var remainingRequests: [Int: Int] = [:]
    private(set) var maximumResidentCost = 0
    private(set) var maximumCounter = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(limit: Int, windowLimit: Int, suppressFinalVisit: Bool = false) {
        precondition(windowLimit > 0 && windowLimit < limit)
        self.limit = limit
        self.windowLimit = windowLimit
        self.suppressFinalVisit = suppressFinalVisit
        main = MemoryCache(costLimit: limit - windowLimit)
        name = suppressFinalVisit
            ? "future-arrival-no-stale-visit-oracle-byte"
            : "future-arrival-oracle-byte"
    }

    var currentCost: Int { main.currentCost + windowCost }
    var metadataBytes: Int { remainingRequests.count * MemoryLayout<Int>.stride * 2 }
    var agingPasses: Int { 0 }
    var maximumProtectedSecondHitBytes: Int { 0 }

    func prepare(requests: [AdmissionCompetitionRequest]) {
        remainingRequests.removeAll(keepingCapacity: true)
        for request in requests {
            remainingRequests[request.key, default: 0] += 1
        }
        maximumCounter = remainingRequests.values.max() ?? 0
    }

    func seed(_ requests: [AdmissionCompetitionRequest]) {
        let mainLimit = limit - windowLimit
        var seededMain = 0
        for request in requests {
            if seededMain + request.cost <= mainLimit {
                main.insert(request.key, for: request.key, cost: request.cost)
                seededMain += request.cost
            } else {
                insertIntoWindow(request)
            }
        }
        precondition(currentCost == limit)
        maximumResidentCost = currentCost
        for request in requests where request.role == .core || request.role == .warm {
            precondition(value(for: request.key) != nil)
        }
    }

    func request(_ request: AdmissionCompetitionRequest) -> Bool {
        consumeCurrentRequest(request.key)
        let hit = requestHit(for: request.key)
        if !hit {
            let hasFutureReuse = remainingRequests[request.key, default: 0] > 0
            let admittedDirectly = hasFutureReuse
                && considerMain(key: request.key, value: request.key, cost: request.cost)
            if !admittedDirectly {
                if request.cost <= windowLimit {
                    insertIntoWindow(request)
                } else {
                    _ = considerMain(key: request.key, value: request.key, cost: request.cost)
                }
            }
        }
        maximumResidentCost = max(maximumResidentCost, currentCost)
        precondition(currentCost <= limit)
        return hit
    }

    private func consumeCurrentRequest(_ key: Int) {
        guard let count = remainingRequests[key] else { return }
        if count <= 1 {
            remainingRequests.removeValue(forKey: key)
        } else {
            remainingRequests[key] = count - 1
        }
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func requestHit(for key: Int) -> Bool {
        if main.resourceProbeValueWithoutVisit(for: key) != nil {
            if !suppressFinalVisit || remainingRequests[key, default: 0] > 0 {
                precondition(main.resourceProbeMarkVisited(for: key))
            }
            return true
        }
        return window[key] != nil
    }

    private func insertIntoWindow(_ request: AdmissionCompetitionRequest) {
        if let existing = window.removeValue(forKey: request.key) {
            windowCost -= existing.cost
            windowOrder.removeAll { $0 == request.key }
        }
        while windowCost > windowLimit - request.cost, let oldest = windowOrder.first {
            windowOrder.removeFirst()
            guard let evicted = window.removeValue(forKey: oldest) else { continue }
            windowCost -= evicted.cost
            _ = considerMain(key: oldest, value: evicted.value, cost: evicted.cost)
        }
        window[request.key] = AdmissionCompetitionWindowEntry(value: request.key, cost: request.cost)
        windowOrder.append(request.key)
        windowCost += request.cost
    }

    @discardableResult
    private func considerMain(key: Int, value: Int, cost: Int) -> Bool {
        guard cost <= limit - windowLimit else { return false }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        guard !victims.isEmpty else {
            main.insert(value, for: key, cost: cost)
            return true
        }
        let candidateFutureByteUtility = remainingRequests[key, default: 0] * cost
        let victimFutureByteUtility = victims.reduce(0) { partial, victim in
            partial + remainingRequests[victim.key, default: 0] * victim.cost
        }
        guard candidateFutureByteUtility > victimFutureByteUtility else { return false }
        main.insert(value, for: key, cost: cost)
        return true
    }
}
