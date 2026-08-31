import Foundation

private struct SegmentedLocalityReuseGapSummary: Codable {
    let repeatedRequestCount: Int
    let meanGapOperations: Double?
    let p50GapOperations: Int?
    let p95GapOperations: Int?
    let p99GapOperations: Int?
    let maximumGapOperations: Int?
}

private struct SegmentedLocalityBlockSummary: Codable {
    let blockIndex: Int
    let operationCount: Int
    let distinctKeyCount: Int
    let idealLastWriteCoalescingRatio: Double
}

private struct SegmentedLocalityTraceSummary: Codable {
    let name: String
    let operationCount: Int
    let distinctKeyCount: Int
    let firstHalfDistinctKeyCount: Int
    let secondHalfDistinctKeyCount: Int
    let idealLastWriteCoalescedMutationCount: Int
    let idealLastWriteCoalescingRatio: Double
    let top1RequestFraction: Double
    let top8RequestFraction: Double
    let top32RequestFraction: Double
    let normalizedShannonEntropy: Double
    let reuseGap: SegmentedLocalityReuseGapSummary
    let blockSize: Int
    let blocks: [SegmentedLocalityBlockSummary]
}

private struct SegmentedLocalityTraceReport: Codable {
    struct Claims: Codable {
        let workloadTraceCharacterization: Bool
        let segmentedManifestIOEvaluated: Bool
        let compactionPolicyEvaluated: Bool
        let formalPerformance: Bool
        let writeAmplificationMeasured: Bool
        let crashRecoveryEvaluated: Bool
        let productionWorkloadDistributionClaim: Bool
    }

    let schemaVersion: Int
    let operationCountPerTrace: Int
    let blockSize: Int
    let traceCount: Int
    let traces: [SegmentedLocalityTraceSummary]
    let allTracesDeterministicAndBounded: Bool
    let claims: Claims
}

/// Deterministic workload-characterization layer for future segmented-manifest experiments.
///
/// It intentionally does *not* model segment bytes, checkpoint thresholds, filesystem writes or
/// recovery cost. The output exists to prevent future actual-I/O experiments from comparing only
/// the pathological endpoints "one hot key" and "all distinct keys".
enum SegmentedManifestLocalityTraceProbe {
    private static let operationCount = 8_192
    private static let blockSize = 512
    private static let universe = 512

    static func run() throws {
        let traces: [(String, [Int])] = [
            ("uniform-working-set-1", uniformTrace(workingSet: 1)),
            ("uniform-working-set-8", uniformTrace(workingSet: 8)),
            ("uniform-working-set-32", uniformTrace(workingSet: 32)),
            ("uniform-working-set-128", uniformTrace(workingSet: 128)),
            ("uniform-working-set-512", uniformTrace(workingSet: 512)),
            ("zipf-0.75-universe-512", zipfTrace(alpha: 0.75)),
            ("zipf-1.00-universe-512", zipfTrace(alpha: 1.00)),
            ("zipf-1.25-universe-512", zipfTrace(alpha: 1.25)),
            ("phase-uniform8-to-uniform512", phaseTrace(firstWorkingSet: 8, secondWorkingSet: 512)),
            ("phase-uniform512-to-uniform8", phaseTrace(firstWorkingSet: 512, secondWorkingSet: 8)),
            ("phase-disjoint-hot8", disjointHotPhaseTrace()),
        ]
        let summaries = traces.map { summarize(name: $0.0, trace: $0.1) }
        let allTracesDeterministicAndBounded = traces.allSatisfy { _, trace in
            trace.count == operationCount
                && trace.allSatisfy { $0 >= 0 && $0 < universe * 2 }
        }
        let report = SegmentedLocalityTraceReport(
            schemaVersion: 1,
            operationCountPerTrace: operationCount,
            blockSize: blockSize,
            traceCount: summaries.count,
            traces: summaries,
            allTracesDeterministicAndBounded: allTracesDeterministicAndBounded,
            claims: .init(
                workloadTraceCharacterization: true,
                segmentedManifestIOEvaluated: false,
                compactionPolicyEvaluated: false,
                formalPerformance: false,
                writeAmplificationMeasured: false,
                crashRecoveryEvaluated: false,
                productionWorkloadDistributionClaim: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allTracesDeterministicAndBounded,
              summaries.first(where: { $0.name == "uniform-working-set-1" })?
                .idealLastWriteCoalescedMutationCount == 1,
              summaries.first(where: { $0.name == "uniform-working-set-512" })?
                .blocks.allSatisfy({ $0.distinctKeyCount == 512 }) == true
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func uniformTrace(workingSet: Int, base: Int = 0) -> [Int] {
        precondition(workingSet > 0 && workingSet <= universe)
        return (0..<operationCount).map { base + ($0 % workingSet) }
    }

    private static func phaseTrace(firstWorkingSet: Int, secondWorkingSet: Int) -> [Int] {
        let half = operationCount / 2
        return (0..<half).map { $0 % firstWorkingSet }
            + (0..<half).map { $0 % secondWorkingSet }
    }

    private static func disjointHotPhaseTrace() -> [Int] {
        let half = operationCount / 2
        return (0..<half).map { $0 % 8 }
            + (0..<half).map { universe + ($0 % 8) }
    }

    private static func zipfTrace(alpha: Double) -> [Int] {
        precondition(alpha > 0)
        let weights = (0..<universe).map { rank in
            1.0 / pow(Double(rank + 1), alpha)
        }
        let total = weights.reduce(0, +)
        var cumulative: [Double] = []
        cumulative.reserveCapacity(universe)
        var running = 0.0
        for weight in weights {
            running += weight / total
            cumulative.append(running)
        }
        cumulative[cumulative.count - 1] = 1.0
        return (0..<operationCount).map { index in
            let unit = radicalInverseBase2(UInt64(index + 1))
            var low = 0
            var high = cumulative.count - 1
            while low < high {
                let mid = (low + high) / 2
                if unit < cumulative[mid] { high = mid }
                else { low = mid + 1 }
            }
            return low
        }
    }

    private static func radicalInverseBase2(_ input: UInt64) -> Double {
        var value = input
        var reversed: UInt64 = 0
        var bits = 0
        while value > 0 {
            reversed = (reversed << 1) | (value & 1)
            value >>= 1
            bits += 1
        }
        return Double(reversed) / Double(UInt64(1) << UInt64(bits))
    }

    private static func summarize(name: String, trace: [Int]) -> SegmentedLocalityTraceSummary {
        precondition(trace.count == operationCount)
        let half = trace.count / 2
        let frequencies = Dictionary(grouping: trace, by: { $0 }).mapValues(\.count)
        let orderedCounts = frequencies.values.sorted(by: >)
        let total = Double(trace.count)
        let top1 = Double(orderedCounts.prefix(1).reduce(0, +)) / total
        let top8 = Double(orderedCounts.prefix(8).reduce(0, +)) / total
        let top32 = Double(orderedCounts.prefix(32).reduce(0, +)) / total
        let entropy = orderedCounts.reduce(0.0) { partial, count in
            let probability = Double(count) / total
            return partial - probability * log2(probability)
        }
        let maximumEntropy = log2(Double(max(1, frequencies.count)))
        let normalizedEntropy = maximumEntropy > 0 ? entropy / maximumEntropy : 0

        var last: [Int: Int] = [:]
        var gaps: [Int] = []
        gaps.reserveCapacity(trace.count)
        for (index, key) in trace.enumerated() {
            if let previous = last.updateValue(index, forKey: key) {
                gaps.append(index - previous)
            }
        }
        let sortedGaps = gaps.sorted()
        let reuse = SegmentedLocalityReuseGapSummary(
            repeatedRequestCount: gaps.count,
            meanGapOperations: gaps.isEmpty
                ? nil : Double(gaps.reduce(0, +)) / Double(gaps.count),
            p50GapOperations: percentile(sortedGaps, 0.50),
            p95GapOperations: percentile(sortedGaps, 0.95),
            p99GapOperations: percentile(sortedGaps, 0.99),
            maximumGapOperations: sortedGaps.last
        )
        let blocks = stride(from: 0, to: trace.count, by: blockSize).enumerated().map {
            blockIndex, start in
            let end = min(trace.count, start + blockSize)
            let distinct = Set(trace[start..<end]).count
            return SegmentedLocalityBlockSummary(
                blockIndex: blockIndex,
                operationCount: end - start,
                distinctKeyCount: distinct,
                idealLastWriteCoalescingRatio: Double(distinct) / Double(end - start)
            )
        }
        return SegmentedLocalityTraceSummary(
            name: name,
            operationCount: trace.count,
            distinctKeyCount: frequencies.count,
            firstHalfDistinctKeyCount: Set(trace[..<half]).count,
            secondHalfDistinctKeyCount: Set(trace[half...]).count,
            idealLastWriteCoalescedMutationCount: frequencies.count,
            idealLastWriteCoalescingRatio: Double(frequencies.count) / total,
            top1RequestFraction: top1,
            top8RequestFraction: top8,
            top32RequestFraction: top32,
            normalizedShannonEntropy: normalizedEntropy,
            reuseGap: reuse,
            blockSize: blockSize,
            blocks: blocks
        )
    }

    private static func percentile(_ sorted: [Int], _ quantile: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * quantile)) - 1))
        return sorted[index]
    }
}
