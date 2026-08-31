import AkashicMemory
import Foundation

private struct ContestAdmissionRequest {
    let key: Int
    let cost: Int
}

private struct ContestWindowEntry {
    let value: Int
    let cost: Int
}

private struct ContestAgingResult: Codable {
    let policy: String
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let phaseAHits: Int
    let phaseBHits: Int
    let admissionContests: Int
    let agingPasses: Int
    let finalCounterCount: Int
    let maximumCounterCount: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

private struct ContestAgingReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let exactCounterMemoryQualified: Bool
        let approximateSketchQualified: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
    }

    let schemaVersion: Int
    let contestHorizons: [Int]
    let results: [ContestAgingResult]
    let checks: [String: Bool]
    let viableHorizons: [Int]
    let broadStableRegionObserved: Bool
    let claims: Claims
}

private final class ContestAdmissionOracle {
    private let main = MemoryCache<Int, Int>(costLimit: 90)
    private let windowLimit = 10
    private let contestHorizon: Int?
    private var window: [Int: ContestWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var frequency: [Int: Int] = [:]
    private(set) var admissionContests = 0
    private(set) var agingPasses = 0
    private(set) var maximumCounterCount = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(contestHorizon: Int?) {
        self.contestHorizon = contestHorizon
    }

    var counterCount: Int { frequency.count }

    func primeHotSet() {
        for key in 0..<9 {
            main.insert(key, for: key, cost: 10)
            observe(key)
        }
        window[9] = ContestWindowEntry(value: 9, cost: 10)
        windowOrder = [9]
        windowCost = 10
        observe(9)
        for _ in 0..<2 {
            for key in 0..<10 {
                observe(key)
                precondition(value(for: key) != nil)
            }
        }
        assertBounds()
    }

    func request(_ request: ContestAdmissionRequest) -> Bool {
        observe(request.key)
        if value(for: request.key) != nil { return true }
        if request.cost <= windowLimit {
            insertIntoWindow(request)
        } else {
            considerMain(key: request.key, value: request.key, cost: request.cost)
        }
        assertBounds()
        return false
    }

    private func observe(_ key: Int) {
        frequency[key, default: 0] += 1
        maximumCounterCount = max(maximumCounterCount, frequency.count)
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: ContestAdmissionRequest) {
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
        window[request.key] = ContestWindowEntry(value: request.key, cost: request.cost)
        windowOrder.append(request.key)
        windowCost += request.cost
    }

    private func considerMain(key: Int, value: Int, cost: Int) {
        guard cost <= 90 else { return }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        guard !victims.isEmpty else {
            main.insert(value, for: key, cost: cost)
            return
        }
        ageBeforeContestIfNeeded()
        admissionContests += 1
        let candidateEvidence = frequency[key, default: 0]
        let victimEvidence = victims.reduce(0) { partial, victim in
            partial + frequency[victim.key, default: 0]
        }
        if candidateEvidence > victimEvidence {
            main.insert(value, for: key, cost: cost)
        }
    }

    private func ageBeforeContestIfNeeded() {
        guard let contestHorizon,
            admissionContests > 0,
            admissionContests % contestHorizon == 0
        else { return }
        frequency = frequency.reduce(into: [:]) { result, item in
            let next = item.value / 2
            if next > 0 { result[item.key] = next }
        }
        agingPasses += 1
    }

    private func assertBounds() {
        precondition(main.currentCost <= 90)
        precondition(windowCost <= windowLimit)
        precondition(main.currentCost + windowCost <= 100)
    }
}

enum MemoryAdmissionContestAgingProbe {
    static func run() throws {
        let horizons: [Int?] = [nil, 8, 32, 128]
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
            "long-stationary-then-shift",
        ]
        var results: [ContestAgingResult] = []
        for horizon in horizons {
            for workload in workloads {
                results.append(runCase(horizon: horizon, workload: workload))
            }
        }
        func get(_ horizon: Int?, _ workload: String) -> ContestAgingResult {
            let policy = horizon.map { "halve-every-\($0)-contests" } ?? "no-aging"
            return results.first { $0.policy == policy && $0.workload == workload }!
        }

        var checks: [String: Bool] = [:]
        var viable: [Int] = []
        for horizon in [8, 32, 128] {
            let prefix = "H\(horizon)"
            let local: [String: Bool] = [
                "unique-small": get(horizon, "unique-small-pollution").hits >= 800,
                "unique-medium": get(horizon, "unique-medium-pollution").hits >= 990,
                "unique-giant": get(horizon, "unique-giant-pollution").hits >= 990,
                "two-touch": get(horizon, "two-touch-small-burst").hits == 200,
                "dominant": get(horizon, "dominant-giant").hits > 803,
                "sparse": get(horizon, "sparse-two-touch-giant").hits >= 990,
                "phase-B": get(horizon, "phase-shift").phaseBHits >= 700,
                "alternating-A": get(horizon, "alternating-20").phaseAHits >= 500,
                "alternating-B": get(horizon, "alternating-20").phaseBHits >= 500,
                "small-to-giant-B": get(horizon, "small-to-giant").phaseBHits >= 700,
                "giant-to-small-B": get(horizon, "giant-to-small").phaseBHits >= 700,
                "long-shift-B": get(horizon, "long-stationary-then-shift").phaseBHits >= 600,
            ]
            for (name, passed) in local { checks["\(prefix).\(name)"] = passed }
            if local.values.allSatisfy({ $0 }) { viable.append(horizon) }
        }

        let report = ContestAgingReport(
            schemaVersion: 1,
            contestHorizons: [8, 32, 128],
            results: results,
            checks: checks,
            viableHorizons: viable,
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

    private static func runCase(horizon: Int?, workload: String) -> ContestAgingResult {
        let oracle = ContestAdmissionOracle(contestHorizon: horizon)
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
        return ContestAgingResult(
            policy: horizon.map { "halve-every-\($0)-contests" } ?? "no-aging",
            workload: workload,
            requests: requests.count,
            hits: hits,
            misses: requests.count - hits,
            phaseAHits: phaseAHits,
            phaseBHits: phaseBHits,
            admissionContests: oracle.admissionContests,
            agingPasses: oracle.agingPasses,
            finalCounterCount: oracle.counterCount,
            maximumCounterCount: oracle.maximumCounterCount,
            maximumVictimCount: oracle.maximumVictimCount,
            maximumVictimCost: oracle.maximumVictimCost
        )
    }

    private static func trace(_ name: String) -> [ContestAdmissionRequest] {
        var result: [ContestAdmissionRequest] = []
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
            for _ in 0..<100 { for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) } }
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
        case "long-stationary-then-shift":
            appendDominant(rounds: 1_000, key: 500, cost: 90, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 90, into: &result)
        default:
            preconditionFailure("unknown workload")
        }
        return result
    }

    private static func appendPollution(
        rounds: Int,
        coldCost: Int,
        coldBase: Int,
        into result: inout [ContestAdmissionRequest]
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
        into result: inout [ContestAdmissionRequest]
    ) {
        for round in 0..<rounds {
            for _ in 0..<9 { result.append(.init(key: key, cost: cost)) }
            result.append(.init(key: round % 10, cost: 10))
        }
    }
}
