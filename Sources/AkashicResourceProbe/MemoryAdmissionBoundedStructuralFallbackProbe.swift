import AkashicMemory
import Foundation

private enum BoundedStructuralFallback: String, CaseIterable, Codable {
    case classicAdmit
    case resourceReject
    case secondTouchAdmit
    case secondTouchDeferredFullReplace
}

private struct BoundedStructuralFallbackRequest {
    let key: Int
    let cost: Int
    let className: String
}

private struct BoundedStructuralFallbackRow: Codable {
    let fallback: String
    let workload: String
    let requests: Int
    let hits: Int
    let misses: Int
    let giantHits: Int
    let hotHits: Int
    let boundedSnapshotSuccesses: Int
    let boundedSnapshotFailures: Int
    let victimLimitFailures: Int
    let inspectionLimitFailures: Int
    let provisionalLimitFailures: Int
    let fallbackAdmissions: Int
    let fallbackRejections: Int
    let deferredFullReplacements: Int
    let maximumCacheCost: Int
}

private struct BoundedStructuralFallbackReport: Codable {
    let schemaVersion: Int
    let cacheCostLimit: Int
    let maximumVictimCount: Int
    let maximumInspectedSlotCount: Int
    let workloads: [String]
    let rows: [BoundedStructuralFallbackRow]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

private final class BoundedStructuralFallbackCache {
    private let cache = MemoryCache<Int, Int>(costLimit: 90)
    private let fallback: BoundedStructuralFallback
    private var secondTouchPending: Set<Int> = []

    private(set) var boundedSnapshotSuccesses = 0
    private(set) var boundedSnapshotFailures = 0
    private(set) var victimLimitFailures = 0
    private(set) var inspectionLimitFailures = 0
    private(set) var provisionalLimitFailures = 0
    private(set) var fallbackAdmissions = 0
    private(set) var fallbackRejections = 0
    private(set) var deferredFullReplacements = 0
    private(set) var maximumCacheCost = 0

    init(fallback: BoundedStructuralFallback) {
        self.fallback = fallback
        for key in 0..<9 {
            cache.insert(key, for: key, cost: 10)
        }
        for key in 0..<9 { _ = cache.value(for: key) }
        sampleBounds()
    }

    func request(_ request: BoundedStructuralFallbackRequest) -> Bool {
        if cache.value(for: request.key) != nil {
            secondTouchPending.remove(request.key)
            sampleBounds()
            return true
        }

        if request.cost < 90 {
            cache.insert(request.key, for: request.key, cost: request.cost)
            sampleBounds()
            return false
        }

        let bounded = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: request.cost,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: 4,
            maximumInspectedSlotCount: 16
        )
        if let snapshot = bounded.snapshot {
            boundedSnapshotSuccesses += 1
            let committed = cache.resourceProbeInsertIfRevocationAwarePlanMatches(
                request.key,
                for: request.key,
                cost: request.cost,
                expectedSnapshot: snapshot
            )
            precondition(committed)
            secondTouchPending.remove(request.key)
            sampleBounds()
            return false
        }

        boundedSnapshotFailures += 1
        switch bounded.limitReason {
        case .victimCount: victimLimitFailures += 1
        case .inspectedSlotCount: inspectionLimitFailures += 1
        case .provisionalLeaseCount: provisionalLimitFailures += 1
        case nil: preconditionFailure("limited bounded snapshot must name a reason")
        }

        switch fallback {
        case .classicAdmit:
            cache.insert(request.key, for: request.key, cost: request.cost)
            fallbackAdmissions += 1
        case .resourceReject:
            fallbackRejections += 1
        case .secondTouchAdmit, .secondTouchDeferredFullReplace:
            if secondTouchPending.remove(request.key) != nil {
                if fallback == .secondTouchDeferredFullReplace {
                    let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
                        request.key,
                        for: request.key,
                        cost: request.cost,
                        maximumConcurrentRetirements: 1
                    )
                    precondition(attempt.disposition == .replaced)
                    precondition(attempt.summary != nil)
                    deferredFullReplacements += 1
                } else {
                    cache.insert(request.key, for: request.key, cost: request.cost)
                }
                fallbackAdmissions += 1
            } else {
                secondTouchPending.insert(request.key)
                fallbackRejections += 1
            }
        }
        sampleBounds()
        return false
    }

    private func sampleBounds() {
        precondition(cache.currentCost <= 90)
        maximumCacheCost = max(maximumCacheCost, cache.currentCost)
    }
}

enum MemoryAdmissionBoundedStructuralFallbackProbe {
    private static let workloads = [
        "unique-giant-pollution",
        "dominant-giant",
        "three-touch-giant-bursts",
        "giant-then-hot-phase",
        "alternating-giant-hot",
    ]

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        var rows: [BoundedStructuralFallbackRow] = []
        for fallback in BoundedStructuralFallback.allCases {
            for workload in workloads {
                rows.append(runCase(fallback: fallback, workload: workload))
            }
        }

        func row(_ fallback: BoundedStructuralFallback, _ workload: String)
            -> BoundedStructuralFallbackRow
        {
            rows.first { $0.fallback == fallback.rawValue && $0.workload == workload }!
        }

        let pollutionAdmit = row(.classicAdmit, "unique-giant-pollution")
        let pollutionReject = row(.resourceReject, "unique-giant-pollution")
        let pollutionSecond = row(.secondTouchAdmit, "unique-giant-pollution")
        let dominantAdmit = row(.classicAdmit, "dominant-giant")
        let dominantReject = row(.resourceReject, "dominant-giant")
        let dominantSecond = row(.secondTouchAdmit, "dominant-giant")
        let pollutionDeferred = row(.secondTouchDeferredFullReplace, "unique-giant-pollution")
        let dominantDeferred = row(.secondTouchDeferredFullReplace, "dominant-giant")
        let checks: [String: Bool] = [
            "all-cost-bounds-preserved": rows.allSatisfy { $0.maximumCacheCost <= 90 },
            "every-workload-fallback-pair-present": rows.count
                == workloads.count * BoundedStructuralFallback.allCases.count,
            "pollution-reject-preserves-more-hot-hits-than-classic-admit":
                pollutionReject.hotHits > pollutionAdmit.hotHits,
            "pollution-second-touch-preserves-more-hot-hits-than-classic-admit":
                pollutionSecond.hotHits > pollutionAdmit.hotHits,
            "dominant-classic-admit-beats-resource-reject":
                dominantAdmit.giantHits > dominantReject.giantHits,
            "dominant-second-touch-beats-resource-reject":
                dominantSecond.giantHits > dominantReject.giantHits,
            "deferred-full-replace-preserves-second-touch-quality-on-key-witnesses":
                pollutionDeferred.hits == pollutionSecond.hits
                    && dominantDeferred.hits == dominantSecond.hits,
            "deferred-full-replace-is-used-when-second-touch-admits-dominant":
                dominantDeferred.deferredFullReplacements == 1,
            "resource-reject-never-performs-unbounded-fallback-admission": rows
                .filter { $0.fallback == BoundedStructuralFallback.resourceReject.rawValue }
                .allSatisfy { $0.fallbackAdmissions == 0 },
        ]
        let observations: [String: Bool] = [
            "classic-admit-and-resource-reject-have-opposite-winners":
                pollutionReject.hits > pollutionAdmit.hits
                    && dominantAdmit.hits > dominantReject.hits,
            "second-touch-reduces-one-off-pollution-without-starving-dominant-giant":
                pollutionSecond.hits > pollutionAdmit.hits
                    && dominantSecond.giantHits > dominantReject.giantHits,
            "second-touch-still-has-an-unbounded-mutation-surface": rows
                .filter { $0.fallback == BoundedStructuralFallback.secondTouchAdmit.rawValue }
                .contains { $0.fallbackAdmissions > 0 },
            "deferred-full-replace-removes-classic-sieve-scan-from-full-cost-second-touch": rows
                .filter {
                    $0.fallback
                        == BoundedStructuralFallback.secondTouchDeferredFullReplace.rawValue
                }
                .allSatisfy { $0.fallbackAdmissions == $0.deferredFullReplacements },
            "bounded-evaluation-does-not-by-itself-bound-classic-insert": rows
                .filter { $0.fallback == BoundedStructuralFallback.classicAdmit.rawValue }
                .contains { $0.boundedSnapshotFailures > 0 && $0.fallbackAdmissions > 0 },
        ]

        let report = BoundedStructuralFallbackReport(
            schemaVersion: 1,
            cacheCostLimit: 90,
            maximumVictimCount: 4,
            maximumInspectedSlotCount: 16,
            workloads: workloads,
            rows: rows,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "boundedSnapshotQualified": true,
                "classicFallbackTailBounded": false,
                "resourceRejectDominantGiantSafe": false,
                "secondTouchFallbackTailBounded": false,
                "fullCostDeferredReplacementUsesVictimScan": false,
                "fullCostDeferredReplacementDefersRetirementReleaseOutsideLock": true,
                "nearFullDeferredReplacementQualified": false,
                "hostBusinessSemantics": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    private static func runCase(
        fallback: BoundedStructuralFallback,
        workload: String
    ) -> BoundedStructuralFallbackRow {
        let policy = BoundedStructuralFallbackCache(fallback: fallback)
        let trace = makeTrace(workload)
        var hits = 0
        var giantHits = 0
        var hotHits = 0
        for request in trace {
            let hit = policy.request(request)
            if hit {
                hits += 1
                if request.className == "giant" { giantHits += 1 }
                if request.className == "hot" { hotHits += 1 }
            }
        }
        return .init(
            fallback: fallback.rawValue,
            workload: workload,
            requests: trace.count,
            hits: hits,
            misses: trace.count - hits,
            giantHits: giantHits,
            hotHits: hotHits,
            boundedSnapshotSuccesses: policy.boundedSnapshotSuccesses,
            boundedSnapshotFailures: policy.boundedSnapshotFailures,
            victimLimitFailures: policy.victimLimitFailures,
            inspectionLimitFailures: policy.inspectionLimitFailures,
            provisionalLimitFailures: policy.provisionalLimitFailures,
            fallbackAdmissions: policy.fallbackAdmissions,
            fallbackRejections: policy.fallbackRejections,
            deferredFullReplacements: policy.deferredFullReplacements,
            maximumCacheCost: policy.maximumCacheCost
        )
    }

    private static func makeTrace(_ workload: String) -> [BoundedStructuralFallbackRequest] {
        var result: [BoundedStructuralFallbackRequest] = []
        func giant(_ key: Int) {
            result.append(.init(key: key, cost: 90, className: "giant"))
        }
        func hotRound() {
            for key in 0..<9 {
                result.append(.init(key: key, cost: 10, className: "hot"))
            }
        }

        switch workload {
        case "unique-giant-pollution":
            for round in 0..<100 {
                giant(10_000 + round)
                hotRound()
            }
        case "dominant-giant":
            for _ in 0..<1_000 { giant(500) }
        case "three-touch-giant-bursts":
            for round in 0..<100 {
                let key = 20_000 + round
                giant(key); giant(key); giant(key)
                hotRound()
            }
        case "giant-then-hot-phase":
            for _ in 0..<300 { giant(600) }
            for _ in 0..<100 { hotRound() }
        case "alternating-giant-hot":
            for _ in 0..<200 {
                giant(700)
                hotRound()
            }
        default:
            preconditionFailure("unknown fallback workload")
        }
        return result
    }
}
