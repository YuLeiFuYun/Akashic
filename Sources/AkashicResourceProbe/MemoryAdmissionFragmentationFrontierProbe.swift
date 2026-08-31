import AkashicMemory
import Foundation

private struct AdmissionFragmentationLayout {
    let name: String
    let costs: [Int]
}

private struct AdmissionFragmentationRow: Codable {
    let layout: String
    let residentCount: Int
    let residentCost: Int
    let totalCost: Int
    let nearFullIncomingCost: Int
    let exactVictimCount: Int
    let exactInspectedSlotCount: Int
    let exactReleasedCost: Int
    let boundedSnapshotSucceeded: Bool
    let boundedLimitReason: String?
    let boundedVictimCountObserved: Int
    let boundedInspectedSlotCountObserved: Int
    let strictBoundedRepeatedHits: Int
    let classicRepeatedHits: Int
    let nearFullDeferredDisposition: String
    let survivorBulkDisposition: String
    let survivorBulkSurvivorCount: Int
    let survivorBulkInspectedSlotCount: Int
    let survivorBulkRepeatedHits: Int
    let fullCostDeferredRepeatedHits: Int
}

private struct AdmissionFragmentationReport: Codable {
    let schemaVersion: Int
    let cacheCostLimit: Int
    let nearFullIncomingCost: Int
    let repeatedRequestCount: Int
    let maximumVictimCount: Int
    let maximumInspectedSlotCount: Int
    let rows: [AdmissionFragmentationRow]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum MemoryAdmissionFragmentationFrontierProbe {
    private static let costLimit = 90
    private static let nearFullCost = 80
    private static let requestCount = 8
    private static let maximumVictimCount = 4
    private static let maximumInspectedSlotCount = 16
    private static let layouts: [AdmissionFragmentationLayout] = [
        .init(name: "3x30", costs: [Int](repeating: 30, count: 3)),
        .init(name: "6x15", costs: [Int](repeating: 15, count: 6)),
        .init(name: "9x10", costs: [Int](repeating: 10, count: 9)),
        .init(name: "18x5", costs: [Int](repeating: 5, count: 18)),
        .init(name: "45x2", costs: [Int](repeating: 2, count: 45)),
        .init(name: "90x1", costs: [Int](repeating: 1, count: 90)),
    ]

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let rows = try layouts.map(runLayout)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.layout, $0) })
        let exactVictimCounts = rows.map(\.exactVictimCount)

        let checks: [String: Bool] = [
            "all-layouts-have-identical-total-cost": rows.allSatisfy {
                $0.totalCost == costLimit
            },
            "exact-victim-count-follows-resident-granularity":
                exactVictimCounts == [3, 6, 8, 16, 40, 80],
            "coarse-layout-fits-four-victim-budget":
                byName["3x30"]?.boundedSnapshotSucceeded == true
                    && byName["3x30"]?.strictBoundedRepeatedHits == requestCount - 1,
            "finer-layouts-cross-the-same-four-victim-budget": rows.dropFirst().allSatisfy {
                !$0.boundedSnapshotSucceeded
                    && $0.boundedLimitReason == "victimCount"
                    && $0.strictBoundedRepeatedHits == 0
            },
            "classic-control-admits-dominant-near-full-key": rows.allSatisfy {
                $0.classicRepeatedHits == requestCount - 1
            },
            "near-full-request-cannot-use-exact-full-cost-retirement-shortcut": rows.allSatisfy {
                $0.nearFullDeferredDisposition == "ineligible"
            },
            "all-visited-survivor-bulk-admits-every-fragmentation-layout": rows.allSatisfy {
                $0.survivorBulkDisposition == "replaced"
                    && $0.survivorBulkRepeatedHits == requestCount - 1
            },
            "survivor-bulk-output-follows-residual-budget-not-victim-count":
                rows.map(\.survivorBulkSurvivorCount) == [0, 0, 1, 2, 5, 10]
                    && rows.map(\.survivorBulkInspectedSlotCount) == [1, 1, 1, 2, 5, 10],
            "exact-full-cost-retirement-shortcut-is-fragmentation-independent": rows.allSatisfy {
                $0.fullCostDeferredRepeatedHits == requestCount - 1
            },
        ]
        let observations: [String: Bool] = [
            "resident-cost-fragmentation-alone-switches-bounded-admissibility":
                byName["3x30"]?.boundedSnapshotSucceeded == true
                    && byName["6x15"]?.boundedSnapshotSucceeded == false,
            "fixed-victim-budget-can-starve-a-repeated-dominant-near-full-key":
                rows.dropFirst().allSatisfy {
                    $0.strictBoundedRepeatedHits == 0
                        && $0.classicRepeatedHits == requestCount - 1
                },
            "exact-full-cost-o1-path-does-not-generalize-to-near-full-cost": rows.allSatisfy {
                $0.nearFullDeferredDisposition == "ineligible"
                    && $0.fullCostDeferredRepeatedHits == requestCount - 1
            },
            "survivor-dual-removes-the-fixed-victim-fragmentation-cliff-on-all-visited-state":
                rows.dropFirst().allSatisfy {
                    $0.strictBoundedRepeatedHits == 0
                        && $0.survivorBulkRepeatedHits == requestCount - 1
                },
            "raising-a-fixed-victim-budget-only-moves-the-fragmentation-cliff":
                exactVictimCounts.last! > maximumVictimCount
                    && Set(exactVictimCounts).count == exactVictimCounts.count,
        ]

        let report = AdmissionFragmentationReport(
            schemaVersion: 1,
            cacheCostLimit: costLimit,
            nearFullIncomingCost: nearFullCost,
            repeatedRequestCount: requestCount,
            maximumVictimCount: maximumVictimCount,
            maximumInspectedSlotCount: maximumInspectedSlotCount,
            rows: rows,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "residentCostFragmentationMechanism": true,
                "fixedVictimBudgetUniversallyQualitySafe": false,
                "nearFullDeferredReplacementQualified": false,
                "fullCostDeferredReplacementFragmentationIndependent": true,
                "allVisitedSurvivorBulkFragmentationQualified": true,
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

    private static func runLayout(_ layout: AdmissionFragmentationLayout) throws
        -> AdmissionFragmentationRow
    {
        precondition(layout.costs.reduce(0, +) == costLimit)

        let exact = makeHotCache(costs: layout.costs)
            .resourceProbeRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: nearFullCost
            ).plan

        let boundedCache = makeHotCache(costs: layout.costs)
        let bounded = boundedCache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: [],
            incomingCost: nearFullCost,
            maximumProvisionalLeaseCount: 0,
            maximumVictimCount: maximumVictimCount,
            maximumInspectedSlotCount: maximumInspectedSlotCount
        )

        let strictHits = try repeatedStrictBoundedHits(costs: layout.costs)
        let classicHits = repeatedClassicHits(costs: layout.costs)

        let nearFullDeferredCache = makeHotCache(costs: layout.costs)
        let nearFullDeferred = nearFullDeferredCache
            .resourceProbeTryInsertFullCostUsingDeferredRetirement(
                10_000,
                for: 10_000,
                cost: nearFullCost,
                maximumConcurrentRetirements: 1
            )
        precondition(nearFullDeferredCache.count == layout.costs.count)
        precondition(nearFullDeferredCache.currentCost == costLimit)

        let survivorBulkCache = makeHotCache(costs: layout.costs)
        let survivorBulk = survivorBulkCache
            .resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
                10_001,
                for: 10_001,
                cost: nearFullCost,
                maximumSurvivorCount: 10,
                maximumInspectedSlotCount: 10,
                maximumConcurrentRetirements: 1
            )
        let survivorBulkHits = try repeatedSurvivorBulkHits(costs: layout.costs)

        let fullCostHits = try repeatedFullCostDeferredHits(costs: layout.costs)

        return .init(
            layout: layout.name,
            residentCount: layout.costs.count,
            residentCost: layout.costs[0],
            totalCost: layout.costs.reduce(0, +),
            nearFullIncomingCost: nearFullCost,
            exactVictimCount: exact.victims.count,
            exactInspectedSlotCount: exact.inspectedSlotCount,
            exactReleasedCost: exact.releasedCost,
            boundedSnapshotSucceeded: bounded.snapshot != nil,
            boundedLimitReason: bounded.limitReason?.rawValue,
            boundedVictimCountObserved: bounded.victimCount,
            boundedInspectedSlotCountObserved: bounded.inspectedSlotCount,
            strictBoundedRepeatedHits: strictHits,
            classicRepeatedHits: classicHits,
            nearFullDeferredDisposition: nearFullDeferred.disposition.rawValue,
            survivorBulkDisposition: survivorBulk.disposition.rawValue,
            survivorBulkSurvivorCount: survivorBulk.survivorCount,
            survivorBulkInspectedSlotCount: survivorBulk.inspectedSlotCount,
            survivorBulkRepeatedHits: survivorBulkHits,
            fullCostDeferredRepeatedHits: fullCostHits
        )
    }

    private static func repeatedStrictBoundedHits(costs: [Int]) throws -> Int {
        let cache = makeHotCache(costs: costs)
        let key = 20_000
        var hits = 0
        for _ in 0..<requestCount {
            if cache.value(for: key) != nil {
                hits += 1
                continue
            }
            let bounded = cache.resourceProbeBoundedRevocationAwareEvictionSnapshot(
                provisionalVisitedKeys: [],
                incomingCost: nearFullCost,
                maximumProvisionalLeaseCount: 0,
                maximumVictimCount: maximumVictimCount,
                maximumInspectedSlotCount: maximumInspectedSlotCount
            )
            guard let snapshot = bounded.snapshot else { continue }
            let committed = cache.resourceProbeCommitRevocationAwareSnapshot(
                key,
                for: key,
                cost: nearFullCost,
                expectedSnapshot: snapshot
            )
            guard committed.accepted else { throw ProbeError.resourceSampleFailed }
        }
        return hits
    }

    private static func repeatedClassicHits(costs: [Int]) -> Int {
        let cache = makeHotCache(costs: costs)
        let key = 30_000
        var hits = 0
        for _ in 0..<requestCount {
            if cache.value(for: key) != nil {
                hits += 1
            } else {
                cache.insert(key, for: key, cost: nearFullCost)
            }
        }
        precondition(cache.currentCost <= costLimit)
        return hits
    }

    private static func repeatedSurvivorBulkHits(costs: [Int]) throws -> Int {
        let cache = makeHotCache(costs: costs)
        let key = 35_000
        var hits = 0
        for _ in 0..<requestCount {
            if cache.value(for: key) != nil {
                hits += 1
                continue
            }
            let attempt = cache.resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
                key,
                for: key,
                cost: nearFullCost,
                maximumSurvivorCount: 10,
                maximumInspectedSlotCount: 10,
                maximumConcurrentRetirements: 1
            )
            guard attempt.disposition == .replaced else {
                throw ProbeError.resourceSampleFailed
            }
        }
        precondition(cache.currentCost <= costLimit)
        return hits
    }

    private static func repeatedFullCostDeferredHits(costs: [Int]) throws -> Int {
        let cache = makeHotCache(costs: costs)
        let key = 40_000
        var hits = 0
        for _ in 0..<requestCount {
            if cache.value(for: key) != nil {
                hits += 1
                continue
            }
            let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
                key,
                for: key,
                cost: costLimit,
                maximumConcurrentRetirements: 1
            )
            guard attempt.disposition == .replaced else {
                throw ProbeError.resourceSampleFailed
            }
        }
        precondition(cache.count == 1)
        precondition(cache.currentCost == costLimit)
        return hits
    }

    private static func makeHotCache(costs: [Int]) -> MemoryCache<Int, Int> {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        for (key, cost) in costs.enumerated() {
            cache.insert(key, for: key, cost: cost)
        }
        precondition(cache.currentCost == costLimit)
        for key in costs.indices { precondition(cache.value(for: key) == key) }
        return cache
    }
}
