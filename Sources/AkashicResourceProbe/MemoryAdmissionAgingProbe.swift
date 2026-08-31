import AkashicMemory
import Foundation

private struct AgedAdmissionRequest {
    let key: Int
    let cost: Int
}

private struct AgedWindowEntry {
    let value: Int
    let cost: Int
}

private struct AgingResult: Codable {
    let policy: String
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let giantAHits: Int
    let giantBHits: Int
    let agingPasses: Int
    let finalCounterCount: Int
    let maximumCounterCount: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

private struct AgingReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let exactCounterMemoryQualified: Bool
        let approximateSketchQualified: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
    }

    let schemaVersion: Int
    let horizons: [Int]
    let results: [AgingResult]
    let checks: [String: Bool]
    let stableAgingRegionObserved: Bool
    let claims: Claims
}

private final class AgedAdmissionOracle {
    private let main = MemoryCache<Int, Int>(costLimit: 90)
    private let windowLimit = 10
    private let agingHorizon: Int?
    private var window: [Int: AgedWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var frequency: [Int: Int] = [:]
    private var requestCount = 0
    private(set) var agingPasses = 0
    private(set) var maximumCounterCount = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(agingHorizon: Int?) {
        self.agingHorizon = agingHorizon
    }

    var counterCount: Int { frequency.count }

    func primeHotSet() {
        for key in 0..<9 {
            main.insert(key, for: key, cost: 10)
            observe(key)
        }
        window[9] = AgedWindowEntry(value: 9, cost: 10)
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

    func request(_ request: AgedAdmissionRequest) -> Bool {
        ageIfNeededBeforeNextRequest()
        requestCount += 1
        observe(request.key)
        if value(for: request.key) != nil { return true }
        if request.cost <= windowLimit {
            insertIntoWindow(request)
        } else {
            considerMain(key: request.key, value: request.key, cost: request.cost)
        }
        sampleBounds()
        return false
    }

    private func ageIfNeededBeforeNextRequest() {
        guard let agingHorizon,
            requestCount > 0,
            requestCount % agingHorizon == 0
        else { return }
        frequency = frequency.reduce(into: [:]) { output, item in
            let value = item.value / 2
            if value > 0 { output[item.key] = value }
        }
        agingPasses += 1
    }

    private func observe(_ key: Int) {
        frequency[key, default: 0] += 1
        maximumCounterCount = max(maximumCounterCount, frequency.count)
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: AgedAdmissionRequest) {
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
        window[request.key] = AgedWindowEntry(value: request.key, cost: request.cost)
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
        precondition(windowCost <= 10)
        precondition(main.currentCost + windowCost <= 100)
    }
}

enum MemoryAdmissionAgingProbe {
    static func run() throws {
        let horizons: [Int?] = [nil, 64, 256, 1024]
        let workloads = [
            "unique-small-pollution",
            "unique-medium-pollution",
            "unique-giant-pollution",
            "two-touch-small-burst",
            "dominant-giant",
            "sparse-two-touch-giant",
            "phase-shift",
            "alternating-20",
        ]
        var results: [AgingResult] = []
        for horizon in horizons {
            for workload in workloads {
                results.append(runCase(horizon: horizon, workload: workload))
            }
        }

        func get(_ horizon: Int?, _ workload: String) -> AgingResult {
            let policy = horizon.map { "halve-\($0)" } ?? "no-aging"
            return results.first { $0.policy == policy && $0.workload == workload }!
        }

        var checks: [String: Bool] = [:]
        for horizon in [64, 256] {
            let prefix = "halve-\(horizon)"
            checks["\(prefix).unique-small"] = get(horizon, "unique-small-pollution").hits >= 800
            checks["\(prefix).unique-medium"] = get(horizon, "unique-medium-pollution").hits >= 990
            checks["\(prefix).unique-giant"] = get(horizon, "unique-giant-pollution").hits >= 990
            checks["\(prefix).two-touch"] = get(horizon, "two-touch-small-burst").hits == 200
            checks["\(prefix).dominant"] = get(horizon, "dominant-giant").hits > 803
            checks["\(prefix).sparse"] = get(horizon, "sparse-two-touch-giant").hits >= 990
            checks["\(prefix).phase-B-learns"] = get(horizon, "phase-shift").giantBHits >= 700
            checks["\(prefix).alternating-both-learn"] =
                get(horizon, "alternating-20").giantAHits >= 500
                && get(horizon, "alternating-20").giantBHits >= 500
        }
        let noAgingPhaseB = get(nil, "phase-shift").giantBHits
        checks["aging-materially-improves-one-way-phase"] =
            get(256, "phase-shift").giantBHits > noAgingPhaseB + 500
        let stableAgingRegionObserved = checks.values.allSatisfy { $0 }

        let report = AgingReport(
            schemaVersion: 1,
            horizons: [64, 256, 1024],
            results: results,
            checks: checks,
            stableAgingRegionObserved: stableAgingRegionObserved,
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

    private static func runCase(horizon: Int?, workload: String) -> AgingResult {
        let oracle = AgedAdmissionOracle(agingHorizon: horizon)
        oracle.primeHotSet()
        let requests = trace(workload)
        var hits = 0
        var giantAHits = 0
        var giantBHits = 0
        for request in requests {
            let hit = oracle.request(request)
            if hit {
                hits += 1
                if request.key == 500 { giantAHits += 1 }
                if request.key == 501 { giantBHits += 1 }
            }
        }
        return AgingResult(
            policy: horizon.map { "halve-\($0)" } ?? "no-aging",
            workload: workload,
            requests: requests.count,
            hits: hits,
            misses: requests.count - hits,
            giantAHits: giantAHits,
            giantBHits: giantBHits,
            agingPasses: oracle.agingPasses,
            finalCounterCount: oracle.counterCount,
            maximumCounterCount: oracle.maximumCounterCount,
            maximumVictimCount: oracle.maximumVictimCount,
            maximumVictimCost: oracle.maximumVictimCost
        )
    }

    private static func trace(_ name: String) -> [AgedAdmissionRequest] {
        var result: [AgedAdmissionRequest] = []
        switch name {
        case "unique-small-pollution":
            for round in 0..<100 {
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
                result.append(.init(key: 10_000 + round, cost: 10))
            }
        case "unique-medium-pollution":
            for round in 0..<100 {
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
                result.append(.init(key: 20_000 + round, cost: 40))
            }
        case "unique-giant-pollution":
            for round in 0..<100 {
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
                result.append(.init(key: 30_000 + round, cost: 90))
            }
        case "two-touch-small-burst":
            for index in 0..<200 {
                let key = 40_000 + index
                result.append(.init(key: key, cost: 10))
                result.append(.init(key: key, cost: 10))
            }
        case "dominant-giant":
            appendDominant(rounds: 100, key: 500, into: &result)
        case "sparse-two-touch-giant":
            result.append(.init(key: 600, cost: 90))
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: 600, cost: 90))
            for _ in 0..<100 {
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            }
        case "phase-shift":
            appendDominant(rounds: 100, key: 500, into: &result)
            appendDominant(rounds: 100, key: 501, into: &result)
        case "alternating-20":
            for _ in 0..<5 {
                appendDominant(rounds: 20, key: 500, into: &result)
                appendDominant(rounds: 20, key: 501, into: &result)
            }
        default:
            preconditionFailure("unknown workload")
        }
        return result
    }

    private static func appendDominant(
        rounds: Int,
        key: Int,
        into result: inout [AgedAdmissionRequest]
    ) {
        for round in 0..<rounds {
            for _ in 0..<9 { result.append(.init(key: key, cost: 90)) }
            result.append(.init(key: round % 10, cost: 10))
        }
    }
}
