import AkashicMemory
import Foundation

private struct CostVolumeAdmissionRequest {
    let key: Int
    let cost: Int
}

private struct CostVolumeWindowEntry {
    let value: Int
    let cost: Int
}

private struct CostVolumeResult: Codable {
    let policy: String
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let phaseAHits: Int
    let phaseBHits: Int
    let agingPasses: Int
    let finalCounterCount: Int
    let maximumCounterCount: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

private struct CostVolumeReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let exactCounterMemoryQualified: Bool
        let approximateSketchQualified: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
    }

    let schemaVersion: Int
    let totalCacheCost: Int
    let budgetMultipliers: [Int]
    let results: [CostVolumeResult]
    let checks: [String: Bool]
    let viableMultipliers: [Int]
    let broadStableRegionObserved: Bool
    let claims: Claims
}

private final class CostVolumeAdmissionOracle {
    private let main = MemoryCache<Int, Int>(costLimit: 90)
    private let windowLimit = 10
    private let totalCacheCost = 100
    private let budgetMultiplier: Int?
    private var window: [Int: CostVolumeWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var frequency: [Int: Int] = [:]
    private var accumulatedRequestCost = 0
    private(set) var agingPasses = 0
    private(set) var maximumCounterCount = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(budgetMultiplier: Int?) {
        self.budgetMultiplier = budgetMultiplier
    }

    var counterCount: Int { frequency.count }

    func primeHotSet() {
        for key in 0..<9 {
            main.insert(key, for: key, cost: 10)
            observe(key)
        }
        window[9] = CostVolumeWindowEntry(value: 9, cost: 10)
        windowOrder = [9]
        windowCost = 10
        observe(9)
        for _ in 0..<2 {
            for key in 0..<10 {
                observe(key)
                precondition(value(for: key) != nil)
            }
        }
        sampleBounds()
    }

    func request(_ request: CostVolumeAdmissionRequest) -> Bool {
        applyPendingAging()
        observe(request.key)
        let hit: Bool
        if value(for: request.key) != nil {
            hit = true
        } else {
            if request.cost <= windowLimit {
                insertIntoWindow(request)
            } else {
                considerMain(key: request.key, value: request.key, cost: request.cost)
            }
            sampleBounds()
            hit = false
        }
        accumulatedRequestCost += min(max(request.cost, 1), totalCacheCost)
        return hit
    }

    private func applyPendingAging() {
        guard let budgetMultiplier else { return }
        let interval = budgetMultiplier * totalCacheCost
        while accumulatedRequestCost >= interval {
            frequency = frequency.reduce(into: [:]) { output, item in
                let value = item.value / 2
                if value > 0 { output[item.key] = value }
            }
            accumulatedRequestCost -= interval
            agingPasses += 1
        }
    }

    private func observe(_ key: Int) {
        frequency[key, default: 0] += 1
        maximumCounterCount = max(maximumCounterCount, frequency.count)
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: CostVolumeAdmissionRequest) {
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
        window[request.key] = CostVolumeWindowEntry(value: request.key, cost: request.cost)
        windowOrder.append(request.key)
        windowCost += request.cost
    }

    private func considerMain(key: Int, value: Int, cost: Int) {
        guard cost <= 90 else { return }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        let candidateEvidence = frequency[key, default: 0]
        let victimEvidence = victims.reduce(0) { partial, victim in
            partial + frequency[victim.key, default: 0]
        }
        if victims.isEmpty || candidateEvidence > victimEvidence {
            main.insert(value, for: key, cost: cost)
        }
    }

    private func sampleBounds() {
        precondition(main.currentCost <= 90)
        precondition(windowCost <= windowLimit)
        precondition(main.currentCost + windowCost <= totalCacheCost)
    }
}

enum MemoryAdmissionCostVolumeProbe {
    static func run() throws {
        let multipliers: [Int?] = [nil, 8, 32, 128]
        let workloads = [
            "unique-small-pollution",
            "unique-medium-pollution",
            "unique-giant-pollution",
            "two-touch-small-burst",
            "dominant-giant",
            "sparse-two-touch-giant",
            "phase-shift",
            "alternating-20",
            "small-to-giant",
            "giant-to-small",
        ]
        var results: [CostVolumeResult] = []
        for multiplier in multipliers {
            for workload in workloads {
                results.append(runCase(multiplier: multiplier, workload: workload))
            }
        }

        func get(_ multiplier: Int?, _ workload: String) -> CostVolumeResult {
            let policy = multiplier.map { "halve-\($0)-budgets" } ?? "no-aging"
            return results.first { $0.policy == policy && $0.workload == workload }!
        }

        var checks: [String: Bool] = [:]
        var viable: [Int] = []
        for multiplier in [8, 32, 128] {
            let prefix = "halve-\(multiplier)-budgets"
            let local: [String: Bool] = [
                "unique-small": get(multiplier, "unique-small-pollution").hits >= 800,
                "unique-medium": get(multiplier, "unique-medium-pollution").hits >= 990,
                "unique-giant": get(multiplier, "unique-giant-pollution").hits >= 990,
                "two-touch": get(multiplier, "two-touch-small-burst").hits == 200,
                "dominant": get(multiplier, "dominant-giant").hits > 803,
                "sparse": get(multiplier, "sparse-two-touch-giant").hits >= 990,
                "phase-B": get(multiplier, "phase-shift").phaseBHits >= 700,
                "alternating-A": get(multiplier, "alternating-20").phaseAHits >= 500,
                "alternating-B": get(multiplier, "alternating-20").phaseBHits >= 500,
                "small-to-giant-A": get(multiplier, "small-to-giant").phaseAHits >= 800,
                "small-to-giant-B": get(multiplier, "small-to-giant").phaseBHits >= 700,
                "giant-to-small-A": get(multiplier, "giant-to-small").phaseAHits >= 800,
                "giant-to-small-B": get(multiplier, "giant-to-small").phaseBHits >= 700,
            ]
            for (name, passed) in local {
                checks["\(prefix).\(name)"] = passed
            }
            if local.values.allSatisfy({ $0 }) { viable.append(multiplier) }
        }
        checks["cost-volume-materially-improves-equal-cost-phase"] =
            viable.contains { get($0, "phase-shift").phaseBHits > get(nil, "phase-shift").phaseBHits + 500 }

        let report = CostVolumeReport(
            schemaVersion: 1,
            totalCacheCost: 100,
            budgetMultipliers: [8, 32, 128],
            results: results,
            checks: checks,
            viableMultipliers: viable,
            broadStableRegionObserved: viable.count >= 2,
            claims: .init(
                productionPolicy: false,
                exactCounterMemoryQualified: false,
                approximateSketchQualified: false,
                shardedConcurrencyQualified: false,
                formalPerformance: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func runCase(multiplier: Int?, workload: String) -> CostVolumeResult {
        let oracle = CostVolumeAdmissionOracle(budgetMultiplier: multiplier)
        oracle.primeHotSet()
        let requests = trace(workload)
        var hits = 0
        var phaseAHits = 0
        var phaseBHits = 0
        for request in requests {
            let hit = oracle.request(request)
            if hit {
                hits += 1
                if request.key == 500 { phaseAHits += 1 }
                if request.key == 501 { phaseBHits += 1 }
            }
        }
        return CostVolumeResult(
            policy: multiplier.map { "halve-\($0)-budgets" } ?? "no-aging",
            workload: workload,
            requests: requests.count,
            hits: hits,
            misses: requests.count - hits,
            phaseAHits: phaseAHits,
            phaseBHits: phaseBHits,
            agingPasses: oracle.agingPasses,
            finalCounterCount: oracle.counterCount,
            maximumCounterCount: oracle.maximumCounterCount,
            maximumVictimCount: oracle.maximumVictimCount,
            maximumVictimCost: oracle.maximumVictimCost
        )
    }

    private static func trace(_ name: String) -> [CostVolumeAdmissionRequest] {
        var result: [CostVolumeAdmissionRequest] = []
        switch name {
        case "unique-small-pollution":
            appendPollution(rounds: 100, coldCost: 10, coldBase: 10_000, into: &result)
        case "unique-medium-pollution":
            appendPollution(rounds: 100, coldCost: 40, coldBase: 20_000, into: &result)
        case "unique-giant-pollution":
            appendPollution(rounds: 100, coldCost: 90, coldBase: 30_000, into: &result)
        case "two-touch-small-burst":
            for index in 0..<200 {
                let key = 40_000 + index
                result.append(.init(key: key, cost: 10))
                result.append(.init(key: key, cost: 10))
            }
        case "dominant-giant":
            appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
        case "sparse-two-touch-giant":
            result.append(.init(key: 600, cost: 90))
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: 600, cost: 90))
            for _ in 0..<100 {
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            }
        case "phase-shift":
            appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 90, into: &result)
        case "alternating-20":
            for _ in 0..<5 {
                appendDominant(rounds: 20, key: 500, cost: 90, into: &result)
                appendDominant(rounds: 20, key: 501, cost: 90, into: &result)
            }
        case "small-to-giant":
            appendDominant(rounds: 100, key: 500, cost: 10, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 90, into: &result)
        case "giant-to-small":
            appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 10, into: &result)
        default:
            preconditionFailure("unknown workload")
        }
        return result
    }

    private static func appendPollution(
        rounds: Int,
        coldCost: Int,
        coldBase: Int,
        into result: inout [CostVolumeAdmissionRequest]
    ) {
        for round in 0..<rounds {
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: coldBase + round, cost: coldCost))
        }
    }

    private static func appendDominant(
        rounds: Int,
        key: Int,
        cost: Int,
        into result: inout [CostVolumeAdmissionRequest]
    ) {
        for round in 0..<rounds {
            for _ in 0..<9 { result.append(.init(key: key, cost: cost)) }
            result.append(.init(key: round % 10, cost: 10))
        }
    }
}
