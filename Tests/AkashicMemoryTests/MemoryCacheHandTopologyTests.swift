import XCTest
@testable import AkashicMemory

final class MemoryCacheHandTopologyTests: XCTestCase {
    func testEmptyAndNilHandTopologyAreExact() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        let empty = cache.resourceProbeHandTopologyState()
        XCTAssertEqual(empty.residentCount, 0)
        XCTAssertEqual(empty.residentCost, 0)
        XCTAssertEqual(empty.prefixBeforeHandCount, 0)
        XCTAssertEqual(empty.prefixBeforeHandCost, 0)
        XCTAssertEqual(empty.suffixFromHandCount, 0)
        XCTAssertEqual(empty.suffixFromHandCost, 0)

        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        let initial = cache.resourceProbeHandTopologyState()
        XCTAssertEqual(initial.residentCount, 4)
        XCTAssertEqual(initial.residentCost, 4)
        XCTAssertEqual(initial.prefixBeforeHandCount, 0)
        XCTAssertEqual(initial.prefixBeforeHandCost, 0)
        XCTAssertEqual(initial.suffixFromHandCount, 4)
        XCTAssertEqual(initial.suffixFromHandCost, 4)
    }

    func testVisitedBitCanBeZeroWhilePhysicalPrefixRemainsBehindHand() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        XCTAssertTrue(cache.resourceProbeMarkVisited(for: 0))
        cache.insert(4, for: 4, cost: 1)

        let visits = cache.resourceProbeVisitState()
        let topology = cache.resourceProbeHandTopologyState()
        XCTAssertEqual(visits.visitedCount, 0)
        XCTAssertEqual(topology.prefixBeforeHandCount, 1)
        XCTAssertEqual(topology.prefixBeforeHandCost, 1)
        XCTAssertEqual(topology.suffixFromHandCount, 3)
        XCTAssertEqual(topology.suffixFromHandCost, 3)

        for offset in 0..<1_024 {
            cache.insert(10_000 + offset, for: 10_000 + offset, cost: 1)
        }
        let after = cache.resourceProbeHandTopologyState()
        XCTAssertEqual(cache.resourceProbeVisitState().visitedCount, 0)
        XCTAssertEqual(after.prefixBeforeHandCount, 1)
        XCTAssertEqual(after.prefixBeforeHandCost, 1)
        XCTAssertNotNil(cache.resourceProbeValueWithoutVisit(for: 0))
    }

    func testAllVisitedEpochResetDoesNotInventPrefixBeforeHand() {
        let cache = MemoryCache<Int, Int>(costLimit: 4)
        for key in 0..<4 { cache.insert(key, for: key, cost: 1) }
        for key in 0..<4 { XCTAssertTrue(cache.resourceProbeMarkVisited(for: key)) }

        cache.insert(4, for: 4, cost: 1)
        let topology = cache.resourceProbeHandTopologyState()
        XCTAssertEqual(topology.residentCount, 4)
        XCTAssertEqual(topology.residentCost, 4)
        XCTAssertEqual(topology.prefixBeforeHandCount, 0)
        XCTAssertEqual(topology.prefixBeforeHandCost, 0)
        XCTAssertEqual(topology.suffixFromHandCount, 4)
        XCTAssertEqual(topology.suffixFromHandCost, 4)
    }

    func testShardedTopologyReportsIndependentHandPrefixes() {
        let shardCount = 4
        let cache = ShardedMemoryCache<Int, Int>(costLimit: 64, shardCount: shardCount)
        let (originals, next) = keysByShard(shardCount: shardCount, countPerShard: 16, startingAt: 1_000_000)
        let (stream, _) = keysByShard(shardCount: shardCount, countPerShard: 256, startingAt: next + 10_000)

        for slot in 0..<16 {
            for shard in 0..<shardCount {
                let key = originals[shard][slot]
                cache.insert(key, for: key, cost: 1)
            }
        }
        for shard in 0..<shardCount {
            for slot in 0..<14 {
                XCTAssertNotNil(cache.value(for: originals[shard][slot]))
            }
        }
        for slot in 0..<256 {
            for shard in 0..<shardCount {
                let key = stream[shard][slot]
                cache.insert(key, for: key, cost: 1)
            }
        }

        let states = cache.resourceProbeHandTopologyStates()
        XCTAssertEqual(states.count, 4)
        XCTAssertTrue(states.allSatisfy { $0.residentCount == 16 && $0.residentCost == 16 })
        XCTAssertTrue(states.allSatisfy { $0.prefixBeforeHandCount == 14 && $0.prefixBeforeHandCost == 14 })
        XCTAssertTrue(states.allSatisfy { $0.suffixFromHandCount == 2 && $0.suffixFromHandCost == 2 })
        XCTAssertEqual(states.reduce(0) { $0 + $1.prefixBeforeHandCost }, 56)
        XCTAssertEqual(states.reduce(0) { $0 + $1.suffixFromHandCost }, 8)
    }

    private func keysByShard(shardCount: Int, countPerShard: Int, startingAt start: Int) -> ([[Int]], Int) {
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
