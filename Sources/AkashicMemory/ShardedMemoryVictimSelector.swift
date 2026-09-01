/// 无状态的跨分片 SIEVE victim 选择器。
///
/// `ShardedMemoryCache` 负责锁序、预算与实际删除；此处只在调用方已经持有全部 shard
/// 锁时，从每个 shard 当前合法 immediate victim 中选择最小过度释放方案。只有同成本
/// immediate victim 形成真实 tie 时，才读取第二 victim 以识别可精确满足剩余 deficit
/// 的安全 successor；这不是一般多步 look-ahead。
enum ShardedMemoryVictimSelector {
  @inline(__always)
  static func bestFitShardIndexLocked<Key: Hashable & Sendable, Value: Sendable>(
    shards: [ShardedMemoryShard<Key, Value>],
    remainingDeficit: Int,
    excluding excludedIndex: Int?,
    startIndex: Int,
    nextVictimCosts: [Int?],
    successorVictimCosts: inout [Int]?
  ) -> Int? {
    precondition(remainingDeficit > 0)
    precondition(shards.indices.contains(startIndex))
    precondition(nextVictimCosts.count == shards.count)
    precondition(successorVictimCosts == nil || successorVictimCosts?.count == shards.count)
    var bestUnderIndex: Int?
    var bestUnderCost = 0
    var bestUnderTieCount = 0
    var bestOverIndex: Int?
    var bestOverCost = Int.max

    for offset in 0 ..< shards.count {
      let index = (startIndex + offset) % shards.count
      if index == excludedIndex { continue }
      guard let victimCost = nextVictimCosts[index] else { continue }
      if victimCost == remainingDeficit {
        return index
      }
      if victimCost < remainingDeficit {
        if victimCost > bestUnderCost {
          bestUnderCost = victimCost
          bestUnderIndex = index
          bestUnderTieCount = 1
        } else if victimCost == bestUnderCost {
          bestUnderTieCount += 1
        }
      } else if victimCost < bestOverCost {
        bestOverCost = victimCost
        bestOverIndex = index
      }
    }

    guard let greedyUnderIndex = bestUnderIndex else { return bestOverIndex }
    guard bestUnderTieCount > 1 else { return greedyUnderIndex }
    return exactSuccessorTieIndexLocked(
      shards: shards,
      remainingDeficit: remainingDeficit,
      bestUnderCost: bestUnderCost,
      excluding: excludedIndex,
      startIndex: startIndex,
      nextVictimCosts: nextVictimCosts,
      successorVictimCosts: &successorVictimCosts
    ) ?? greedyUnderIndex
  }

  @inline(never)
  private static func exactSuccessorTieIndexLocked<
    Key: Hashable & Sendable,
    Value: Sendable
  >(
    shards: [ShardedMemoryShard<Key, Value>],
    remainingDeficit: Int,
    bestUnderCost: Int,
    excluding excludedIndex: Int?,
    startIndex: Int,
    nextVictimCosts: [Int?],
    successorVictimCosts: inout [Int]?
  ) -> Int? {
    let exactSuccessorCost = remainingDeficit - bestUnderCost
    precondition(exactSuccessorCost > 0)
    if successorVictimCosts == nil {
      successorVictimCosts = [Int](repeating: -1, count: shards.count)
    }
    for offset in 0 ..< shards.count {
      let index = (startIndex + offset) % shards.count
      if index == excludedIndex || nextVictimCosts[index] != bestUnderCost { continue }
      var successorCost = successorVictimCosts![index]
      if successorCost < 0 {
        let forecast = shards[index].nextTwoVictimCostsLocked()
        precondition(forecast?.first == nextVictimCosts[index])
        successorCost = forecast?.second ?? 0
        successorVictimCosts![index] = successorCost
      }
      if successorCost == exactSuccessorCost {
        return index
      }
    }
    return nil
  }
}
