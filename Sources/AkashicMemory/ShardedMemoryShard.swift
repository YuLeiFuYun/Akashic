import Foundation
import os

/// `ShardedMemoryCache` 的单分片 SIEVE 内核。
///
/// 该类型只管理一个分片的哈希桶、SIEVE/FIFO 链和已分配成本；跨分片总预算由
/// `ShardedMemoryCache` 协调。所有 `*Locked` 成员都要求调用方已经持有本分片锁。
final class ShardedMemoryShard<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
  private final class Node {
    var key: Key
    var rawHash: Int
    var value: Value
    var cost: Int
    var visitedEpoch: UInt64 = 0
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
  private var visitedCount = 0
  private var visitEpoch: UInt64 = 1
  private unowned(unsafe) var head: Node?
  private unowned(unsafe) var tail: Node?
  private unowned(unsafe) var hand: Node?

  init(costLimit: Int, bucketHashShift: Int, bucketSizingCostLimit: Int? = nil) {
    self.costLimit = max(0, costLimit)
    let bucketCount = Self.bucketCount(for: bucketSizingCostLimit ?? costLimit)
    bucketHeads = Array(repeating: nil, count: bucketCount)
    bucketMask = UInt(bucketCount - 1)
    self.bucketHashShift = bucketHashShift
  }

  func value(for key: Key, rawHash: Int) -> Value? {
    atomic {
      guard let node = node(for: key, rawHash: rawHash) else { return nil }
      if node.visitedEpoch != visitEpoch {
        node.visitedEpoch = visitEpoch
        visitedCount += 1
      }
      return node.value
    }
  }

  func acquire() {
    os_unfair_lock_lock(&lock)
  }

  func release() {
    os_unfair_lock_unlock(&lock)
  }

  var currentCostLocked: Int { totalCost }
  var costLimitLocked: Int { costLimit }
  var countLocked: Int { residentCount }

  /// 仅扩展/保持预算；不得把 limit 压到当前 resident cost 以下。
  func setCostLimitPreservingResidentsLocked(_ limit: Int) {
    precondition(limit >= totalCost)
    costLimit = limit
  }

  /// 将分片预算收敛到真实 resident cost，并返回可归还全局池的空闲单位。
  @discardableResult
  func normalizeCostLimitToResidentsLocked() -> Int {
    precondition(costLimit >= totalCost)
    let released = costLimit - totalCost
    costLimit = totalCost
    return released
  }

  func costLocked(for key: Key, rawHash: Int) -> Int {
    node(for: key, rawHash: rawHash)?.cost ?? 0
  }

  /// Package research snapshots call this only while holding the shard lock. Like the single-
  /// shard observer, an unset hand means the next SIEVE search begins at FIFO head.
  func handTopologyStateLocked() -> MemoryCacheHandTopologyState {
    guard let head else {
      return MemoryCacheHandTopologyState(
        residentCount: 0,
        residentCost: 0,
        prefixBeforeHandCount: 0,
        prefixBeforeHandCost: 0,
        suffixFromHandCount: 0,
        suffixFromHandCost: 0
      )
    }
    let effectiveHand = hand ?? head
    var prefixCount = 0
    var prefixCost = 0
    var suffixCount = 0
    var suffixCost = 0
    var beforeHand = true
    var cursor: Node? = head
    while let node = cursor {
      if node === effectiveHand { beforeHand = false }
      if beforeHand {
        prefixCount += 1
        prefixCost += node.cost
      } else {
        suffixCount += 1
        suffixCost += node.cost
      }
      cursor = node.next
    }
    precondition(prefixCount + suffixCount == residentCount)
    precondition(prefixCost + suffixCost == totalCost)
    return MemoryCacheHandTopologyState(
      residentCount: residentCount,
      residentCost: totalCost,
      prefixBeforeHandCount: prefixCount,
      prefixBeforeHandCost: prefixCost,
      suffixFromHandCount: suffixCount,
      suffixFromHandCost: suffixCost
    )
  }

  /// Returns the cost of the next victim under the current shard-local SIEVE state without
  /// mutating reference epochs or the hand. When every resident was referenced in the current
  /// epoch, classic SIEVE would clear one full ring and select the starting hand; the epoch/count
  /// representation proves that case in O(1) instead of scanning the entire shard.
  func nextVictimCostLocked() -> Int? {
    guard let head else { return nil }
    let start = hand ?? head
    if visitedCount == residentCount { return start.cost }
    var candidate = start
    while true {
      if candidate.visitedEpoch != visitEpoch { return candidate.cost }
      candidate = candidate.next ?? head
      if candidate === start { return start.cost }
    }
  }

  /// Forecasts the current legal SIEVE victim and the legal successor after removing it, without
  /// mutating the hand or visited state. The successor is used only for a globally exact-fit tie
  /// break; it is not a general multi-victim planner.
  func nextTwoVictimCostsLocked() -> (first: Int, second: Int?)? {
    guard residentCount > 0, let head else { return nil }
    let start = hand ?? head
    if residentCount == 1 { return (start.cost, nil) }

    // Classic SIEVE advances the visit epoch before choosing when every resident is visited. After
    // that O(1) epoch transition all nodes are logically unvisited, so the next two victims are just
    // the current hand and its next resident.
    if visitedCount == residentCount {
      return (start.cost, start.next?.cost ?? head.cost)
    }

    // Simulate only the first victim scan. Visited nodes crossed by that scan would be cleared by
    // `nextVictim`; remember them locally so the successor scan sees the same virtual state.
    var clearedVisitedCount = 0
    var first = start
    while first.visitedEpoch == visitEpoch {
      clearedVisitedCount += 1
      first = first.next ?? head
    }

    let virtualHead = first === head ? first.next : head
    let virtualResidentCount = residentCount - 1
    guard virtualResidentCount > 0, let virtualHead else {
      return (first.cost, nil)
    }

    func nextAlive(after node: Node) -> Node? {
      var candidate = node.next ?? virtualHead
      if candidate === first {
        candidate = first.next ?? virtualHead
      }
      return candidate === first ? nil : candidate
    }

    var virtualHand: Node? = first.next ?? virtualHead
    if virtualHand === first {
      virtualHand = nextAlive(after: first)
    }
    guard let successorStart = virtualHand else { return (first.cost, nil) }

    let remainingVisitedCount = visitedCount - clearedVisitedCount
    if remainingVisitedCount == virtualResidentCount {
      // The next real call would advance the epoch and therefore choose its hand immediately.
      return (first.cost, successorStart.cost)
    }

    var candidate = successorStart
    while true {
      // The first scan clears one contiguous visited prefix in SIEVE traversal order. If the
      // successor scan wraps back into that prefix, `start` is necessarily the first cleared node
      // it encounters and is therefore immediately eligible without materializing a visited set.
      if clearedVisitedCount > 0, candidate === start {
        return (first.cost, candidate.cost)
      }
      if candidate.visitedEpoch != visitEpoch {
        return (first.cost, candidate.cost)
      }
      guard let next = nextAlive(after: candidate) else {
        return (first.cost, nil)
      }
      candidate = next
      if candidate === successorStart {
        // With at least one logically unvisited survivor this should be unreachable, but returning
        // the start matches SIEVE's fail-safe ring behavior without mutating state.
        return (first.cost, successorStart.cost)
      }
    }
  }

  /// Removes exactly one shard-local SIEVE victim and returns its normalized cost.
  @discardableResult
  func removeNextVictimLocked() -> Int? {
    removeNextVictimRecordLocked()?.cost
  }

  /// Reporting variant used only by callers that must mirror exact residency identities.
  func removeNextVictimRecordLocked() -> MemoryCacheEvictionVictim<Key>? {
    guard let victim = nextVictim() else { return nil }
    let record = MemoryCacheEvictionVictim(key: victim.key, cost: victim.cost)
    removeNode(victim)
    return record
  }

  func insertLocked(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    normalizedCost: Int
  ) {
    var ignoredVictims: [MemoryCacheEvictionVictim<Key>]? = nil
    insertLocked(
      value,
      for: key,
      rawHash: rawHash,
      normalizedCost: normalizedCost,
      evictedVictims: &ignoredVictims
    )
  }

  func insertLocked(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    normalizedCost: Int,
    evictedVictims: inout [MemoryCacheEvictionVictim<Key>]?
  ) {
    precondition(normalizedCost > 0 && normalizedCost <= costLimit)
    let reusable = node(for: key, rawHash: rawHash)
    if let reusable {
      detach(reusable)
    }

    // 稳态扫描通常每次只淘汰一个节点。将首个 victim 原地改写为新条目，避免在锁内
    // 反复分配/释放 Node；额外 victim 仍按经典 SIEVE 删除。
    var recycled: Node?
    while totalCost > costLimit - normalizedCost, let victim = nextVictim() {
      evictedVictims?.append(MemoryCacheEvictionVictim(key: victim.key, cost: victim.cost))
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
      reusable.visitedEpoch = 0
      reusable.previous = tail
      node = reusable
    } else if let recycled {
      recycled.key = key
      recycled.rawHash = rawHash
      recycled.value = value
      recycled.cost = normalizedCost
      recycled.visitedEpoch = 0
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
    visitedCount = 0
    visitEpoch = 1
    head = nil
    tail = nil
    hand = nil
    totalCost = 0
    return summary
  }

  private func nextVictim() -> Node? {
    guard residentCount > 0, let head else { return nil }
    if hand == nil {
      hand = head
    }
    if visitedCount == residentCount {
      advanceVisitEpochLocked()
    }
    while let candidate = hand {
      let next = candidate.next ?? head
      if candidate.visitedEpoch == visitEpoch {
        candidate.visitedEpoch = 0
        visitedCount -= 1
        hand = next
      } else {
        hand = next === candidate ? nil : next
        return candidate
      }
    }
    return head
  }

  private func advanceVisitEpochLocked() {
    if visitEpoch == .max {
      var node = head
      while let current = node {
        current.visitedEpoch = 0
        node = current.next
      }
      visitEpoch = 1
    } else {
      visitEpoch += 1
    }
    visitedCount = 0
  }

  private func detach(_ node: Node) {
    if node.visitedEpoch == visitEpoch {
      visitedCount -= 1
    }
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
