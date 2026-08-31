import AkashicMemory
import Foundation

private enum SaturationCounterKind: String, Codable, CaseIterable {
    case uint8
    case uint16

    var bits: Int { self == .uint8 ? 8 : 16 }
    var bytesPerCounter: Int { bits / 8 }
}

private struct SaturationRequest {
    let key: Int
    let cost: Int
}

private struct SaturationWindowEntry {
    let value: Int
    let cost: Int
}

private struct SaturationSketch {
    static let rowCount = 4
    private static let seeds: [UInt64] = [
        0x9e3779b97f4a7c15,
        0xbf58476d1ce4e5b9,
        0x94d049bb133111eb,
        0xd6e8feb86659fd93,
    ]

    let kind: SaturationCounterKind
    let width: Int
    private var counters8: [UInt8]
    private var counters16: [UInt16]
    private(set) var maximumCounter = 0

    init(kind: SaturationCounterKind, width: Int) {
        precondition(width > 0)
        self.kind = kind
        self.width = width
        let count = Self.rowCount * width
        counters8 = kind == .uint8 ? Array(repeating: 0, count: count) : []
        counters16 = kind == .uint16 ? Array(repeating: 0, count: count) : []
    }

    var counterPayloadBytes: Int {
        Self.rowCount * width * kind.bytesPerCounter
    }

    mutating func increment(_ key: Int) {
        for row in 0..<Self.rowCount {
            let offset = row * width + index(key, row: row)
            switch kind {
            case .uint8:
                if counters8[offset] < .max { counters8[offset] &+= 1 }
                maximumCounter = max(maximumCounter, Int(counters8[offset]))
            case .uint16:
                if counters16[offset] < .max { counters16[offset] &+= 1 }
                maximumCounter = max(maximumCounter, Int(counters16[offset]))
            }
        }
    }

    func estimate(_ key: Int) -> Int {
        var result = Int.max
        for row in 0..<Self.rowCount {
            let offset = row * width + index(key, row: row)
            let value = kind == .uint8 ? Int(counters8[offset]) : Int(counters16[offset])
            result = min(result, value)
        }
        return result == Int.max ? 0 : result
    }

    mutating func halve() {
        switch kind {
        case .uint8:
            for index in counters8.indices { counters8[index] >>= 1 }
        case .uint16:
            for index in counters16.indices { counters16[index] >>= 1 }
        }
    }

    func position(_ key: Int, row: Int) -> Int { index(key, row: row) }

    private func index(_ key: Int, row: Int) -> Int {
        let raw = UInt64(bitPattern: Int64(key)) ^ Self.seeds[row]
        return Int(Self.mix(raw) % UInt64(width))
    }

    private static func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private final class SaturationAdmissionPolicy {
    private let main = MemoryCache<Int, Int>(costLimit: 90)
    private let windowLimit = 10
    private let contestHorizon = 8
    private var sketch: SaturationSketch
    private var exact: [Int: Int] = [:]
    private var window: [Int: SaturationWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var contestsForClock = 0
    private(set) var falseAdmits = 0
    private(set) var falseRejects = 0
    private(set) var admissionContests = 0
    private(set) var agingPasses = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(kind: SaturationCounterKind, width: Int) {
        sketch = SaturationSketch(kind: kind, width: width)
    }

    var maximumCounter: Int { sketch.maximumCounter }
    var counterPayloadBytes: Int { sketch.counterPayloadBytes }

    func primeHotSet() {
        for key in 0..<9 {
            main.insert(key, for: key, cost: 10)
            observe(key)
        }
        window[9] = SaturationWindowEntry(value: 9, cost: 10)
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

    func request(_ request: SaturationRequest) -> Bool {
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
        exact[key, default: 0] += 1
        sketch.increment(key)
    }

    private func age() {
        exact = exact.reduce(into: [:]) { output, item in
            let value = item.value / 2
            if value > 0 { output[item.key] = value }
        }
        sketch.halve()
        agingPasses += 1
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: SaturationRequest) {
        if let old = window.removeValue(forKey: request.key) {
            windowCost -= old.cost
            windowOrder.removeAll { $0 == request.key }
        }
        while windowCost > windowLimit - request.cost, let oldest = windowOrder.first {
            windowOrder.removeFirst()
            guard let evicted = window.removeValue(forKey: oldest) else { continue }
            windowCost -= evicted.cost
            considerMain(key: oldest, value: evicted.value, cost: evicted.cost)
        }
        window[request.key] = SaturationWindowEntry(value: request.key, cost: request.cost)
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
        if contestsForClock > 0, contestsForClock % contestHorizon == 0 { age() }
        contestsForClock += 1
        admissionContests += 1

        let exactCandidate = exact[key, default: 0]
        let exactVictims = victims.reduce(0) { $0 + exact[$1.key, default: 0] }
        let sketchCandidate = sketch.estimate(key)
        let sketchVictims = victims.reduce(0) { $0 + sketch.estimate($1.key) }
        let exactDecision = exactCandidate > exactVictims
        let sketchDecision = sketchCandidate > sketchVictims
        if sketchDecision && !exactDecision { falseAdmits += 1 }
        if !sketchDecision && exactDecision { falseRejects += 1 }
        if sketchDecision { main.insert(value, for: key, cost: cost) }
    }

    private func assertBounds() {
        precondition(main.currentCost <= 90)
        precondition(windowCost <= 10)
        precondition(main.currentCost + windowCost <= 100)
    }
}

private struct SaturationCaseResult: Codable {
    let counterBits: Int
    let width: Int
    let workload: String
    let requests: Int
    let hits: Int
    let falseAdmits: Int
    let falseRejects: Int
    let admissionContests: Int
    let agingPasses: Int
    let maximumCounter: Int
    let counterPayloadBytes: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

private struct SaturationCollisionResult: Codable {
    let counterBits: Int
    let width: Int
    let exactTargetCount: Int
    let sketchTargetEstimate: Int
    let falseHotCreated: Bool
}

private struct SaturationWidthComparison: Codable {
    let width: Int
    let uint8OriginalDisagreements: Int
    let uint16OriginalDisagreements: Int
    let uint8AllDisagreements: Int
    let uint16AllDisagreements: Int
    let uint8MaximumCounter: Int
    let uint16MaximumCounter: Int
}

private struct SaturationProbeReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
        let fullMemoryFootprintQualified: Bool
        let adversarialHashHardening: Bool
    }

    let schemaVersion: Int
    let rows: Int
    let contestHorizon: Int
    let widths: [Int]
    let counterBits: [Int]
    let results: [SaturationCaseResult]
    let comparisons: [SaturationWidthComparison]
    let collisions: [SaturationCollisionResult]
    let uint8ResidualWidthInvariant: Bool
    let uint16EliminatesOriginalResidual: Bool
    let allCounterPayloadsExact: Bool
    let allVictimBoundsPreserved: Bool
    let allCollisionControlsRemainNegative: Bool
    let claims: Claims
}

enum MemoryAdmissionCounterSaturationProbe {
    private static let originalWorkloads = [
        "unique-small", "unique-medium", "unique-giant", "two-touch",
        "dominant", "sparse", "phase", "alternating", "small-to-giant",
        "giant-to-small", "cold-cardinality",
    ]
    private static let extraWorkloads = [
        "long-hot-single-challenger", "long-candidate-hot-victim",
        "repeated-phase-cycles", "burst-contests", "spread-contests",
    ]

    static func run() throws {
        let widths = [128, 512]
        let kinds = SaturationCounterKind.allCases
        var results: [SaturationCaseResult] = []
        for kind in kinds {
            for width in widths {
                for workload in originalWorkloads + extraWorkloads {
                    results.append(runCase(kind: kind, width: width, workload: workload))
                }
            }
        }
        let comparisons = widths.map { width in
            compare(width: width, results: results)
        }
        let collisions = kinds.flatMap { kind in
            widths.map { collisionControl(kind: kind, width: $0) }
        }
        let uint8Original = comparisons.map(\.uint8OriginalDisagreements)
        let report = SaturationProbeReport(
            schemaVersion: 1,
            rows: SaturationSketch.rowCount,
            contestHorizon: 8,
            widths: widths,
            counterBits: kinds.map(\.bits),
            results: results,
            comparisons: comparisons,
            collisions: collisions,
            uint8ResidualWidthInvariant: Set(uint8Original).count == 1
                && (uint8Original.first ?? 0) > 0,
            uint16EliminatesOriginalResidual: comparisons.allSatisfy {
                $0.uint16OriginalDisagreements == 0
            },
            allCounterPayloadsExact: results.allSatisfy {
                $0.counterPayloadBytes == SaturationSketch.rowCount * $0.width * ($0.counterBits / 8)
            },
            allVictimBoundsPreserved: results.allSatisfy {
                $0.maximumVictimCount <= 9 && $0.maximumVictimCost <= 90
            },
            allCollisionControlsRemainNegative: collisions.allSatisfy(\.falseHotCreated),
            claims: .init(
                productionPolicy: false,
                shardedConcurrencyQualified: false,
                formalPerformance: false,
                fullMemoryFootprintQualified: false,
                adversarialHashHardening: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func runCase(
        kind: SaturationCounterKind,
        width: Int,
        workload: String
    ) -> SaturationCaseResult {
        let policy = SaturationAdmissionPolicy(kind: kind, width: width)
        policy.primeHotSet()
        let requests = trace(workload)
        var hits = 0
        for request in requests where policy.request(request) { hits += 1 }
        return SaturationCaseResult(
            counterBits: kind.bits,
            width: width,
            workload: workload,
            requests: requests.count,
            hits: hits,
            falseAdmits: policy.falseAdmits,
            falseRejects: policy.falseRejects,
            admissionContests: policy.admissionContests,
            agingPasses: policy.agingPasses,
            maximumCounter: policy.maximumCounter,
            counterPayloadBytes: policy.counterPayloadBytes,
            maximumVictimCount: policy.maximumVictimCount,
            maximumVictimCost: policy.maximumVictimCost
        )
    }

    private static func compare(
        width: Int,
        results: [SaturationCaseResult]
    ) -> SaturationWidthComparison {
        func disagreements(bits: Int, workloads: [String]) -> Int {
            results.filter { $0.width == width && $0.counterBits == bits && workloads.contains($0.workload) }
                .reduce(0) { $0 + $1.falseAdmits + $1.falseRejects }
        }
        func maximum(bits: Int) -> Int {
            results.filter { $0.width == width && $0.counterBits == bits }
                .map(\.maximumCounter).max() ?? 0
        }
        let all = originalWorkloads + extraWorkloads
        return SaturationWidthComparison(
            width: width,
            uint8OriginalDisagreements: disagreements(bits: 8, workloads: originalWorkloads),
            uint16OriginalDisagreements: disagreements(bits: 16, workloads: originalWorkloads),
            uint8AllDisagreements: disagreements(bits: 8, workloads: all),
            uint16AllDisagreements: disagreements(bits: 16, workloads: all),
            uint8MaximumCounter: maximum(bits: 8),
            uint16MaximumCounter: maximum(bits: 16)
        )
    }

    private static func collisionControl(
        kind: SaturationCounterKind,
        width: Int
    ) -> SaturationCollisionResult {
        let target = 1_700_000 + width
        var sketch = SaturationSketch(kind: kind, width: width)
        var cursor = 1_800_000
        var colliders: [Int] = []
        for row in 0..<SaturationSketch.rowCount {
            let wanted = sketch.position(target, row: row)
            while sketch.position(cursor, row: row) != wanted || cursor == target { cursor += 1 }
            colliders.append(cursor)
            cursor += 1
        }
        for key in colliders { for _ in 0..<64 { sketch.increment(key) } }
        let estimate = sketch.estimate(target)
        return SaturationCollisionResult(
            counterBits: kind.bits,
            width: width,
            exactTargetCount: 0,
            sketchTargetEstimate: estimate,
            falseHotCreated: estimate > 0
        )
    }

    private static func trace(_ name: String) -> [SaturationRequest] {
        var result: [SaturationRequest] = []
        switch name {
        case "unique-small": appendPollution(rounds: 100, cost: 10, base: 10_000, into: &result)
        case "unique-medium": appendPollution(rounds: 100, cost: 40, base: 20_000, into: &result)
        case "unique-giant": appendPollution(rounds: 100, cost: 90, base: 30_000, into: &result)
        case "two-touch":
            for index in 0..<200 {
                let key = 40_000 + index
                result += [.init(key: key, cost: 10), .init(key: key, cost: 10)]
            }
        case "dominant": appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
        case "sparse":
            result.append(.init(key: 600, cost: 90))
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: 600, cost: 90))
            for _ in 0..<100 { for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) } }
        case "phase":
            appendDominant(rounds: 100, key: 500, cost: 90, into: &result)
            appendDominant(rounds: 100, key: 501, cost: 90, into: &result)
        case "alternating":
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
        case "cold-cardinality":
            for index in 0..<10_000 { result.append(.init(key: 100_000 + index, cost: 10)) }
        case "long-hot-single-challenger":
            appendDominant(rounds: 400, key: 500, cost: 90, into: &result)
            for _ in 0..<64 { result.append(.init(key: 501, cost: 90)) }
        case "long-candidate-hot-victim":
            appendDominant(rounds: 250, key: 500, cost: 90, into: &result)
            for round in 0..<600 {
                result.append(.init(key: 501, cost: 90))
                if round % 4 == 0 { result.append(.init(key: 500, cost: 90)) }
            }
        case "repeated-phase-cycles":
            for _ in 0..<8 {
                appendDominant(rounds: 40, key: 500, cost: 90, into: &result)
                appendDominant(rounds: 40, key: 501, cost: 90, into: &result)
            }
        case "burst-contests":
            for index in 0..<500 { result.append(.init(key: 300_000 + index, cost: 90)) }
            for _ in 0..<500 { for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) } }
        case "spread-contests":
            for index in 0..<500 {
                result.append(.init(key: 400_000 + index, cost: 90))
                for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            }
        default: preconditionFailure("unknown workload")
        }
        return result
    }

    private static func appendPollution(
        rounds: Int,
        cost: Int,
        base: Int,
        into result: inout [SaturationRequest]
    ) {
        for round in 0..<rounds {
            for hot in 0..<10 { result.append(.init(key: hot, cost: 10)) }
            result.append(.init(key: base + round, cost: cost))
        }
    }

    private static func appendDominant(
        rounds: Int,
        key: Int,
        cost: Int,
        into result: inout [SaturationRequest]
    ) {
        for round in 0..<rounds {
            for _ in 0..<9 { result.append(.init(key: key, cost: cost)) }
            result.append(.init(key: round % 10, cost: 10))
        }
    }
}
