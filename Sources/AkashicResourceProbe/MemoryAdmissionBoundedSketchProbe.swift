import AkashicMemory
import Foundation

struct SketchClockConfig: Codable, Hashable {
    let kind: String
    let value: Int
}

struct SketchConfigFile: Codable {
    struct Family: Codable {
        let kind: String
        let values: [Int]
    }
    let families: [Family]
}

struct SketchRequest {
    let key: Int
    let cost: Int
}

struct SketchWindowEntry {
    let value: Int
    let cost: Int
}

struct SketchPolicyResult: Codable {
    let clockKind: String
    let clockValue: Int
    let width: Int
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let falseAdmits: Int
    let falseRejects: Int
    let admissionContests: Int
    let agingPasses: Int
    let maximumCounter: Int
    let counterPayloadBytes: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

struct SketchCollisionResult: Codable {
    let width: Int
    let targetKey: Int
    let colliders: [Int]
    let incrementsPerCollider: Int
    let exactTargetCount: Int
    let sketchTargetEstimate: Int
    let falseHotCreated: Bool
}

struct SketchTransactionFrontierCase: Codable {
    let workload: String
    let candidateKey: Int
    let victimKey: Int
    let evidenceColliders: [Int]
    let beforeCandidateEstimate: Int
    let beforeVictimEstimate: Int
    let beforeAdmit: Bool
    let afterCandidateEstimate: Int
    let afterVictimEstimate: Int
    let afterAdmit: Bool
    let structuralVictimsUnchanged: Bool
    let evictionStateVersionChanged: Bool
    let structuralCommitAccepted: Bool
    let structuralValidationMode: String
}

struct SketchTransactionFrontierReport: Codable {
    let schemaVersion: Int
    let width: Int
    let cases: [SketchTransactionFrontierCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

struct SketchEvidenceVersionRetryCase: Codable {
    let retryBudget: Int
    let attempts: Int
    let accepted: Bool
    let relevantEstimatesChanged: Bool
    let decisionChanged: Bool
}

struct SketchEvidenceEpochLagCase: Codable {
    let epochInterval: Int
    let observationsUntilPublishedDecisionFlip: Int
    let publishedCandidateEstimateBefore: Int
    let publishedVictimEstimateBefore: Int
    let publishedCandidateEstimateAfter: Int
    let publishedVictimEstimateAfter: Int
    let singleSketchCounterBytes: Int
    let dualSketchLogicalCounterBytes: Int
}

struct SketchEvidenceConsistencyReport: Codable {
    let schemaVersion: Int
    let width: Int
    let unrelatedEvidenceKey: Int
    let strictVersionRetries: [SketchEvidenceVersionRetryCase]
    let epochLag: [SketchEvidenceEpochLagCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

struct SketchProbeReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let shardedConcurrencyQualified: Bool
        let formalPerformance: Bool
        let fullMemoryFootprintQualified: Bool
        let deterministicHashPersistence: Bool
    }

    let schemaVersion: Int
    let rows: Int
    let widths: [Int]
    let eligibleClocks: [SketchClockConfig]
    let results: [SketchPolicyResult]
    let collisions: [SketchCollisionResult]
    let summary: [String: Bool]
    let claims: Claims
}

enum SketchEvidenceMode: String, Codable {
    case live
    case epochLatched
    case epochLatchedCandidateDelta
}

struct SketchEpochQualityRow: Codable {
    let evidenceMode: String
    let clockKind: String
    let clockValue: Int
    let width: Int
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let falseAdmits: Int
    let falseRejects: Int
    let admissionContests: Int
    let agingPasses: Int
    let counterPayloadBytes: Int
    let maximumVictimCount: Int
    let maximumVictimCost: Int
}

struct SketchEpochQualityDelta: Codable {
    let clockKind: String
    let clockValue: Int
    let width: Int
    let workload: String
    let hitDeltaLatchedMinusLive: Int
    let falseAdmitDeltaLatchedMinusLive: Int
    let falseRejectDeltaLatchedMinusLive: Int
    let counterPayloadDeltaBytes: Int
}

struct SketchEpochQualityReport: Codable {
    let schemaVersion: Int
    let clocks: [SketchClockConfig]
    let widths: [Int]
    let workloads: [String]
    let rows: [SketchEpochQualityRow]
    let deltas: [SketchEpochQualityDelta]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

struct SketchEpochHybridComparison: Codable {
    let clockKind: String
    let clockValue: Int
    let width: Int
    let workload: String
    let liveHits: Int
    let latchedHits: Int
    let candidateDeltaHits: Int
    let liveFalseAdmits: Int
    let latchedFalseAdmits: Int
    let candidateDeltaFalseAdmits: Int
    let liveFalseRejects: Int
    let latchedFalseRejects: Int
    let candidateDeltaFalseRejects: Int
    let candidateDeltaHitDeltaVsLive: Int
    let candidateDeltaHitRecoveryVsLatched: Int
}

struct SketchEpochHybridQualityReport: Codable {
    let schemaVersion: Int
    let clocks: [SketchClockConfig]
    let widths: [Int]
    let workloads: [String]
    let comparisons: [SketchEpochHybridComparison]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

struct FourRowCountMinSketch {
    static let rowCount = 4
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
        counters = Array(repeating: 0, count: Self.rowCount * width)
    }

    mutating func increment(_ key: Int) {
        for row in 0..<Self.rowCount {
            let offset = row * width + index(key, row: row)
            if counters[offset] < UInt8.max { counters[offset] &+= 1 }
            maximumCounter = max(maximumCounter, counters[offset])
        }
    }

    func estimate(_ key: Int) -> Int {
        var value = Int.max
        for row in 0..<Self.rowCount {
            value = min(value, Int(counters[row * width + index(key, row: row)]))
        }
        return value == Int.max ? 0 : value
    }

    mutating func halve() {
        for index in counters.indices { counters[index] >>= 1 }
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

/// Research-only immutable-evidence prototype. Observations mutate `active`; admission reads only
/// `published`. At an epoch boundary the active sketch is aged, then copied by value into published.
/// Swift Array COW keeps the published counter storage immutable once the next observation mutates
/// active, yielding a stable evidence epoch without holding a lock across cache mutation.
struct EpochLatchedFourRowSketch {
    private(set) var active: FourRowCountMinSketch
    private(set) var published: FourRowCountMinSketch
    let epochInterval: Int
    private(set) var observationsSincePublish = 0
    private(set) var epoch: UInt64 = 0

    init(width: Int, epochInterval: Int) {
        precondition(epochInterval > 0)
        let initial = FourRowCountMinSketch(width: width)
        self.active = initial
        self.published = initial
        self.epochInterval = epochInterval
    }

    mutating func observe(_ key: Int) {
        active.increment(key)
        observationsSincePublish += 1
        if observationsSincePublish == epochInterval {
            active.halve()
            published = active
            observationsSincePublish = 0
            epoch &+= 1
        }
    }

    mutating func publishCurrentWithoutAging() {
        published = active
        observationsSincePublish = 0
    }

    func publishedEstimate(_ key: Int) -> Int { published.estimate(key) }

    var singleSketchCounterBytes: Int { active.counters.count }
    var dualSketchLogicalCounterBytes: Int { active.counters.count + published.counters.count }
}

final class BoundedSketchAdmissionPolicy {
    private let main = MemoryCache<Int, Int>(costLimit: 90)
    private let windowLimit = 10
    private let clock: SketchClockConfig
    private let evidenceMode: SketchEvidenceMode
    private var sketch: FourRowCountMinSketch
    private var publishedSketch: FourRowCountMinSketch?
    private var exact: [Int: Int] = [:]
    private var window: [Int: SketchWindowEntry] = [:]
    private var windowOrder: [Int] = []
    private var windowCost = 0
    private var accumulatedRequestCost = 0
    private var admissionContestsForClock = 0
    private(set) var falseAdmits = 0
    private(set) var falseRejects = 0
    private(set) var admissionContests = 0
    private(set) var agingPasses = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0

    init(
        clock: SketchClockConfig,
        width: Int,
        evidenceMode: SketchEvidenceMode = .live
    ) {
        self.clock = clock
        self.evidenceMode = evidenceMode
        sketch = FourRowCountMinSketch(width: width)
    }

    var maximumCounter: Int { Int(sketch.maximumCounter) }
    var counterPayloadBytes: Int {
        sketch.counters.count * (evidenceMode == .live ? 1 : 2)
    }

    func primeHotSet() {
        for key in 0..<9 {
            main.insert(key, for: key, cost: 10)
            observe(key)
        }
        window[9] = SketchWindowEntry(value: 9, cost: 10)
        windowOrder = [9]
        windowCost = 10
        observe(9)
        for _ in 0..<2 {
            for key in 0..<10 {
                prepareBeforeRequest()
                observe(key)
                precondition(value(for: key) != nil)
                finishRequest(cost: 10)
            }
        }
        if evidenceMode != .live { publishedSketch = sketch }
        assertBounds()
    }

    func request(_ request: SketchRequest) -> Bool {
        prepareBeforeRequest()
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
            hit = false
        }
        finishRequest(cost: request.cost)
        assertBounds()
        return hit
    }

    private func prepareBeforeRequest() {
        guard clock.kind == "cost-volume" else { return }
        let interval = clock.value * 100
        while accumulatedRequestCost >= interval {
            age()
            accumulatedRequestCost -= interval
        }
    }

    private func finishRequest(cost: Int) {
        if clock.kind == "cost-volume" {
            accumulatedRequestCost += min(max(cost, 1), 100)
        }
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
        if evidenceMode != .live { publishedSketch = sketch }
        agingPasses += 1
    }

    private func value(for key: Int) -> Int? {
        if let value = main.value(for: key) { return value }
        return window[key]?.value
    }

    private func insertIntoWindow(_ request: SketchRequest) {
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
        window[request.key] = SketchWindowEntry(value: request.key, cost: request.cost)
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
        if clock.kind == "contest" {
            if admissionContestsForClock > 0,
                admissionContestsForClock % clock.value == 0
            {
                age()
            }
            admissionContestsForClock += 1
        }
        admissionContests += 1

        let exactCandidate = exact[key, default: 0]
        let exactVictims = victims.reduce(0) { $0 + exact[$1.key, default: 0] }
        let sketchCandidate = candidateAdmissionEstimate(key)
        let sketchVictims = victims.reduce(0) { $0 + victimAdmissionEstimate($1.key) }
        let exactDecision = exactCandidate > exactVictims
        let sketchDecision = sketchCandidate > sketchVictims
        if sketchDecision && !exactDecision { falseAdmits += 1 }
        if !sketchDecision && exactDecision { falseRejects += 1 }
        if sketchDecision { main.insert(value, for: key, cost: cost) }
    }

    private func candidateAdmissionEstimate(_ key: Int) -> Int {
        switch evidenceMode {
        case .live:
            sketch.estimate(key)
        case .epochLatched:
            (publishedSketch ?? sketch).estimate(key)
        case .epochLatchedCandidateDelta:
            // Candidate evidence may advance monotonically within the current publication epoch;
            // victim evidence remains immutable. A positive candidate observation therefore cannot
            // be invalidated by unrelated current-epoch victim updates, although it can still be
            // retired at the next explicit epoch boundary.
            sketch.estimate(key)
        }
    }

    private func victimAdmissionEstimate(_ key: Int) -> Int {
        switch evidenceMode {
        case .live:
            sketch.estimate(key)
        case .epochLatched, .epochLatchedCandidateDelta:
            (publishedSketch ?? sketch).estimate(key)
        }
    }

    private func assertBounds() {
        precondition(main.currentCost <= 90)
        precondition(windowCost <= 10)
        precondition(main.currentCost + windowCost <= 100)
    }
}
enum MemoryAdmissionBoundedSketchProbe {
}
