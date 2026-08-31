import Foundation
import AkashicMemory

package enum MemorySIEVEDelayedSecondTouchProbe {
    private static let costLimit = 1_024
    private static let rounds = 64
    private static let scanBytesPerRound = 256
    private static let delays = [0, 64, 256, 512, 1_024, 2_048]
    private static let coreStrides = [4, 16]
    private static let warmStrides = [2, 8]
    private static let scanCosts = [4, 64]

    private enum SecondMode: String, Codable, CaseIterable {
        case touchOnly = "touch-only"
        case requestReinsert = "request-reinsert"
    }

    private enum Topology: String, Codable, CaseIterable {
        case fillerWarmCore = "filler-warm-core"
        case coreWarmFiller = "core-warm-filler"
        case shuffle73 = "shuffle73"
    }

    private struct Resident: Sendable {
        let key: String
        let cost: Int
    }

    private struct PendingSecond {
        let targetPressure: Int
        let key: String
        let cost: Int
    }

    private struct CaseReport: Codable {
        let topology: Topology
        let coreStride: Int
        let warmStride: Int
        let scanObjectCost: Int
        let delayBytes: Int
        let delayCacheTurns: Double
        let secondMode: SecondMode
        let coreHitRatio: Double
        let warmHitRatio: Double
        let coreRefillBytes: Int
        let warmRefillBytes: Int
        let secondHitRatio: Double
        let secondHits: Int
        let secondMisses: Int
        let secondReinsertions: Int
        let pendingSecondRequestsAtEnd: Int
        let residentCost: Int
    }

    private struct BaselineReport: Codable {
        let topology: Topology
        let coreStride: Int
        let warmStride: Int
        let scanObjectCost: Int
        let coreHitRatio: Double
        let warmHitRatio: Double
        let coreRefillBytes: Int
        let warmRefillBytes: Int
    }

    private struct DelaySummary: Codable {
        let secondMode: SecondMode
        let delayBytes: Int
        let delayCacheTurns: Double
        let minimumCoreHitRatio: Double
        let minimumWarmHitRatio: Double
        let meanCoreHitRatio: Double
        let meanWarmHitRatio: Double
        let minimumSecondHitRatio: Double
        let meanSecondHitRatio: Double
        let maximumCoreRefillBytes: Int
        let maximumWarmRefillBytes: Int
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let implementation: String
        let cacheCostLimit: Int
        let scanBytesPerRound: Int
        let rounds: Int
        let baselineCaseCount: Int
        let baselineMinimumCoreHitRatio: Double
        let baselineMinimumWarmHitRatio: Double
        let caseCount: Int
        let summaryByDelay: [DelaySummary]
        let worstCases: [CaseReport]
        let checks: [String: Bool]
        let allGatesPass: Bool
        let claimBoundary: String
    }

    private static let filler: [Resident] = (0..<128).map { Resident(key: "f\($0)", cost: 4) }
    private static let warm: [Resident] = (0..<64).map { Resident(key: "w\($0)", cost: 4) }
    private static let core: [Resident] = (0..<64).map { Resident(key: "c\($0)", cost: 4) }

    package static func run() throws {
        var baselines: [BaselineReport] = []
        var cases: [CaseReport] = []

        for topology in Topology.allCases {
            for coreStride in coreStrides {
                for warmStride in warmStrides {
                    for scanCost in scanCosts {
                        baselines.append(
                            runBaseline(
                                topology: topology,
                                coreStride: coreStride,
                                warmStride: warmStride,
                                scanCost: scanCost
                            )
                        )
                        for delay in delays {
                            for mode in SecondMode.allCases {
                                cases.append(
                                    runCase(
                                        topology: topology,
                                        coreStride: coreStride,
                                        warmStride: warmStride,
                                        scanCost: scanCost,
                                        delayBytes: delay,
                                        secondMode: mode
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }

        let baselineMinCore = baselines.map(\.coreHitRatio).min() ?? 0
        let baselineMinWarm = baselines.map(\.warmHitRatio).min() ?? 0
        var summaries: [DelaySummary] = []
        for mode in SecondMode.allCases {
            for delay in delays {
                let rows = cases.filter { $0.secondMode == mode && $0.delayBytes == delay }
                summaries.append(
                    DelaySummary(
                        secondMode: mode,
                        delayBytes: delay,
                        delayCacheTurns: Double(delay) / Double(costLimit),
                        minimumCoreHitRatio: rows.map(\.coreHitRatio).min() ?? 0,
                        minimumWarmHitRatio: rows.map(\.warmHitRatio).min() ?? 0,
                        meanCoreHitRatio: mean(rows.map(\.coreHitRatio)),
                        meanWarmHitRatio: mean(rows.map(\.warmHitRatio)),
                        minimumSecondHitRatio: rows.map(\.secondHitRatio).min() ?? 0,
                        meanSecondHitRatio: mean(rows.map(\.secondHitRatio)),
                        maximumCoreRefillBytes: rows.map(\.coreRefillBytes).max() ?? 0,
                        maximumWarmRefillBytes: rows.map(\.warmRefillBytes).max() ?? 0
                    )
                )
            }
        }

        let immediate = summaries.first { $0.secondMode == .touchOnly && $0.delayBytes == 0 }
        let longTouch = summaries.first { $0.secondMode == .touchOnly && $0.delayBytes == 2_048 }
        let longRequest = summaries.first { $0.secondMode == .requestReinsert && $0.delayBytes == 2_048 }
        let checks: [String: Bool] = [
            "noSecondTouchPreservesCoreInFocusedMatrix": baselineMinCore == 1,
            "noSecondTouchPreservesWarmInFocusedMatrix": baselineMinWarm == 1,
            "immediateSecondTouchCreatesHotSetDamage": (immediate?.minimumCoreHitRatio ?? 1) < 0.5
                && (immediate?.minimumWarmHitRatio ?? 1) < 0.5,
            "delayedSecondRequestCanMiss": (longTouch?.meanSecondHitRatio ?? 1) < (immediate?.meanSecondHitRatio ?? 0),
            "requestReinsertDiffersFromTouchOnlyAtLongDelay": longTouch != nil && longRequest != nil && (
                longTouch!.meanCoreHitRatio != longRequest!.meanCoreHitRatio
                    || longTouch!.meanWarmHitRatio != longRequest!.meanWarmHitRatio
                    || longTouch!.maximumCoreRefillBytes != longRequest!.maximumCoreRefillBytes
                    || longTouch!.maximumWarmRefillBytes != longRequest!.maximumWarmRefillBytes
            ),
            "residentCostNeverExceedsLimit": cases.allSatisfy { $0.residentCost <= costLimit },
        ]
        let worst = cases.sorted {
            let lhs = $0.coreHitRatio + $0.warmHitRatio
            let rhs = $1.coreHitRatio + $1.warmHitRatio
            if lhs != rhs { return lhs < rhs }
            if $0.coreHitRatio != $1.coreHitRatio { return $0.coreHitRatio < $1.coreHitRatio }
            return $0.warmHitRatio < $1.warmHitRatio
        }.prefix(20)
        let report = Report(
            schemaVersion: 1,
            implementation: "actual Akashic MemoryCache SIEVE",
            cacheCostLimit: costLimit,
            scanBytesPerRound: scanBytesPerRound,
            rounds: rounds,
            baselineCaseCount: baselines.count,
            baselineMinimumCoreHitRatio: baselineMinCore,
            baselineMinimumWarmHitRatio: baselineMinWarm,
            caseCount: cases.count,
            summaryByDelay: summaries,
            worstCases: Array(worst),
            checks: checks,
            allGatesPass: checks.values.allSatisfy { $0 },
            claimBoundary: "Deterministic single-threaded MemoryCache mechanism replay. No timing, concurrency, disk, authority, admission-policy, or Fovea claim."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        if !report.allGatesPass {
            throw ProbeError.invalidArguments
        }
    }

    private static func runCase(
        topology: Topology,
        coreStride: Int,
        warmStride: Int,
        scanCost: Int,
        delayBytes: Int,
        secondMode: SecondMode
    ) -> CaseReport {
        let cache = MemoryCache<String, Int>(costLimit: costLimit)
        for resident in topologyItems(topology) {
            cache.insert(1, for: resident.key, cost: resident.cost)
        }
        var pressure = 0
        var pending: [PendingSecond] = []
        var pendingHead = 0
        var scanSerial = 0
        var coreHits = 0
        var coreAccesses = 0
        var warmHits = 0
        var warmAccesses = 0
        var coreRefillBytes = 0
        var warmRefillBytes = 0
        var secondHits = 0
        var secondMisses = 0
        var secondReinsertions = 0

        func access(_ residents: [Resident], coreGroup: Bool) {
            for resident in residents {
                let hit = cache.value(for: resident.key) != nil
                if coreGroup {
                    coreAccesses += 1
                    if hit { coreHits += 1 }
                    else {
                        coreRefillBytes += resident.cost
                        cache.insert(1, for: resident.key, cost: resident.cost)
                    }
                } else {
                    warmAccesses += 1
                    if hit { warmHits += 1 }
                    else {
                        warmRefillBytes += resident.cost
                        cache.insert(1, for: resident.key, cost: resident.cost)
                    }
                }
            }
        }

        func serviceDue() {
            while pendingHead < pending.count && pending[pendingHead].targetPressure <= pressure {
                let request = pending[pendingHead]
                pendingHead += 1
                if cache.value(for: request.key) != nil {
                    secondHits += 1
                } else {
                    secondMisses += 1
                    if secondMode == .requestReinsert {
                        cache.insert(1, for: request.key, cost: request.cost)
                        secondReinsertions += 1
                    }
                }
            }
        }

        for round in 0..<rounds {
            if round % coreStride == 0 { access(core, coreGroup: true) }
            if round % warmStride == 0 { access(warm, coreGroup: false) }
            for _ in 0..<(scanBytesPerRound / scanCost) {
                let key = "s\(scanSerial)"
                scanSerial += 1
                cache.insert(1, for: key, cost: scanCost)
                pending.append(
                    PendingSecond(
                        targetPressure: pressure + scanCost + delayBytes,
                        key: key,
                        cost: scanCost
                    )
                )
                pressure += scanCost
                serviceDue()
            }
        }
        serviceDue()
        let secondTotal = secondHits + secondMisses
        return CaseReport(
            topology: topology,
            coreStride: coreStride,
            warmStride: warmStride,
            scanObjectCost: scanCost,
            delayBytes: delayBytes,
            delayCacheTurns: Double(delayBytes) / Double(costLimit),
            secondMode: secondMode,
            coreHitRatio: Double(coreHits) / Double(coreAccesses),
            warmHitRatio: Double(warmHits) / Double(warmAccesses),
            coreRefillBytes: coreRefillBytes,
            warmRefillBytes: warmRefillBytes,
            secondHitRatio: secondTotal == 0 ? 0 : Double(secondHits) / Double(secondTotal),
            secondHits: secondHits,
            secondMisses: secondMisses,
            secondReinsertions: secondReinsertions,
            pendingSecondRequestsAtEnd: pending.count - pendingHead,
            residentCost: cache.currentCost
        )
    }

    private static func runBaseline(
        topology: Topology,
        coreStride: Int,
        warmStride: Int,
        scanCost: Int
    ) -> BaselineReport {
        let cache = MemoryCache<String, Int>(costLimit: costLimit)
        for resident in topologyItems(topology) {
            cache.insert(1, for: resident.key, cost: resident.cost)
        }
        var scanSerial = 0
        var coreHits = 0
        var coreAccesses = 0
        var warmHits = 0
        var warmAccesses = 0
        var coreRefill = 0
        var warmRefill = 0
        for round in 0..<rounds {
            if round % coreStride == 0 {
                for resident in core {
                    coreAccesses += 1
                    if cache.value(for: resident.key) != nil { coreHits += 1 }
                    else {
                        coreRefill += resident.cost
                        cache.insert(1, for: resident.key, cost: resident.cost)
                    }
                }
            }
            if round % warmStride == 0 {
                for resident in warm {
                    warmAccesses += 1
                    if cache.value(for: resident.key) != nil { warmHits += 1 }
                    else {
                        warmRefill += resident.cost
                        cache.insert(1, for: resident.key, cost: resident.cost)
                    }
                }
            }
            for _ in 0..<(scanBytesPerRound / scanCost) {
                cache.insert(1, for: "n\(scanSerial)", cost: scanCost)
                scanSerial += 1
            }
        }
        return BaselineReport(
            topology: topology,
            coreStride: coreStride,
            warmStride: warmStride,
            scanObjectCost: scanCost,
            coreHitRatio: Double(coreHits) / Double(coreAccesses),
            warmHitRatio: Double(warmHits) / Double(warmAccesses),
            coreRefillBytes: coreRefill,
            warmRefillBytes: warmRefill
        )
    }

    private static func topologyItems(_ topology: Topology) -> [Resident] {
        switch topology {
        case .fillerWarmCore:
            return filler + warm + core
        case .coreWarmFiller:
            return core + warm + filler
        case .shuffle73:
            return (filler + warm + core).sorted { lhs, rhs in
                let l = shuffleRank(lhs.key)
                let r = shuffleRank(rhs.key)
                return l == r ? lhs.key < rhs.key : l < r
            }
        }
    }

    private static func shuffleRank(_ key: String) -> Int {
        let first = Int(key.utf8.first ?? 0)
        let number = Int(key.dropFirst()) ?? 0
        return (number * 73 + first * 17) % 997
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
