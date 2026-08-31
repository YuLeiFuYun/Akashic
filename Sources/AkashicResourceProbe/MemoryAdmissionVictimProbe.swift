import AkashicMemory
import Foundation

private struct AdmissionRequest {
    let key: Int
    let cost: Int
}

private struct AdmissionWindowEntry {
    let value: Int
    let cost: Int
}

private struct AdmissionResult: Codable {
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let hitRatio: Double
    let giantAHits: Int
    let giantBHits: Int
    let finalMainCost: Int
    let finalWindowCost: Int
    let finalMainCount: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

private struct AdmissionVictimOracleReport: Codable {
    let schemaVersion: Int
    let forecastControls: Int
    let forecastControlsPassed: Int
    let results: [AdmissionResult]
    let checks: [String: Bool]
    let allNonPhaseChecksPass: Bool
    let phaseShiftExposesStaleFrequency: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionPolicy: Bool
        let exactFrequencyMemoryQualified: Bool
        let agingQualified: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
    }
}

private final class CostAwareAdmissionOracle {
    private let main = MemoryCache<Int, Int>(costLimit: 90)
    private let windowLimit = 10
    private var window: [Int: AdmissionWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var frequency: [Int: Int] = [:]
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    var mainCost: Int { main.currentCost }
    var mainCount: Int { main.count }
    var currentWindowCost: Int { windowCost }

    func primeHotSet() {
        for key in 0..<9 {
            main.insert(key, for: key, cost: 10)
            frequency[key] = 1
        }
        window[9] = AdmissionWindowEntry(value: 9, cost: 10)
        windowOrder = [9]
        windowCost = 10
        frequency[9] = 1
        for _ in 0..<2 {
            for key in 0..<10 {
                frequency[key, default: 0] += 1
                precondition(valueWithoutFrequency(for: key) != nil)
            }
        }
        assertBounds()
    }

    func request(_ request: AdmissionRequest) -> Bool {
        frequency[request.key, default: 0] += 1
        if valueWithoutFrequency(for: request.key) != nil {
            return true
        }
        if request.cost <= windowLimit {
            insertIntoWindow(request)
        } else {
            considerMain(key: request.key, value: request.key, cost: request.cost)
        }
        assertBounds()
        return false
    }

    private func valueWithoutFrequency(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: AdmissionRequest) {
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
        window[request.key] = AdmissionWindowEntry(value: request.key, cost: request.cost)
        windowOrder.append(request.key)
        windowCost += request.cost
    }

    private func considerMain(key: Int, value: Int, cost: Int) {
        guard cost <= 90 else { return }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        let victimCost = victims.reduce(0) { $0 + $1.cost }
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victimCost)
        let candidateEvidence = frequency[key, default: 0]
        let victimEvidence = victims.reduce(0) { partial, victim in
            partial + frequency[victim.key, default: 0]
        }
        if victims.isEmpty || candidateEvidence > victimEvidence {
            main.insert(value, for: key, cost: cost)
        }
    }

    private func assertBounds() {
        precondition(main.currentCost <= 90)
        precondition(windowCost <= windowLimit)
        precondition(main.currentCost + windowCost <= 100)
    }
}

enum MemoryAdmissionVictimProbe {
    static func run() throws {
        let forecastControls = try verifyForecastControls()
        let workloads = [
            "unique-small-pollution",
            "unique-medium-pollution",
            "unique-giant-pollution",
            "two-touch-small-burst",
            "dominant-giant",
            "sparse-two-touch-giant",
            "phase-shift",
        ]
        let results = workloads.map(runWorkload)
        var checks: [String: Bool] = [:]
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.workload, $0) })
        checks["unique-small-protected"] = byName["unique-small-pollution"]!.hits >= 800
        checks["unique-medium-protected"] = byName["unique-medium-pollution"]!.hits >= 990
        checks["unique-giant-protected"] = byName["unique-giant-pollution"]!.hits >= 990
        checks["two-touch-window-preserved"] = byName["two-touch-small-burst"]!.hits == 200
        checks["dominant-giant-better-than-binary-window"] = byName["dominant-giant"]!.hits > 803
        checks["sparse-two-touch-does-not-collapse-hot-set"] =
            byName["sparse-two-touch-giant"]!.hits >= 990
        let phase = byName["phase-shift"]!
        let phaseShiftExposesStaleFrequency = phase.giantAHits > 800 && phase.giantBHits < 100

        let report = AdmissionVictimOracleReport(
            schemaVersion: 1,
            forecastControls: forecastControls.total,
            forecastControlsPassed: forecastControls.passed,
            results: results,
            checks: checks,
            allNonPhaseChecksPass: forecastControls.total == forecastControls.passed
                && checks.values.allSatisfy { $0 },
            phaseShiftExposesStaleFrequency: phaseShiftExposesStaleFrequency,
            claims: .init(
                productionPolicy: false,
                exactFrequencyMemoryQualified: false,
                agingQualified: false,
                shardedConcurrencyQualified: false,
                formalPerformance: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func runWorkload(_ name: String) -> AdmissionResult {
        let oracle = CostAwareAdmissionOracle()
        oracle.primeHotSet()
        let requests = trace(name)
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
        return AdmissionResult(
            workload: name,
            requests: requests.count,
            hits: hits,
            misses: requests.count - hits,
            hitRatio: Double(hits) / Double(requests.count),
            giantAHits: giantAHits,
            giantBHits: giantBHits,
            finalMainCost: oracle.mainCost,
            finalWindowCost: oracle.currentWindowCost,
            finalMainCount: oracle.mainCount,
            maximumVictimCount: oracle.maximumVictimCount,
            maximumVictimCost: oracle.maximumVictimCost
        )
    }

    private static func trace(_ name: String) -> [AdmissionRequest] {
        var result: [AdmissionRequest] = []
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
            for round in 0..<100 {
                for _ in 0..<9 { result.append(.init(key: 500, cost: 90)) }
                result.append(.init(key: round % 10, cost: 10))
            }
        case "sparse-two-touch-giant":
            result.append(.init(key: 600, cost: 90))
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: 600, cost: 90))
            for _ in 0..<100 {
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            }
        case "phase-shift":
            for round in 0..<100 {
                for _ in 0..<9 { result.append(.init(key: 500, cost: 90)) }
                result.append(.init(key: round % 10, cost: 10))
            }
            for round in 0..<100 {
                for _ in 0..<9 { result.append(.init(key: 501, cost: 90)) }
                result.append(.init(key: round % 10, cost: 10))
            }
        default:
            preconditionFailure("unknown workload")
        }
        return result
    }

    private static func verifyForecastControls() throws -> (total: Int, passed: Int) {
        var total = 0
        var passed = 0
        for incomingCost in [10, 40, 90] {
            let cache = MemoryCache<Int, Int>(costLimit: 100)
            for key in 0..<10 { cache.insert(key, for: key, cost: 10) }
            for _ in 0..<2 {
                for key in 0..<10 { _ = cache.value(for: key) }
            }
            let forecast = cache.resourceProbeEvictionForecast(incomingCost: incomingCost)
            let forecastKeys = Set(forecast.map(\.key))
            cache.insert(999, for: 999, cost: incomingCost)
            var missing = Set<Int>()
            for key in 0..<10 {
                if cache.value(for: key) == nil { missing.insert(key) }
            }
            total += 1
            if missing == forecastKeys { passed += 1 }
        }
        guard passed == total else { throw SegmentedManifestShadowError.invariantViolation }
        return (total, passed)
    }
}
