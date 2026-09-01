@testable import AkashicMemory
import Testing

@Suite("AkashicMemory sharded SIEVE cache")
struct ShardedMemoryCacheTests {
  @Test("Reporting insert returns exact local and cross-shard SIEVE victims")
  func reportingInsertReturnsExactVictims() {
    let local = ShardedMemoryCache<Int, Int>(costLimit: 3, shardCount: 1)
    local.insert(0, for: 0, cost: 1)
    local.insert(1, for: 1, cost: 1)
    local.insert(2, for: 2, cost: 1)

    let localReport = local.insertReportingEvictions(3, for: 3, cost: 1)
    #expect(localReport.evictedKeys == [0])
    #expect(localReport.summary == MemoryCacheRemovalSummary(itemCount: 1, costBytes: 1))
    #expect(local.value(for: 0) == nil)
    #expect(local.value(for: 3) == 3)

    let crossShard = ShardedMemoryCache<RoutedKey, Int>(costLimit: 102, shardCount: 3)
    let large = RoutedKey(identity: 10, routeHash: 1)
    let small = RoutedKey(identity: 11, routeHash: 2)
    let incoming = RoutedKey(identity: 12, routeHash: 0)
    crossShard.insert(10, for: large, cost: 100)
    crossShard.insert(11, for: small, cost: 1)

    let crossReport = crossShard.insertReportingEvictions(12, for: incoming, cost: 2)
    #expect(crossReport.evictedKeys == [small])
    #expect(crossReport.summary == MemoryCacheRemovalSummary(itemCount: 1, costBytes: 1))
    #expect(crossShard.value(for: large) == 10)
    #expect(crossShard.value(for: small) == nil)
    #expect(crossShard.value(for: incoming) == 12)
  }

  @Test("Reporting shrink and oversized replacement return only identities that leave residency")
  func reportingShrinkAndOversizedReplacementReturnExactVictims() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 102, shardCount: 2)
    let smallA = RoutedKey(identity: 20, routeHash: 0)
    let smallB = RoutedKey(identity: 21, routeHash: 0)
    let large = RoutedKey(identity: 22, routeHash: 1)
    cache.insert(20, for: smallA, cost: 1)
    cache.insert(21, for: smallB, cost: 1)
    cache.insert(22, for: large, cost: 100)

    let shrink = cache.updateCostLimitReportingEvictions(101)
    #expect(shrink.evictedKeys.count == 1)
    #expect(Set(shrink.evictedKeys).isSubset(of: [smallA, smallB]))
    #expect(shrink.summary == MemoryCacheRemovalSummary(itemCount: 1, costBytes: 1))
    #expect(cache.value(for: large) == 22)

    let survivor = shrink.evictedKeys[0] == smallA ? smallB : smallA
    let replacement = cache.insertReportingEvictions(23, for: survivor, cost: 1)
    #expect(replacement.evictedKeys.isEmpty)
    #expect(replacement.summary == MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0))
    #expect(cache.value(for: survivor) == 23)

    let tooLarge = cache.insertReportingEvictions(24, for: survivor, cost: 102)
    #expect(tooLarge.evictedKeys == [survivor])
    #expect(tooLarge.summary.itemCount == 1)
    #expect(tooLarge.summary.costBytes == 1)
    #expect(cache.value(for: survivor) == nil)
  }

  @Test("AKASHIC-CT-035 shard budgets sum to exact global bound")
  func exactGlobalBound() async {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 257, shardCount: 8)
    await withTaskGroup(of: Void.self) { group in
      for worker in 0 ..< 16 {
        group.addTask {
          for step in 0 ..< 2000 {
            let key = worker * 10000 + step
            cache.insert(key, for: key, cost: 1)
            _ = cache.value(for: key)
          }
        }
      }
    }
    #expect(cache.currentCost <= 257)
    #expect(cache.count <= 257)
    #expect(cache.costLimit == 257)
  }

  @Test("AKASHIC-CT-036 dynamic limit preserves exact aggregate bound")
  func dynamicLimit() {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 128, shardCount: 8)
    for key in 0 ..< 1000 {
      cache.insert(key, for: key, cost: 1)
    }
    let before = cache.currentCost
    let summary = cache.updateCostLimit(31)
    #expect(cache.currentCost <= 31)
    #expect(summary.costBytes == before - cache.currentCost)
    #expect(cache.costLimit == 31)
    _ = cache.updateCostLimit(3)
    #expect(cache.currentCost <= 3)
  }

  @Test("AKASHIC-CT-037 scan-resistant hot set survives uniform scan")
  func scanResistance() {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 128, shardCount: 8)
    for key in 0 ..< 32 {
      cache.insert(key, for: key, cost: 1)
    }
    for key in 0 ..< 32 {
      #expect(cache.value(for: key) == key)
    }
    for key in 10000 ..< 14096 {
      cache.insert(key, for: key, cost: 1)
    }
    let retained = (0 ..< 32).filter { cache.value(for: $0) == $0 }.count
    #expect(retained >= 28)
    #expect(cache.currentCost <= 128)
  }

  @Test("AKASHIC-CT-039 single shard matches classic SIEVE observable semantics")
  func singleShardDifferential() {
    let sharded = ShardedMemoryCache<Int, String>(costLimit: 31, shardCount: 1)
    let classic = MemoryCache<Int, String>(costLimit: 31)
    var generator = ShardedGenerator(seed: 7)
    for step in 0 ..< 4000 {
      let key = generator.nextInt(upperBound: 41)
      switch generator.nextInt(upperBound: 100) {
      case 0 ..< 50:
        let cost = generator.nextInt(upperBound: 35) + 1
        let value = "v-\(step)"
        sharded.insert(value, for: key, cost: cost)
        classic.insert(value, for: key, cost: cost)
      case 50 ..< 80:
        #expect(sharded.value(for: key) == classic.value(for: key))
      case 80 ..< 95:
        sharded.remove(key)
        classic.remove(key)
      default:
        let limit = generator.nextInt(upperBound: 48) + 1
        #expect(sharded.updateCostLimit(limit) == classic.updateCostLimit(limit))
      }
      #expect(sharded.currentCost == classic.currentCost)
      #expect(sharded.count == classic.count)
    }
  }

  @Test("AKASHIC-CT-040 prehashed buckets preserve colliding keys across recycling")
  func collidingKeysAndRecycling() {
    let cache = ShardedMemoryCache<CollidingKey, Int>(costLimit: 4, shardCount: 1)
    for value in 0 ..< 4 {
      cache.insert(value, for: CollidingKey(value), cost: 1)
    }
    for value in 0 ..< 4 {
      #expect(cache.value(for: CollidingKey(value)) == value)
    }

    cache.remove(CollidingKey(1))
    cache.insert(4, for: CollidingKey(4), cost: 1)
    #expect(cache.value(for: CollidingKey(4)) == 4)
    cache.insert(5, for: CollidingKey(5), cost: 1)

    #expect(cache.value(for: CollidingKey(1)) == nil)
    #expect(cache.value(for: CollidingKey(4)) == 4)
    #expect(cache.value(for: CollidingKey(5)) == 5)
    #expect(cache.currentCost <= 4)
    #expect(cache.count <= 4)
  }

  @Test("AKASHIC-CT-043 global spare prevents shard-local premature eviction")
  func skewedShardUsesIdleGlobalBudgetBeforeEviction() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 64, shardCount: 8)
    let first = RoutedKey(identity: 101, routeHash: 0)
    let second = RoutedKey(identity: 102, routeHash: 0)
    let third = RoutedKey(identity: 103, routeHash: 0)

    cache.insert(1, for: first, cost: 6)
    cache.insert(2, for: second, cost: 6)
    cache.insert(3, for: third, cost: 6)

    #expect(cache.value(for: first) == 1)
    #expect(cache.value(for: second) == 2)
    #expect(cache.value(for: third) == 3)
    #expect(cache.currentCost == 18)
    #expect(cache.currentCost <= cache.costLimit)
  }

  @Test("AKASHIC-CT-044 released global spare is reusable across shards")
  func releasedGlobalSpareIsReusableAcrossShards() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 16, shardCount: 2)
    let left = (0 ..< 8).map { RoutedKey(identity: 200 + $0, routeHash: 0) }
    let right = (0 ..< 8).map { RoutedKey(identity: 300 + $0, routeHash: 1) }
    for (index, key) in left.enumerated() {
      cache.insert(index, for: key, cost: 1)
    }
    for (index, key) in right.enumerated() {
      cache.insert(100 + index, for: key, cost: 1)
    }
    #expect(cache.currentCost == 16)

    // 首个额外写确认“全局已满”，但只能在目标分片淘汰，不能误伤另一分片。
    let firstExtra = RoutedKey(identity: 400, routeHash: 0)
    cache.insert(400, for: firstExtra, cost: 1)
    #expect(cache.currentCost == 16)
    for (index, key) in right.enumerated() {
      #expect(cache.value(for: key) == 100 + index)
    }

    // 删除另一分片一个对象后，全局重新出现 1 unit spare。下一次目标分片已满的写
    // 必须借用这个 spare，而不是继续做 shard-local eviction。
    cache.remove(right[0])
    #expect(cache.currentCost == 15)
    let survivors = (left + Array(right.dropFirst()) + [firstExtra]).filter {
      cache.value(for: $0) != nil
    }
    #expect(survivors.count == 15)

    let secondExtra = RoutedKey(identity: 401, routeHash: 0)
    cache.insert(401, for: secondExtra, cost: 1)
    #expect(cache.currentCost == 16)
    #expect(cache.count == 16)
    for key in survivors {
      #expect(cache.value(for: key) != nil)
    }
    #expect(cache.value(for: secondExtra) == 401)
  }

  @Test("AKASHIC-CT-050 cross-shard slow path releases only the real deficit")
  func crossShardSlowPathDoesNotEvenlyRepartitionDonors() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 100, shardCount: 3)
    let heavy = (0 ..< 98).map { RoutedKey(identity: 500 + $0, routeHash: 1) }
    let light = RoutedKey(identity: 700, routeHash: 2)
    for (index, key) in heavy.enumerated() {
      cache.insert(index, for: key, cost: 1)
    }
    cache.insert(700, for: light, cost: 1)
    #expect(cache.currentCost == 99)

    // 目标 shard 需要一个 cost=2 的对象，当前只有 1 unit global spare，所以真正的
    // cross-shard deficit 只有 1。旧均分慢路径会把 heavy shard 从 98 压到 49；
    // 当前实现只能释放一个 1-unit victim，然后用满精确 100-unit 全局预算。
    let incoming = RoutedKey(identity: 800, routeHash: 0)
    cache.insert(800, for: incoming, cost: 2)

    #expect(cache.value(for: incoming) == 800)
    #expect(cache.value(for: light) == 700)
    #expect(cache.currentCost == 100)
    #expect(cache.count == 99)
    let heavySurvivors = heavy.filter { cache.value(for: $0) != nil }.count
    #expect(heavySurvivors == 97)
  }

  @Test("AKASHIC-CT-051 exact global shrink preserves an equal-cost skewed resident")
  func exactGlobalShrinkDoesNotEvictEqualCostResident() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 75, shardCount: 8)
    let hot = RoutedKey(identity: 900, routeHash: 5)
    cache.insert(900, for: hot, cost: 60)
    #expect(cache.currentCost == 60)
    #expect(cache.value(for: hot) == 900)

    let summary = cache.updateCostLimit(60)

    #expect(summary.itemCount == 0)
    #expect(summary.costBytes == 0)
    #expect(cache.currentCost == 60)
    #expect(cache.count == 1)
    #expect(cache.value(for: hot) == 900)
    #expect(cache.costLimit == 60)

    let expansion = cache.updateCostLimit(75)
    #expect(expansion.itemCount == 0)
    #expect(expansion.costBytes == 0)
    #expect(cache.currentCost == 60)
    #expect(cache.count == 1)
    #expect(cache.value(for: hot) == 900)
    #expect(cache.costLimit == 75)
  }

  @Test("AKASHIC-CT-052 global shrink avoids fixed-shard over-release")
  func globalShrinkUsesBestFitCurrentVictimAcrossShards() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 102, shardCount: 2)
    let smallA = RoutedKey(identity: 1_000, routeHash: 0)
    let smallB = RoutedKey(identity: 1_001, routeHash: 0)
    let large = RoutedKey(identity: 1_002, routeHash: 1)
    cache.insert(1_000, for: smallA, cost: 1)
    cache.insert(1_001, for: smallB, cost: 1)
    cache.insert(1_002, for: large, cost: 100)
    #expect(cache.currentCost == 102)
    #expect(cache.count == 3)

    // Only one unit must be released. A shard-index ordered resize would preserve shard 0's two
    // unit entries, force shard 1 from 100 to 99, and therefore evict the entire 100-cost resident.
    // Global best-fit among each shard's current legal SIEVE victim must choose one 1-cost entry.
    let summary = cache.updateCostLimit(101)

    #expect(summary.itemCount == 1)
    #expect(summary.costBytes == 1)
    #expect(cache.currentCost == 101)
    #expect(cache.count == 2)
    #expect(cache.costLimit == 101)
    #expect(cache.value(for: large) == 1_002)
    let smallSurvivors = [smallA, smallB].filter { cache.value(for: $0) != nil }.count
    #expect(smallSurvivors == 1)
  }

  @Test("AKASHIC-CT-053 insert donor selection avoids object-granularity over-release")
  func crossShardInsertUsesBestFitCurrentDonorVictim() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 102, shardCount: 3)
    let large = RoutedKey(identity: 1_100, routeHash: 1)
    let small = RoutedKey(identity: 1_101, routeHash: 2)
    let incoming = RoutedKey(identity: 1_102, routeHash: 0)
    cache.insert(1_100, for: large, cost: 100)
    cache.insert(1_101, for: small, cost: 1)
    #expect(cache.currentCost == 101)

    // Incoming cost=2 can use the one global spare unit, so the real cross-shard deficit is one.
    // Target-relative ring order sees shard 1 first, but its only legal victim costs 100; shard 2
    // has an exact 1-cost victim. Best-fit must preserve the large resident and release only one.
    cache.insert(1_102, for: incoming, cost: 2)

    #expect(cache.value(for: incoming) == 1_102)
    #expect(cache.value(for: large) == 1_100)
    #expect(cache.value(for: small) == nil)
    #expect(cache.currentCost == 102)
    #expect(cache.count == 2)
  }

  @Test("AKASHIC-CT-069 equal-cost donor tie uses an exact local successor when available")
  func equalCostTieUsesExactSuccessorWithoutOverRelease() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 16, shardCount: 2)
    let leftFirst = RoutedKey(identity: 1_200, routeHash: 0)
    let leftSecond = RoutedKey(identity: 1_201, routeHash: 0)
    let rightFirst = RoutedKey(identity: 1_202, routeHash: 1)
    let rightSecond = RoutedKey(identity: 1_203, routeHash: 1)

    // Both shards expose a 1-cost immediate victim. The legacy ring tie chose shard 0, then greedily
    // consumed its 6-cost successor and eventually had to delete the 8-cost shard-1 successor too:
    // release 16 for a 9-unit deficit. Shard 1's tied 1-cost victim instead exposes an exact 8-cost
    // successor, so the safe exact-successor tie break can release exactly 9 without changing the
    // immediate greedy cost class or either shard's local SIEVE order.
    cache.insert(1_200, for: leftFirst, cost: 1)
    cache.insert(1_201, for: leftSecond, cost: 6)
    cache.insert(1_202, for: rightFirst, cost: 1)
    cache.insert(1_203, for: rightSecond, cost: 8)
    #expect(cache.currentCost == 16)

    let summary = cache.updateCostLimit(7)

    #expect(summary.itemCount == 2)
    #expect(summary.costBytes == 9)
    #expect(cache.currentCost == 7)
    #expect(cache.value(for: leftFirst) == 1_200)
    #expect(cache.value(for: leftSecond) == 1_201)
    #expect(cache.value(for: rightFirst) == nil)
    #expect(cache.value(for: rightSecond) == nil)
  }

  @Test("AKASHIC-CT-070 cross-shard insert tie uses an exact local successor when available")
  func crossShardInsertTieUsesExactSuccessorWithoutOverRelease() {
    let cache = ShardedMemoryCache<RoutedKey, Int>(costLimit: 16, shardCount: 3)
    let leftFirst = RoutedKey(identity: 1_300, routeHash: 1)
    let leftSecond = RoutedKey(identity: 1_301, routeHash: 1)
    let rightFirst = RoutedKey(identity: 1_302, routeHash: 2)
    let rightSecond = RoutedKey(identity: 1_303, routeHash: 2)
    let incoming = RoutedKey(identity: 1_304, routeHash: 0)

    cache.insert(1_300, for: leftFirst, cost: 1)
    cache.insert(1_301, for: leftSecond, cost: 6)
    cache.insert(1_302, for: rightFirst, cost: 1)
    cache.insert(1_303, for: rightSecond, cost: 8)
    #expect(cache.currentCost == 16)

    // Target shard 0 has no resident budget and global spare is zero, so this 9-cost insert needs
    // exactly nine donor units. Both donor shards expose an immediate 1-cost victim. The shard-2 tie
    // exposes an exact 8-cost successor; choosing it must preserve shard 1 and avoid the legacy
    // 1+6+1+8 release cascade before admitting the incoming object.
    cache.insert(1_304, for: incoming, cost: 9)

    #expect(cache.currentCost == 16)
    #expect(cache.count == 3)
    #expect(cache.value(for: incoming) == 1_304)
    #expect(cache.value(for: leftFirst) == 1_300)
    #expect(cache.value(for: leftSecond) == 1_301)
    #expect(cache.value(for: rightFirst) == nil)
    #expect(cache.value(for: rightSecond) == nil)
  }

  @Test("AKASHIC-CT-038 entry larger than one shard borrows global budget")
  func oversizedShardEntryUsesGlobalBudget() {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 64, shardCount: 8)
    cache.insert(1, for: 1, cost: 9)
    #expect(cache.value(for: 1) == 1)
    #expect(cache.currentCost == 9)
    #expect(cache.currentCost <= cache.costLimit)

    cache.insert(2, for: 2, cost: 31)
    #expect(cache.value(for: 2) == 2)
    #expect(cache.currentCost <= 64)

    cache.insert(3, for: 2, cost: 65)
    #expect(cache.value(for: 2) == nil)
    #expect(cache.currentCost <= 64)

    let distributed = ShardedMemoryCache<RoutedKey, Int>(costLimit: 64, shardCount: 8)
    let first = RoutedKey(identity: 1, routeHash: 0)
    let second = RoutedKey(identity: 2, routeHash: 1)
    distributed.insert(1, for: first, cost: 16)
    distributed.insert(2, for: second, cost: 16)
    #expect(distributed.value(for: first) == 1)
    #expect(distributed.value(for: second) == 2)
    #expect(distributed.currentCost == 32)

    let maximum = ShardedMemoryCache<RoutedKey, Int>(
      costLimit: Int.max,
      shardCount: 8
    )
    let retained = RoutedKey(identity: 10, routeHash: 0)
    let maximumEntry = RoutedKey(identity: 11, routeHash: 0)
    maximum.insert(10, for: retained, cost: 2)
    maximum.insert(11, for: maximumEntry, cost: Int.max)
    #expect(maximum.value(for: retained) == nil)
    #expect(maximum.value(for: maximumEntry) == 11)
    #expect(maximum.currentCost == Int.max)
    maximum.insert(12, for: maximumEntry, cost: Int.max)
    #expect(maximum.value(for: maximumEntry) == 12)
    #expect(maximum.currentCost == Int.max)
  }

  @Test("AKASHIC-CT-042 concurrent rebalance, resize and shard traffic remain bounded")
  func concurrentRebalanceAndResize() async {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 257, shardCount: 8)
    await withTaskGroup(of: Void.self) { group in
      for worker in 0 ..< 12 {
        group.addTask {
          for step in 0 ..< 800 {
            let key = worker * 10000 + (step % 193)
            if step.isMultiple(of: 37) {
              cache.insert(key, for: key, cost: 48 + (step % 41))
            } else {
              cache.insert(key, for: key, cost: 1 + (step % 7))
            }
            if step.isMultiple(of: 11) {
              cache.remove(key)
            }
            if step.isMultiple(of: 5) {
              _ = cache.value(for: key)
            }
          }
        }
      }
      group.addTask {
        let limits = [257, 129, 511, 193, 320]
        for step in 0 ..< 160 {
          _ = cache.updateCostLimit(limits[step % limits.count])
        }
      }
      group.addTask {
        for step in 0 ..< 40 {
          if step.isMultiple(of: 7) {
            cache.removeAll(where: { $0 % 13 == 0 })
          }
        }
      }
    }
    #expect(cache.currentCost <= cache.costLimit)
    #expect(cache.count >= 0)
  }

  @Test("AKASHIC-CT-041 shrinking below a borrowed entry evicts to the global bound")
  func shrinkingBorrowedBudget() {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 64, shardCount: 8)
    cache.insert(1, for: 1, cost: 33)
    #expect(cache.value(for: 1) == 1)
    _ = cache.updateCostLimit(16)
    #expect(cache.value(for: 1) == nil)
    #expect(cache.currentCost <= 16)
    #expect(cache.costLimit == 16)
  }

  @Test("AKASHIC-CT-068 two-victim forecast matches actual shard-local SIEVE removals")
  func twoVictimForecastMatchesActualRemovals() {
    for seed in 1 ... 24 {
      let shard = ShardedMemoryShard<Int, Int>(costLimit: 64, bucketHashShift: 0)
      var generator = ShardedGenerator(seed: UInt64(seed))

      for step in 0 ..< 600 {
        let key = generator.nextInt(upperBound: 47)
        switch generator.nextInt(upperBound: 100) {
        case 0 ..< 55:
          let cost = generator.nextInt(upperBound: 12) + 1
          shard.acquire()
          shard.insertLocked(
            step,
            for: key,
            rawHash: key.hashValue,
            normalizedCost: cost
          )
          shard.release()
        case 55 ..< 85:
          _ = shard.value(for: key, rawHash: key.hashValue)
        default:
          shard.acquire()
          shard.removeLocked(key, rawHash: key.hashValue)
          shard.release()
        }

        if step.isMultiple(of: 7) {
          shard.acquire()
          let forecast = shard.nextTwoVictimCostsLocked()
          let immediate = shard.nextVictimCostLocked()
          let first = shard.removeNextVictimLocked()
          let second = shard.removeNextVictimLocked()
          shard.release()

          #expect(forecast?.first == immediate)
          #expect(forecast?.first == first)
          #expect(forecast?.second == second)
        }
      }
    }
  }

  @Test("AKASHIC-CT-054 all-visited epoch fast path preserves classic SIEVE semantics")
  func allVisitedEpochFastPathMatchesClassicSIEVE() {
    let sharded = ShardedMemoryCache<Int, Int>(costLimit: 32, shardCount: 1)
    let classic = MemoryCache<Int, Int>(costLimit: 32)
    var nextKey = 0

    for cycle in 0 ..< 64 {
      while sharded.count < 32 {
        sharded.insert(nextKey, for: nextKey, cost: 1)
        classic.insert(nextKey, for: nextKey, cost: 1)
        nextKey += 1
      }

      let liveRange = max(0, nextKey - 96) ..< nextKey
      for key in liveRange {
        let shardedValue = sharded.value(for: key)
        let classicValue = classic.value(for: key)
        #expect(shardedValue == classicValue)
      }

      let incoming = nextKey
      sharded.insert(cycle, for: incoming, cost: 1)
      classic.insert(cycle, for: incoming, cost: 1)
      nextKey += 1

      #expect(sharded.currentCost == classic.currentCost)
      #expect(sharded.count == classic.count)
      for key in max(0, nextKey - 96) ..< nextKey {
        #expect(sharded.value(for: key) == classic.value(for: key))
      }
    }
  }
}

private struct ShardedGenerator {
  private var state: UInt64
  init(seed: UInt64) {
    state = seed
  }

  mutating func nextInt(upperBound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int(state % UInt64(upperBound))
  }
}

private struct CollidingKey: Hashable, Sendable {
  let value: Int
  init(_ value: Int) {
    self.value = value
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(0)
  }
}

private struct RoutedKey: Hashable, Sendable {
  let identity: Int
  let routeHash: Int

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity
  }

  var hashValue: Int {
    routeHash
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(routeHash)
  }
}
