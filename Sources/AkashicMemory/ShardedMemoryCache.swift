import Foundation
import os

/// 将精确总成本预算分配给多个独立 SIEVE 分片的并发缓存。
///
/// 常规键读写、替换和淘汰只竞争所属分片。每个分片使用独立 `os_unfair_lock`
/// 和经典单比特 SIEVE，较短的链限制了清访问位时的最坏扫描长度。条目超过当前
/// 分片预算但仍不超过全局预算时，缓存进入低频慢路径：按固定顺序锁住全部分片、
/// 重新分配预算并完成插入。由此既保留并发热路径，也不把“单分片预算”泄漏成
/// 公共容量语义。
public final class ShardedMemoryCache<Key: Hashable & Sendable, Value: Sendable>:
  @unchecked Sendable
{
  private final class Shard: @unchecked Sendable {
    private final class Node {
      var key: Key
      var rawHash: Int
      var value: Value
      var cost: Int
      var visited = false
      unowned(unsafe) var previous: Node?
      unowned(unsafe) var next: Node?
      var collisionNext: Node?

      init(key: Key, rawHash: Int, value: Value, cost: Int, previous: Node?) {
        self.key = key
        self.rawHash = rawHash
        self.value = value
        self.cost = cost
        self.previous = previous
      }
    }

    private var lock = os_unfair_lock_s()
    private var costLimit: Int
    private var totalCost = 0
    private var bucketHeads: [Node?]
    private let bucketMask: UInt
    private let bucketHashShift: Int
    private var residentCount = 0
    private unowned(unsafe) var head: Node?
    private unowned(unsafe) var tail: Node?
    private unowned(unsafe) var hand: Node?

    init(costLimit: Int, bucketHashShift: Int) {
      self.costLimit = max(0, costLimit)
      let bucketCount = Self.bucketCount(for: costLimit)
      bucketHeads = Array(repeating: nil, count: bucketCount)
      bucketMask = UInt(bucketCount - 1)
      self.bucketHashShift = bucketHashShift
    }

    func value(for key: Key, rawHash: Int) -> Value? {
      atomic {
        guard let node = node(for: key, rawHash: rawHash) else { return nil }
        node.visited = true
        return node.value
      }
    }

    /// 返回 `false` 表示条目需要全局预算重分配；此时不改变当前状态。
    func insert(_ value: Value, for key: Key, rawHash: Int, cost: Int) -> Bool {
      atomic {
        let normalized = max(1, cost)
        guard normalized <= costLimit else { return false }
        insertLocked(value, for: key, rawHash: rawHash, normalizedCost: normalized)
        return true
      }
    }

    func remove(_ key: Key, rawHash: Int) {
      atomic { removeLocked(key, rawHash: rawHash) }
    }

    func acquire() {
      os_unfair_lock_lock(&lock)
    }

    func release() {
      os_unfair_lock_unlock(&lock)
    }

    var currentCostLocked: Int {
      totalCost
    }

    var countLocked: Int {
      residentCount
    }

    func costLocked(for key: Key, rawHash: Int) -> Int {
      node(for: key, rawHash: rawHash)?.cost ?? 0
    }

    func insertLocked(
      _ value: Value,
      for key: Key,
      rawHash: Int,
      normalizedCost: Int
    ) {
      precondition(normalizedCost > 0 && normalizedCost <= costLimit)
      let reusable = node(for: key, rawHash: rawHash)
      if let reusable {
        detach(reusable)
      }

      // 稳态扫描通常每次只淘汰一个节点。将首个 victim 原地改写为新条目，
      // 避免在锁内反复分配/释放 Node；额外 victim 仍按经典 SIEVE 删除。
      var recycled: Node?
      while totalCost > costLimit - normalizedCost, let victim = nextVictim() {
        detach(victim)
        removeFromBucket(victim)
        if recycled == nil {
          recycled = victim
        }
      }

      let node: Node
      if let reusable {
        reusable.value = value
        reusable.cost = normalizedCost
        reusable.visited = false
        reusable.previous = tail
        node = reusable
      } else if let recycled {
        recycled.key = key
        recycled.rawHash = rawHash
        recycled.value = value
        recycled.cost = normalizedCost
        recycled.visited = false
        recycled.previous = tail
        recycled.collisionNext = nil
        insertIntoBucket(recycled)
        node = recycled
      } else {
        node = Node(
          key: key,
          rawHash: rawHash,
          value: value,
          cost: normalizedCost,
          previous: tail
        )
        insertIntoBucket(node)
      }
      tail?.next = node
      if head == nil {
        head = node
      }
      tail = node
      totalCost += normalizedCost
    }

    func updateCostLimitLocked(_ limit: Int) -> MemoryCacheRemovalSummary {
      let oldCount = residentCount
      let oldCost = totalCost
      costLimit = max(0, limit)
      while totalCost > costLimit, let victim = nextVictim() {
        removeNode(victim)
      }
      return MemoryCacheRemovalSummary(
        itemCount: oldCount - residentCount,
        costBytes: oldCost - totalCost
      )
    }

    func removeLocked(_ key: Key, rawHash: Int) {
      guard let node = node(for: key, rawHash: rawHash) else { return }
      removeNode(node)
    }

    func removeAllLocked(where predicate: @Sendable (Key) -> Bool) {
      let victims = allNodes().filter { predicate($0.key) }
      for node in victims {
        removeNode(node)
      }
    }

    func removeAllAndReportLocked() -> MemoryCacheRemovalSummary {
      let summary = MemoryCacheRemovalSummary(
        itemCount: residentCount,
        costBytes: totalCost
      )
      for index in bucketHeads.indices {
        bucketHeads[index] = nil
      }
      residentCount = 0
      head = nil
      tail = nil
      hand = nil
      totalCost = 0
      return summary
    }

    private func nextVictim() -> Node? {
      guard let head else { return nil }
      if hand == nil {
        hand = head
      }
      while let candidate = hand {
        let next = candidate.next ?? head
        if candidate.visited {
          candidate.visited = false
          hand = next
        } else {
          hand = next === candidate ? nil : next
          return candidate
        }
      }
      return head
    }

    private func detach(_ node: Node) {
      if hand === node {
        hand = node.next ?? (head === node ? nil : head)
      }
      if head === node {
        head = node.next
      }
      if tail === node {
        tail = node.previous
      }
      node.previous?.next = node.next
      node.next?.previous = node.previous
      node.previous = nil
      node.next = nil
      totalCost -= node.cost
      if head == nil {
        tail = nil
        hand = nil
      }
    }

    private func removeNode(_ node: Node) {
      detach(node)
      removeFromBucket(node)
    }

    private func node(for key: Key, rawHash: Int) -> Node? {
      var candidate = bucketHeads[bucketIndex(rawHash)]
      while let current = candidate {
        if current.rawHash == rawHash, current.key == key {
          return current
        }
        candidate = current.collisionNext
      }
      return nil
    }

    private func insertIntoBucket(_ node: Node) {
      let index = bucketIndex(node.rawHash)
      node.collisionNext = bucketHeads[index]
      bucketHeads[index] = node
      residentCount += 1
    }

    private func removeFromBucket(_ node: Node) {
      let index = bucketIndex(node.rawHash)
      guard let head = bucketHeads[index] else { return }
      if head === node {
        bucketHeads[index] = node.collisionNext
        node.collisionNext = nil
        residentCount -= 1
        return
      }
      var previous = head
      while let current = previous.collisionNext {
        if current === node {
          previous.collisionNext = current.collisionNext
          current.collisionNext = nil
          residentCount -= 1
          return
        }
        previous = current
      }
    }

    private func allNodes() -> [Node] {
      var result: [Node] = []
      result.reserveCapacity(residentCount)
      for head in bucketHeads {
        var candidate = head
        while let current = candidate {
          result.append(current)
          candidate = current.collisionNext
        }
      }
      return result
    }

    @inline(__always)
    private func bucketIndex(_ rawHash: Int) -> Int {
      let bits = UInt(bitPattern: rawHash)
      let bucketBits = bucketHashShift == 0 ? bits : bits >> bucketHashShift
      return Int(bucketBits & bucketMask)
    }

    private static func bucketCount(for costLimit: Int) -> Int {
      let scaled = costLimit > 1024 ? 4096 : max(1, costLimit) * 8
      let target = max(16, min(4096, scaled))
      var value = 1
      while value < target {
        value <<= 1
      }
      return value
    }

    @inline(__always)
    private func atomic<T>(_ operation: () throws -> T) rethrows -> T {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      return try operation()
    }
  }

  private let configurationLock = NSLock()
  private let shards: [Shard]
  private let shardMask: UInt?
  private var totalCostLimit: Int

  /// 创建固定数量分片的缓存。分片数被限制为 1...64。
  public init(costLimit: Int, shardCount: Int = 8) {
    let normalizedLimit = max(1, costLimit)
    let normalizedShardCount = max(1, min(64, shardCount))
    totalCostLimit = normalizedLimit
    shardMask =
      normalizedShardCount.nonzeroBitCount == 1
        ? UInt(normalizedShardCount - 1)
        : nil
    let bucketHashShift =
      normalizedShardCount.nonzeroBitCount == 1
        ? normalizedShardCount.trailingZeroBitCount
        : 0
    shards = ShardedMemoryBudget.partition(normalizedLimit, count: normalizedShardCount)
      .map { Shard(costLimit: $0, bucketHashShift: bucketHashShift) }
  }

  public func value(for key: Key) -> Value? {
    let rawHash = key.hashValue
    return shards[shardIndex(rawHash: rawHash)].value(for: key, rawHash: rawHash)
  }

  public func insert(_ value: Value, for key: Key, cost: Int) {
    let normalized = max(1, cost)
    let rawHash = key.hashValue
    let index = shardIndex(rawHash: rawHash)
    if shards[index].insert(value, for: key, rawHash: rawHash, cost: normalized) {
      return
    }
    insertWithRedistributedBudget(
      value,
      for: key,
      rawHash: rawHash,
      shardIndex: index,
      normalizedCost: normalized
    )
  }

  /// 原子更新全局成本上限并恢复均匀分片预算。
  public func updateCostLimit(_ newLimit: Int) -> MemoryCacheRemovalSummary {
    withAllShardsLocked {
      let normalized = max(1, newLimit)
      totalCostLimit = normalized
      let limits = ShardedMemoryBudget.partition(normalized, count: shards.count)
      var items = 0
      var cost = 0
      for (shard, limit) in zip(shards, limits) {
        let summary = shard.updateCostLimitLocked(limit)
        items += summary.itemCount
        cost += summary.costBytes
      }
      return MemoryCacheRemovalSummary(itemCount: items, costBytes: cost)
    }
  }

  public func remove(_ key: Key) {
    let rawHash = key.hashValue
    shards[shardIndex(rawHash: rawHash)].remove(key, rawHash: rawHash)
  }

  public func removeAll(where predicate: @Sendable (Key) -> Bool) {
    withAllShardsLocked {
      for shard in shards {
        shard.removeAllLocked(where: predicate)
      }
    }
  }

  public func removeAll() {
    _ = removeAllAndReport()
  }

  public func removeAllAndReport() -> MemoryCacheRemovalSummary {
    withAllShardsLocked {
      var items = 0
      var cost = 0
      let evenLimits = ShardedMemoryBudget.partition(totalCostLimit, count: shards.count)
      for (shard, limit) in zip(shards, evenLimits) {
        let summary = shard.removeAllAndReportLocked()
        _ = shard.updateCostLimitLocked(limit)
        items += summary.itemCount
        cost += summary.costBytes
      }
      return MemoryCacheRemovalSummary(itemCount: items, costBytes: cost)
    }
  }

  public var currentCost: Int {
    withAllShardsLocked { shards.reduce(0) { $0 + $1.currentCostLocked } }
  }

  public var count: Int {
    withAllShardsLocked { shards.reduce(0) { $0 + $1.countLocked } }
  }

  public var costLimit: Int {
    configurationLock.lock()
    defer { configurationLock.unlock() }
    return totalCostLimit
  }

  private func insertWithRedistributedBudget(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    shardIndex targetIndex: Int,
    normalizedCost: Int
  ) {
    withAllShardsLocked {
      guard normalizedCost <= totalCostLimit else {
        // 与单分片 MemoryCache 相同：过大全量替换会移除旧键并留下 miss。
        shards[targetIndex].removeLocked(key, rawHash: rawHash)
        return
      }

      let currentCosts = shards.map(\.currentCostLocked)
      let replacedCost = shards[targetIndex].costLocked(for: key, rawHash: rawHash)
      let limits = ShardedMemoryBudget.redistributedLimits(
        currentCosts: currentCosts,
        replacedCost: replacedCost,
        targetIndex: targetIndex,
        incomingCost: normalizedCost,
        totalLimit: totalCostLimit
      )
      for (shard, limit) in zip(shards, limits) {
        _ = shard.updateCostLimitLocked(limit)
      }
      shards[targetIndex].insertLocked(
        value,
        for: key,
        rawHash: rawHash,
        normalizedCost: normalizedCost
      )
    }
  }

  @inline(__always)
  private func shardIndex(rawHash: Int) -> Int {
    let bits = UInt(bitPattern: rawHash)
    if let shardMask {
      return Int(bits & shardMask)
    }
    return Int(bits % UInt(shards.count))
  }

  private func withAllShardsLocked<T>(_ operation: () throws -> T) rethrows -> T {
    configurationLock.lock()
    for shard in shards {
      shard.acquire()
    }
    defer {
      for shard in shards.reversed() {
        shard.release()
      }
      configurationLock.unlock()
    }
    return try operation()
  }
}
