import CAkashicAtomics
import Foundation

package struct ShardedMemoryBudgetSnapshot: Sendable {
  package let totalCostLimit: Int
  package let currentCost: Int
  package let globalUnassignedCost: Int
  package let shardCurrentCosts: [Int]
  package let shardAssignedLimits: [Int]
  package let shardResidentCounts: [Int]
}

/// 共享精确总成本预算的多分片 SIEVE 并发缓存。
///
/// 常规键读写、替换和淘汰只竞争所属分片。每个分片使用独立 `os_unfair_lock`
/// 和经典单比特 SIEVE；未被 resident 对象占用的成本单位保存在一个 lock-free
/// 全局池中，任意分片均可领取。因此哈希偏斜不会把实现分片泄漏成有效容量语义。
/// 稳态满缓存仍只执行一次原子池读取/领取和一次目标分片锁；只有单个对象无法由
/// 目标分片 resident 预算加全局空闲预算容纳时，才进入按固定顺序锁住全部分片的
/// 低频跨分片重分配路径。
public final class ShardedMemoryCache<Key: Hashable & Sendable, Value: Sendable>:
  @unchecked Sendable
{
  private let configurationLock = NSLock()
  private var globalUnassignedCost: AkashicAtomicInt64
  private let shards: [ShardedMemoryShard<Key, Value>]
  private let shardMask: UInt?
  private var totalCostLimit: Int

  /// 创建固定数量分片的缓存。分片数被限制为 1...64。
  public init(costLimit: Int, shardCount: Int = 8) {
    let normalizedLimit = max(1, costLimit)
    let normalizedShardCount = max(1, min(64, shardCount))
    // Bucket count is only a hash-table sizing hint. Do not model it as resident capacity: the
    // effective cache budget is the single global unassigned pool plus resident cost.
    let sizingBase = normalizedLimit / normalizedShardCount
    let sizingRemainder = normalizedLimit % normalizedShardCount
    totalCostLimit = normalizedLimit
    globalUnassignedCost = AkashicAtomicInt64(value: Int64(normalizedLimit))
    shardMask =
      normalizedShardCount.nonzeroBitCount == 1
        ? UInt(normalizedShardCount - 1)
        : nil
    let bucketHashShift =
      normalizedShardCount.nonzeroBitCount == 1
        ? normalizedShardCount.trailingZeroBitCount
        : 0
    shards = (0 ..< normalizedShardCount).map { index in
      let bucketSizingCostLimit = sizingBase + (index < sizingRemainder ? 1 : 0)
      return ShardedMemoryShard(
        costLimit: 0,
        bucketHashShift: bucketHashShift,
        bucketSizingCostLimit: bucketSizingCostLimit
      )
    }
  }

  public func value(for key: Key) -> Value? {
    let rawHash = key.hashValue
    return shards[shardIndex(rawHash: rawHash)].value(for: key, rawHash: rawHash)
  }

  public func insert(_ value: Value, for key: Key, cost: Int) {
    var ignoredVictims: [MemoryCacheEvictionVictim<Key>]? = nil
    insert(
      value,
      for: key,
      cost: cost,
      evictedVictims: &ignoredVictims
    )
  }

  /// 插入值并返回本次因成本准入真实离开缓存的身份。
  ///
  /// 普通 replacement 不会把同一 key 计为 eviction；超过全局成本上限的新值若替换
  /// 既有 key，则该旧 resident 会出现在回执中。该方法只为需要同步外部轻量索引的
  /// 宿主承担 victim 数组成本，常规 `insert` 保持无回执分配路径。
  @discardableResult
  public func insertReportingEvictions(
    _ value: Value,
    for key: Key,
    cost: Int
  ) -> MemoryCacheEvictionReport<Key> {
    var victims: [MemoryCacheEvictionVictim<Key>]? = []
    insert(value, for: key, cost: cost, evictedVictims: &victims)
    return evictionReport(from: victims ?? [])
  }

  private func insert(
    _ value: Value,
    for key: Key,
    cost: Int,
    evictedVictims: inout [MemoryCacheEvictionVictim<Key>]?
  ) {
    let normalized = max(1, cost)
    let rawHash = key.hashValue
    let index = shardIndex(rawHash: rawHash)
    let shard = shards[index]

    shard.acquire()
    let assignedLimit = shard.costLimitLocked
    // 不为“是否 replacement”预查 bucket。新 key 是扫描/滚动热路径；先最多领取
    // incomingCost，replacement 多领的部分会在 insert 后由 canonicalization 立即归还。
    // 这样常规 miss-insert 只做 `insertLocked` 内的一次 key lookup。
    let claimed = takeGlobalBudgetUpTo(normalized)
    if claimed > 0 {
      let expanded = assignedLimit.addingReportingOverflow(claimed)
      precondition(!expanded.overflow)
      shard.setCostLimitPreservingResidentsLocked(expanded.partialValue)
    }

    if normalized <= shard.costLimitLocked {
      shard.insertLocked(
        value,
        for: key,
        rawHash: rawHash,
        normalizedCost: normalized,
        evictedVictims: &evictedVictims
      )
      let released = shard.normalizeCostLimitToResidentsLocked()
      returnGlobalBudget(released)
      shard.release()
      return
    }

    // 即使领取了当前全部全局 spare，单个对象仍大于目标分片可用预算；归还临时
    // 领取后再进入真正的跨分片慢路径。慢路径会在锁住全部分片后重新计算 ground truth。
    let released = shard.normalizeCostLimitToResidentsLocked()
    returnGlobalBudget(released)
    shard.release()
    insertWithRedistributedBudget(
      value,
      for: key,
      rawHash: rawHash,
      shardIndex: index,
      normalizedCost: normalized,
      evictedVictims: &evictedVictims
    )
  }

  /// 原子更新全局成本上限。扩容不驱逐任何 resident；缩容在每轮各 shard 当前合法
  /// SIEVE victim 之间做 best-fit：优先选择不超过剩余 deficit 的最大 victim，否则选择
  /// 最小 overshoot。这样 shard index 不再决定一个 1-unit shrink 是否误删一个 100-unit
  /// 对象，同时每个 shard 内仍严格服从自己的 SIEVE 顺序。结束后重新建立
  /// “各 shard limit = resident cost + 全局未分配池”的不变量。
  public func updateCostLimit(_ newLimit: Int) -> MemoryCacheRemovalSummary {
    var ignoredVictims: [MemoryCacheEvictionVictim<Key>]? = nil
    return updateCostLimit(newLimit, evictedVictims: &ignoredVictims)
  }

  /// 更新全局成本上限并返回 shrink 实际删除的身份与释放摘要。
  /// 扩容或等值更新返回空 `evictedKeys` 与零摘要。
  public func updateCostLimitReportingEvictions(
    _ newLimit: Int
  ) -> MemoryCacheEvictionReport<Key> {
    var victims: [MemoryCacheEvictionVictim<Key>]? = []
    let summary = updateCostLimit(newLimit, evictedVictims: &victims)
    let records = victims ?? []
    let report = evictionReport(from: records)
    precondition(report.summary == summary)
    return report
  }

  private func updateCostLimit(
    _ newLimit: Int,
    evictedVictims: inout [MemoryCacheEvictionVictim<Key>]?
  ) -> MemoryCacheRemovalSummary {
    withAllShardsLocked {
      let normalized = max(1, newLimit)
      totalCostLimit = normalized
      var remainingDeficit = max(0, currentCostLocked() - normalized)
      var items = 0
      var cost = 0

      if remainingDeficit > 0 {
        // 保留 immediate-victim cache 作为常态成本。只有 selector 真实遇到 equal-cost tie
        // 且第一 victim 不足以满足 deficit 时，才直接读取 tied shard 的 successor。
        var nextVictimCosts = shards.map { $0.nextVictimCostLocked() }
        // Allocate successor state only if an equal-cost tie actually reaches the cold selector.
        // Once allocated: -1 = not forecast, 0 = no successor, >0 = normalized successor cost.
        // Stable shards do not mutate while all shard locks are held, so their cached forecast stays
        // valid until that shard is selected for removal.
        var successorVictimCosts: [Int]?
        while remainingDeficit > 0 {
          guard
            let index = ShardedMemoryVictimSelector.bestFitShardIndexLocked(
              shards: shards,
              remainingDeficit: remainingDeficit,
              excluding: nil,
              startIndex: 0,
              nextVictimCosts: nextVictimCosts,
              successorVictimCosts: &successorVictimCosts
            ),
            let victim = shards[index].removeNextVictimRecordLocked()
          else {
            preconditionFailure("global cache resize deficit must be satisfiable")
          }
          evictedVictims?.append(victim)
          let released = victim.cost
          items += 1
          cost += released
          remainingDeficit = max(0, remainingDeficit - released)
          nextVictimCosts[index] = shards[index].nextVictimCostLocked()
          successorVictimCosts?[index] = -1
        }
      }

      canonicalizeBudgetLocked()
      return MemoryCacheRemovalSummary(itemCount: items, costBytes: cost)
    }
  }

  public func remove(_ key: Key) {
    let rawHash = key.hashValue
    let shard = shards[shardIndex(rawHash: rawHash)]
    shard.acquire()
    shard.removeLocked(key, rawHash: rawHash)
    let released = shard.normalizeCostLimitToResidentsLocked()
    returnGlobalBudget(released)
    shard.release()
  }

  public func removeAll(where predicate: @Sendable (Key) -> Bool) {
    withAllShardsLocked {
      for shard in shards {
        shard.removeAllLocked(where: predicate)
      }
      canonicalizeBudgetLocked()
    }
  }

  public func removeAll() {
    _ = removeAllAndReport()
  }

  public func removeAllAndReport() -> MemoryCacheRemovalSummary {
    withAllShardsLocked {
      var items = 0
      var cost = 0
      for shard in shards {
        let summary = shard.removeAllAndReportLocked()
        items += summary.itemCount
        cost += summary.costBytes
      }
      canonicalizeBudgetLocked()
      return MemoryCacheRemovalSummary(itemCount: items, costBytes: cost)
    }
  }

  public var currentCost: Int {
    withAllShardsLocked { currentCostLocked() }
  }

  public var count: Int {
    withAllShardsLocked { shards.reduce(0) { $0 + $1.countLocked } }
  }

  public var costLimit: Int {
    configurationLock.lock()
    defer { configurationLock.unlock() }
    return totalCostLimit
  }

  /// Package-only stable resource snapshot for deterministic research probes.
  ///
  /// This deliberately takes the existing all-shard ordering path only when explicitly invoked;
  /// no counters or instrumentation are added to ordinary cache operations. The snapshot exposes
  /// physical budget ownership only and is not cache-policy authority or a performance metric.
  package func resourceProbeBudgetSnapshot() -> ShardedMemoryBudgetSnapshot {
    withAllShardsLocked {
      let shardCurrentCosts = shards.map(\.currentCostLocked)
      let shardAssignedLimits = shards.map(\.costLimitLocked)
      let shardResidentCounts = shards.map(\.countLocked)
      let currentCost = shardCurrentCosts.reduce(0, +)
      let unassigned = Int(AkashicAtomicInt64Load(&globalUnassignedCost))
      return ShardedMemoryBudgetSnapshot(
        totalCostLimit: totalCostLimit,
        currentCost: currentCost,
        globalUnassignedCost: unassigned,
        shardCurrentCosts: shardCurrentCosts,
        shardAssignedLimits: shardAssignedLimits,
        shardResidentCounts: shardResidentCounts
      )
    }
  }

  /// Package-only, explicitly sampled SIEVE hand geometry for each shard. No telemetry is kept on
  /// ordinary cache operations; the all-shard lock cost is paid only by research probes.
  package func resourceProbeHandTopologyStates() -> [MemoryCacheHandTopologyState] {
    withAllShardsLocked { shards.map { $0.handTopologyStateLocked() } }
  }

  private func insertWithRedistributedBudget(
    _ value: Value,
    for key: Key,
    rawHash: Int,
    shardIndex targetIndex: Int,
    normalizedCost: Int,
    evictedVictims: inout [MemoryCacheEvictionVictim<Key>]?
  ) {
    withAllShardsLocked {
      guard normalizedCost <= totalCostLimit else {
        // 与单分片 MemoryCache 相同：过大全量替换会移除旧键并留下 miss。
        let replacedCost = shards[targetIndex].costLocked(for: key, rawHash: rawHash)
        if replacedCost > 0 {
          evictedVictims?.append(MemoryCacheEvictionVictim(key: key, cost: replacedCost))
        }
        shards[targetIndex].removeLocked(key, rawHash: rawHash)
        canonicalizeBudgetLocked()
        return
      }

      let currentCosts = shards.map(\.currentCostLocked)
      let currentTotal = currentCosts.reduce(0, +)
      precondition(currentTotal <= totalCostLimit)
      let targetCurrent = currentCosts[targetIndex]
      let replacedCost = shards[targetIndex].costLocked(for: key, rawHash: rawHash)
      let targetRetained = targetCurrent - replacedCost
      let otherCurrent = currentTotal - targetCurrent
      let maximumTargetWithoutOtherEviction = totalCostLimit - otherCurrent
      let requiredTarget = targetRetained.addingReportingOverflow(normalizedCost)
      precondition(!requiredTarget.overflow)

      if normalizedCost <= maximumTargetWithoutOtherEviction {
        // 全局总容量足以仅在目标 shard 内解决：先把所有当前 spare（最多到本次真正
        // 需要的量）借给目标，再由目标自己的 SIEVE 处理剩余局部淘汰，不触碰其他 shard。
        let targetLimit = max(
          targetCurrent,
          min(maximumTargetWithoutOtherEviction, requiredTarget.partialValue)
        )
        shards[targetIndex].setCostLimitPreservingResidentsLocked(targetLimit)
      } else {
        // 单个对象本身都无法由“目标 shard + 当前全局 spare”容纳，才允许跨 shard
        // 释放 resident。这里只释放让 incoming object 合法所缺的最小成本，不再把
        // `totalLimit - targetLimit` 均分给其他 shard：均分会在高度偏斜状态下把
        // 一个 1-unit 缺口放大成几十个 unit 的无关热数据淘汰。
        var remainingDeficit = normalizedCost - maximumTargetWithoutOtherEviction
        precondition(remainingDeficit > 0)

        // 每轮只在其他 shard 当前合法的 SIEVE victim 中做 best-fit；目标 shard 留给
        // 随后的本地 insert/SIEVE 处理。这样不但不再均分 donor capacity，也避免一个
        // 1-unit deficit 因环上第一个 donor 恰好只有 100-unit victim 而过度释放。
        let donorStartIndex = (targetIndex + 1) % shards.count
        // 与 resize 相同，只缓存 immediate victim；successor 查询完全限制在真正需要
        // exact-successor tie-break 的轮次，避免无 tie slow path 承担额外 allocation/scan。
        var nextVictimCosts = shards.indices.map { index in
          index == targetIndex ? nil : shards[index].nextVictimCostLocked()
        }
        var successorVictimCosts: [Int]?
        while remainingDeficit > 0 {
          guard
            let donorIndex = ShardedMemoryVictimSelector.bestFitShardIndexLocked(
              shards: shards,
              remainingDeficit: remainingDeficit,
              excluding: targetIndex,
              startIndex: donorStartIndex,
              nextVictimCosts: nextVictimCosts,
              successorVictimCosts: &successorVictimCosts
            ),
            let victim = shards[donorIndex].removeNextVictimRecordLocked()
          else {
            preconditionFailure("global cache deficit must be satisfiable")
          }
          evictedVictims?.append(victim)
          let released = victim.cost
          remainingDeficit = max(0, remainingDeficit - released)
          nextVictimCosts[donorIndex] = shards[donorIndex].nextVictimCostLocked()
          successorVictimCosts?[donorIndex] = -1
        }

        let otherCostAfterRelease =
          currentCostLocked() - shards[targetIndex].currentCostLocked
        let targetLimit = totalCostLimit - otherCostAfterRelease
        precondition(targetLimit >= normalizedCost)
        shards[targetIndex].setCostLimitPreservingResidentsLocked(targetLimit)
      }

      shards[targetIndex].insertLocked(
        value,
        for: key,
        rawHash: rawHash,
        normalizedCost: normalizedCost,
        evictedVictims: &evictedVictims
      )
      canonicalizeBudgetLocked()
    }
  }

  private func evictionReport(
    from victims: [MemoryCacheEvictionVictim<Key>]
  ) -> MemoryCacheEvictionReport<Key> {
    var releasedCost = 0
    for victim in victims {
      let addition = releasedCost.addingReportingOverflow(victim.cost)
      precondition(!addition.overflow)
      releasedCost = addition.partialValue
    }
    return MemoryCacheEvictionReport(
      evictedKeys: victims.map(\.key),
      summary: MemoryCacheRemovalSummary(
        itemCount: victims.count,
        costBytes: releasedCost
      )
    )
  }

  @inline(__always)
  private func currentCostLocked() -> Int {
    shards.reduce(0) { $0 + $1.currentCostLocked }
  }

  private func canonicalizeBudgetLocked() {
    let current = currentCostLocked()
    precondition(current <= totalCostLimit)
    for shard in shards {
      shard.setCostLimitPreservingResidentsLocked(shard.currentCostLocked)
    }
    setGlobalUnassignedBudget(totalCostLimit - current)
  }

  @inline(__always)
  private func takeGlobalBudgetUpTo(_ amount: Int) -> Int {
    guard amount > 0 else { return 0 }
    guard let amount64 = Int64(exactly: amount) else {
      preconditionFailure("Akashic memory budget must fit Int64")
    }
    return Int(AkashicAtomicInt64TakeUpTo(&globalUnassignedCost, amount64))
  }

  @inline(__always)
  private func returnGlobalBudget(_ amount: Int) {
    guard amount > 0 else { return }
    guard let amount64 = Int64(exactly: amount) else {
      preconditionFailure("Akashic memory budget must fit Int64")
    }
    AkashicAtomicInt64Add(&globalUnassignedCost, amount64)
  }

  @inline(__always)
  private func setGlobalUnassignedBudget(_ amount: Int) {
    precondition(amount >= 0)
    guard let amount64 = Int64(exactly: amount) else {
      preconditionFailure("Akashic memory budget must fit Int64")
    }
    AkashicAtomicInt64Store(&globalUnassignedCost, amount64)
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
