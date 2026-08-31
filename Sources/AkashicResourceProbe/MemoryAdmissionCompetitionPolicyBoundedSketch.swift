import AkashicMemory
import Foundation

final class BoundedSketchCompetitionPolicy: AdmissionCompetitionPolicy {
    let name: String
    private let limit: Int
    private let windowLimit: Int
    private let main: MemoryCache<Int, Int>
    private var window: [Int: AdmissionCompetitionWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var sketch: AdmissionCompetitionSketch
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
        width: Int,
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
        sketch = AdmissionCompetitionSketch(width: width)
        name = (byteWeightedEvidence ? "sketch-byte" : "sketch")
            + "-w\(width)-age\(agingVolume)"
    }

    var currentCost: Int { main.currentCost + windowCost }
    var metadataBytes: Int { sketch.counters.count }
    var maximumCounter: Int { Int(sketch.maximumCounter) }
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
        ageIfNeeded(before: request)
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

    private func ageIfNeeded(before request: AdmissionCompetitionRequest) {
        _ = request
        while observedVolume >= agingVolume {
            sketch.halve()
            observedVolume -= agingVolume
            agingPasses += 1
        }
    }

    private func observe(_ request: AdmissionCompetitionRequest) {
        sketch.increment(request.key)
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
        let candidateFrequency = sketch.estimate(key)
        let candidateEvidence = byteWeightedEvidence
            ? candidateFrequency * cost
            : candidateFrequency
        let victimEvidence = victims.reduce(0) { partial, victim in
            let frequency = sketch.estimate(victim.key)
            return partial + (byteWeightedEvidence ? frequency * victim.cost : frequency)
        }
        if candidateEvidence > victimEvidence {
            main.insert(value, for: key, cost: cost)
        }
    }
}
