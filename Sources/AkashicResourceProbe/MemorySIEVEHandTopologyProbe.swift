import AkashicMemory
import Foundation

private struct MemorySIEVEHandTopologySingleResult: Codable {
    let afterFirstSkip: MemoryCacheHandTopologyState
    let afterLongStream: MemoryCacheHandTopologyState
    let visitedAfterFirstSkip: Int
    let visitedAfterLongStream: Int
    let targetStillResident: Bool
}

private struct MemorySIEVEHandTopologyShardedResult: Codable {
    let shardTopologies: [MemoryCacheHandTopologyState]
    let totalPrefixCost: Int
    let totalSuffixCost: Int
    let totalResidentCost: Int
}

private struct MemorySIEVEHandTopologyReport: Codable {
    struct Claims: Codable {
        let productionEvictionChanged: Bool
        let publicAPIChanged: Bool
        let formalPerformance: Bool
        let logicalAuthority: Bool
        let diskPhysicalOwnership: Bool
        let foveaBusinessSemantics: Bool
        let physicalTopologyTelemetryOnly: Bool
    }

    let schemaVersion: Int
    let single: MemorySIEVEHandTopologySingleResult
    let sharded: MemorySIEVEHandTopologyShardedResult
    let checks: [String: Bool]
    let claims: Claims
}

enum MemorySIEVEHandTopologyProbe {
    static func run() throws {
        let single = singleReplay()
        let sharded = shardedReplay()
        let checks = [
            "single-first-skip-exposes-one-byte-prefix":
                single.afterFirstSkip.prefixBeforeHandCount == 1
                    && single.afterFirstSkip.prefixBeforeHandCost == 1,
            "single-first-skip-visited-count-zero": single.visitedAfterFirstSkip == 0,
            "single-long-stream-preserves-one-byte-prefix":
                single.afterLongStream.prefixBeforeHandCount == 1
                    && single.afterLongStream.prefixBeforeHandCost == 1,
            "single-long-stream-visited-count-zero": single.visitedAfterLongStream == 0,
            "single-target-still-resident": single.targetStillResident,
            "single-partition-sums-exact":
                single.afterLongStream.prefixBeforeHandCount
                    + single.afterLongStream.suffixFromHandCount
                    == single.afterLongStream.residentCount
                    && single.afterLongStream.prefixBeforeHandCost
                        + single.afterLongStream.suffixFromHandCost
                        == single.afterLongStream.residentCost,
            "four-shards-report-four-independent-prefixes":
                sharded.shardTopologies.count == 4
                    && sharded.shardTopologies.allSatisfy {
                        $0.prefixBeforeHandCount == 14 && $0.prefixBeforeHandCost == 14
                    },
            "four-shards-report-two-byte-suffix-each":
                sharded.shardTopologies.allSatisfy {
                    $0.suffixFromHandCount == 2 && $0.suffixFromHandCost == 2
                },
            "sharded-prefix-cost-is-56": sharded.totalPrefixCost == 56,
            "sharded-suffix-cost-is-8": sharded.totalSuffixCost == 8,
            "sharded-resident-cost-is-64": sharded.totalResidentCost == 64,
        ]
        let report = MemorySIEVEHandTopologyReport(
            schemaVersion: 2,
            single: single,
            sharded: sharded,
            checks: checks,
            claims: .init(
                productionEvictionChanged: false,
                publicAPIChanged: false,
                formalPerformance: false,
                logicalAuthority: false,
                diskPhysicalOwnership: false,
                foveaBusinessSemantics: false,
                physicalTopologyTelemetryOnly: true
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else { throw ProbeError.resourceSampleFailed }
    }

    private static func singleReplay() -> MemorySIEVEHandTopologySingleResult {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        precondition(cache.resourceProbeMarkVisited(for: 0))
        cache.insert(4, for: 4, cost: 1)
        let firstTopology = cache.resourceProbeHandTopologyState()
        let firstVisit = cache.resourceProbeVisitState()

        for offset in 0..<10_000 {
            let key = 10_000 + offset
            cache.insert(key, for: key, cost: 1)
        }
        let finalTopology = cache.resourceProbeHandTopologyState()
        let finalVisit = cache.resourceProbeVisitState()
        return .init(
            afterFirstSkip: firstTopology,
            afterLongStream: finalTopology,
            visitedAfterFirstSkip: firstVisit.visitedCount,
            visitedAfterLongStream: finalVisit.visitedCount,
            targetStillResident: cache.resourceProbeValueWithoutVisit(for: 0) != nil
        )
    }

    private static func shardedReplay() -> MemorySIEVEHandTopologyShardedResult {
        let shardCount = 4
        let cache = ShardedMemoryCache<Int, Int>(costLimit: 64, shardCount: shardCount)
        let (originals, next) = keysByShard(
            shardCount: shardCount,
            countPerShard: 16,
            startingAt: 1_000_000
        )
        let (stream, _) = keysByShard(
            shardCount: shardCount,
            countPerShard: 1_000,
            startingAt: next + 10_000
        )
        for slot in 0..<16 {
            for shard in 0..<shardCount {
                let key = originals[shard][slot]
                cache.insert(key, for: key, cost: 1)
            }
        }
        for shard in 0..<shardCount {
            for slot in 0..<14 {
                precondition(cache.value(for: originals[shard][slot]) != nil)
            }
        }
        for slot in 0..<1_000 {
            for shard in 0..<shardCount {
                let key = stream[shard][slot]
                cache.insert(key, for: key, cost: 1)
            }
        }
        let topologies = cache.resourceProbeHandTopologyStates()
        return .init(
            shardTopologies: topologies,
            totalPrefixCost: topologies.reduce(0) { $0 + $1.prefixBeforeHandCost },
            totalSuffixCost: topologies.reduce(0) { $0 + $1.suffixFromHandCost },
            totalResidentCost: topologies.reduce(0) { $0 + $1.residentCost }
        )
    }

    private static func keysByShard(
        shardCount: Int,
        countPerShard: Int,
        startingAt start: Int
    ) -> ([[Int]], Int) {
        var result = Array(repeating: [Int](), count: shardCount)
        var candidate = start
        while result.contains(where: { $0.count < countPerShard }) {
            let index = Int(UInt(bitPattern: candidate.hashValue) & UInt(shardCount - 1))
            if result[index].count < countPerShard { result[index].append(candidate) }
            candidate += 1
        }
        return (result, candidate)
    }
}
