import AkashicMemory
import Testing

@Suite("AkashicMemory sharded SIEVE cache")
struct ShardedMemoryCacheTests {
  @Test("AKASHIC-CT-037 shard budgets sum to exact global bound")
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

  @Test("AKASHIC-CT-038 dynamic limit preserves exact aggregate bound")
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

  @Test("AKASHIC-CT-039 scan-resistant hot set survives uniform scan")
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

  @Test("AKASHIC-CT-041 single shard matches classic SIEVE observable semantics")
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

  @Test("AKASHIC-CT-042 prehashed buckets preserve colliding keys across recycling")
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

  @Test("AKASHIC-CT-040 entry larger than one shard borrows global budget")
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

  @Test("AKASHIC-CT-044 concurrent rebalance, resize and shard traffic remain bounded")
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

  @Test("AKASHIC-CT-043 shrinking below a borrowed entry evicts to the global bound")
  func shrinkingBorrowedBudget() {
    let cache = ShardedMemoryCache<Int, Int>(costLimit: 64, shardCount: 8)
    cache.insert(1, for: 1, cost: 33)
    #expect(cache.value(for: 1) == 1)
    _ = cache.updateCostLimit(16)
    #expect(cache.value(for: 1) == nil)
    #expect(cache.currentCost <= 16)
    #expect(cache.costLimit == 16)
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
