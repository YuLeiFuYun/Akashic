import Foundation

/// 描述一次内存缓存裁剪或清空实际释放的条目数与归一化成本。
package struct MemoryCacheEvictionVictim<Key: Sendable>: Sendable {
    package let key: Key
    package let cost: Int

    package init(key: Key, cost: Int) {
        self.key = key
        self.cost = cost
    }
}

/// 研究探针使用：描述一次不变更真实缓存状态的 SIEVE 淘汰模拟。
/// `clearedVisitedKeys` 按模拟 hand 顺序列出本次为寻找 victim 而消费 second-chance 的 key；
/// `victims` 则是随后实际需要删除的对象集合。package-only，不构成公共 cache contract。
package struct MemoryCacheEvictionTrace<Key: Sendable>: Sendable {
    package let clearedVisitedKeys: [Key]
    package let victims: [MemoryCacheEvictionVictim<Key>]
    /// 模拟过程中会触发 production `visitedCount == residentCount` epoch 全清的次数。
    package let fullVisitedEpochResetCount: Int
}

/// 研究探针使用：当前 resident SIEVE visited/unvisited 资源分解。
package struct MemoryCacheVisitState: Sendable {
    package let residentCount: Int
    package let visitedCount: Int
    package let residentCost: Int
    package let visitedCost: Int
    package let unvisitedCost: Int
}

/// 研究探针使用：把当前 FIFO resident ring 按有效 SIEVE hand 切成 hand 之前的前缀
/// 与从 hand 开始的后缀。该状态只在显式 probe 调用时遍历链表，不在普通 hit/insert
/// 热路径维护额外计数；package-only，不构成公共 cache policy contract。
package struct MemoryCacheHandTopologyState: Codable, Hashable, Sendable {
    package let residentCount: Int
    package let residentCost: Int
    package let prefixBeforeHandCount: Int
    package let prefixBeforeHandCost: Int
    package let suffixFromHandCount: Int
    package let suffixFromHandCost: Int

    package init(
        residentCount: Int,
        residentCost: Int,
        prefixBeforeHandCount: Int,
        prefixBeforeHandCost: Int,
        suffixFromHandCount: Int,
        suffixFromHandCost: Int
    ) {
        self.residentCount = residentCount
        self.residentCost = residentCost
        self.prefixBeforeHandCount = prefixBeforeHandCount
        self.prefixBeforeHandCost = prefixBeforeHandCost
        self.suffixFromHandCount = suffixFromHandCount
        self.suffixFromHandCost = suffixFromHandCost
    }
}

public struct MemoryCacheRemovalSummary: Hashable, Sendable {
    /// 本次操作移除的缓存项数量。
    public let itemCount: Int
    /// 本次操作释放的归一化成本字节数。
    public let costBytes: Int

    /// 创建已完成缓存操作的释放摘要。
    public init(itemCount: Int, costBytes: Int) {
        self.itemCount = itemCount
        self.costBytes = costBytes
    }
}

/// 一次缓存变更实际删除的身份与对应释放摘要。
///
/// `evictedKeys` 只包含操作结束后已不再驻留的 key；同 key 的普通 replacement 不会
/// 被误报为 eviction。该结果用于上层维护与真实缓存 residency 同步的轻量索引，而不
/// 暴露 SIEVE hand、visited bit 或分片实现细节。
public struct MemoryCacheEvictionReport<Key: Sendable>: Sendable {
    /// 按真实删除顺序记录的缓存身份。
    public let evictedKeys: [Key]
    /// 与 `evictedKeys` 对应的条目数和归一化成本汇总。
    public let summary: MemoryCacheRemovalSummary

    /// 创建一次已完成缓存变更的精确 eviction 回执。
    public init(evictedKeys: [Key], summary: MemoryCacheRemovalSummary) {
        self.evictedKeys = evictedKeys
        self.summary = summary
    }
}

/// 进程内、按成本设限的 SIEVE 缓存；不感知所存值所属的业务领域。
///
/// 命中只设置单比特访问标记，淘汰时再执行惰性提升。与逐命中改链表的 LRU 相比，
/// 该状态机减少命中热路径写操作，并让一次性对象更快离开 FIFO 驻留集合。
/// 内部用短临界区锁和直接节点链接维护线性化语义，避免 actor 调度、Entry 值拷贝
/// 以及通过键反复回查相邻节点的成本。
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var incarnation: UInt64
        var visitedEpoch: UInt64
        unowned(unsafe) var previous: Node?
        unowned(unsafe) var next: Node?

        init(key: Key, value: Value, cost: Int, previous: Node?) {
            self.key = key
            self.value = value
            self.cost = cost
            self.incarnation = 0
            self.visitedEpoch = 0
            self.previous = previous
        }
    }

    let lock = NSLock()
    var costLimit: Int
    var totalCost = 0
    var residentCount = 0
    var visitedCount = 0
    var visitEpoch: UInt64 = 1
    var evictionStateVersion: UInt64 = 0
    var evictionStateVersionSaturated = false
    var deferredRetirementInFlight = 0
    var deferredRetirementInFlightItemCount = 0
    var deferredRetirementInFlightCost = 0
    var queuedRetirementEntries: [Key: Node]? = nil
    var queuedRetirementItemCount = 0
    var queuedRetirementCost = 0
    var entries: [Key: Node] = [:]
    unowned(unsafe) var leastRecent: Node?
    unowned(unsafe) var mostRecent: Node?
    unowned(unsafe) var sieveHand: Node?

    /// 创建总成本上限已归一化为正值的 SIEVE 缓存。
    public init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
    }

    /// 返回缓存值，并设置访问标记；命中热路径不改变 FIFO 链表。
    public func value(for key: Key) -> Value? {
        atomic {
            guard let node = entries[key] else { return nil }
            if node.visitedEpoch != visitEpoch {
                node.visitedEpoch = visitEpoch
                visitedCount += 1
                markEvictionStateChangedLocked()
            }
            return node.value
        }
    }

    /// 先淘汰满足成本上限所需的最久未使用项，再插入值。
    public func insert(_ value: Value, for key: Key, cost: Int) {
        atomic {
            if insertLocked(value, for: key, cost: cost) {
                markEvictionStateChangedLocked()
            }
        }
    }

    /// 原子更新总成本上限，并按当前 SIEVE 状态淘汰到新上限。
    ///
    /// 返回本次收缩实际删除的条目数和成本；扩张或等值更新返回零摘要。
    public func updateCostLimit(_ newLimit: Int) -> MemoryCacheRemovalSummary {
        atomic {
            let normalized = max(1, newLimit)
            let limitChanged = normalized != costLimit
            costLimit = normalized
            let initialCount = entries.count
            let initialCost = totalCost
            while totalCost > normalized, let victim = nextSieveVictimLocked() {
                removeLocked(victim)
            }
            let summary = MemoryCacheRemovalSummary(
                itemCount: initialCount - entries.count,
                costBytes: initialCost - totalCost
            )
            if limitChanged || summary.itemCount > 0 {
                markEvictionStateChangedLocked()
            }
            return summary
        }
    }

    /// 删除一个键，同时保持其他最近性链接正确。
    public func remove(_ key: Key) {
        atomic {
            guard let node = entries[key] else { return }
            removeLocked(node)
            markEvictionStateChangedLocked()
        }
    }

    /// 删除由非隔离且可发送谓词选中的所有键。
    public func removeAll(where predicate: @Sendable (Key) -> Bool) {
        // Never execute caller code while holding the cache mutex. Besides allowing the predicate
        // to re-enter this cache, the saved node identity + incarnation makes the second phase
        // conditional: a replacement that happens while the predicate is running must survive an
        // older snapshot's decision.
        let candidates: [(key: Key, node: Node, incarnation: UInt64)] = atomic {
            entries.values.map { ($0.key, $0, $0.incarnation) }
        }
        let victims = candidates.filter { predicate($0.key) }
        atomic {
            var removedAny = false
            for candidate in victims {
                guard let current = entries[candidate.key],
                    current === candidate.node,
                    current.incarnation == candidate.incarnation
                else { continue }
                removeLocked(current)
                removedAny = true
            }
            if removedAny { markEvictionStateChangedLocked() }
        }
    }

    /// 删除全部缓存项并重置成本计数。
    public func removeAll() {
        _ = removeAllAndReport()
    }

    /// 删除全部缓存项，并返回实际释放的条目数与成本。
    public func removeAllAndReport() -> MemoryCacheRemovalSummary {
        atomic {
            let summary = MemoryCacheRemovalSummary(
                itemCount: entries.count,
                costBytes: totalCost
            )
            entries.removeAll(keepingCapacity: false)
            leastRecent = nil
            mostRecent = nil
            sieveHand = nil
            totalCost = 0
            residentCount = 0
            visitedCount = 0
            visitEpoch = 1
            if summary.itemCount > 0 { markEvictionStateChangedLocked() }
            return summary
        }
    }

    /// 研究探针使用：在不改变 SIEVE hand、访问代次或 resident 状态的前提下，
    /// 精确预测一个新对象按当前状态插入时需要淘汰的 victim 集合。
    /// 该入口是 package-only，不构成公共 cache policy contract。
    public var currentCost: Int { atomic { totalCost } }

    /// 当前活动缓存项数量。
    public var count: Int { atomic { entries.count } }

    @discardableResult
    func insertLocked(_ value: Value, for key: Key, cost: Int) -> Bool {
        let cost = max(1, cost)
        let reusable = entries[key]
        if let reusable { detachLocked(reusable) }
        guard cost <= costLimit else {
            if reusable != nil {
                entries.removeValue(forKey: key)
                return true
            }
            return false
        }

        // 先腾出确定空间，再执行加法；即使 limit 为 Int.max，也不会发生总成本溢出。
        let maximumExistingCost = costLimit - cost
        while totalCost > maximumExistingCost, let victim = nextSieveVictimLocked() {
            removeLocked(victim)
        }

        let node: Node
        if let reusable, reusable.incarnation != UInt64.max {
            reusable.value = value
            reusable.cost = cost
            reusable.incarnation += 1
            reusable.visitedEpoch = 0
            reusable.previous = mostRecent
            node = reusable
        } else {
            node = Node(key: key, value: value, cost: cost, previous: mostRecent)
        }
        mostRecent?.next = node
        if leastRecent == nil { leastRecent = node }
        mostRecent = node
        residentCount += 1
        if reusable == nil || node !== reusable { entries[key] = node }
        totalCost += cost
        return true
    }

    /// SIEVE 将插入链表视作 FIFO 队列。循环指针遇到已访问对象时只清除访问代次，
    /// 遇到未访问对象时才淘汰。若全部驻留对象都已访问，经典 SIEVE 必然完整绕环、
    /// 清除所有访问位并回到同一 hand；此处以 O(1) 推进全局代次得到完全相同的 victim，
    /// 避免高并发读后下一次插入在锁内集中扫描整个缓存。
    func nextSieveVictimLocked() -> Node? {
        guard residentCount > 0, leastRecent != nil else { return nil }
        if sieveHand == nil { sieveHand = leastRecent }
        if visitedCount == residentCount { advanceVisitEpochLocked() }

        while let candidate = sieveHand {
            let next = candidate.next ?? leastRecent
            if candidate.visitedEpoch == visitEpoch {
                candidate.visitedEpoch = 0
                visitedCount -= 1
                sieveHand = next
            } else {
                sieveHand = next === candidate ? nil : next
                return candidate
            }
        }
        return leastRecent
    }

    /// 全访问集合的逻辑清位。UInt64 回绕只可能在不可实现的运行长度后出现，
    /// 仍通过一次显式归一化保持状态机总定义和可模型检查性。
    func advanceVisitEpochLocked() {
        if visitEpoch == .max {
            var node = leastRecent
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

    func retirementGenerationCountLocked() -> Int {
        let queuedCount = queuedRetirementEntries == nil ? 0 : 1
        let total = deferredRetirementInFlight.addingReportingOverflow(queuedCount)
        return total.overflow ? .max : total.partialValue
    }

    func beginRetirementInFlightLocked(_ summary: MemoryCacheRemovalSummary) {
        precondition(summary.itemCount >= 0 && summary.costBytes >= 0)
        let generations = deferredRetirementInFlight.addingReportingOverflow(1)
        let items = deferredRetirementInFlightItemCount.addingReportingOverflow(summary.itemCount)
        let cost = deferredRetirementInFlightCost.addingReportingOverflow(summary.costBytes)
        precondition(!generations.overflow && !items.overflow && !cost.overflow)
        deferredRetirementInFlight = generations.partialValue
        deferredRetirementInFlightItemCount = items.partialValue
        deferredRetirementInFlightCost = cost.partialValue
    }

    func finishRetirementInFlightLocked(_ summary: MemoryCacheRemovalSummary) {
        precondition(
            deferredRetirementInFlight > 0
                && deferredRetirementInFlightItemCount >= summary.itemCount
                && deferredRetirementInFlightCost >= summary.costBytes
        )
        deferredRetirementInFlight -= 1
        deferredRetirementInFlightItemCount -= summary.itemCount
        deferredRetirementInFlightCost -= summary.costBytes
    }

    /// Monotonic decision-state token for optimistic package-only admission. Saturation deliberately
    /// disables the equality fast path instead of wrapping: a wrapped token could ABA an arbitrarily
    /// old snapshot. Once saturated, exact streaming validation remains available indefinitely.
    func markEvictionStateChangedLocked() {
        guard !evictionStateVersionSaturated else { return }
        if evictionStateVersion == .max {
            evictionStateVersionSaturated = true
        } else {
            evictionStateVersion += 1
        }
    }

    func currentEvictionStateVersionLocked() -> UInt64? {
        evictionStateVersionSaturated ? nil : evictionStateVersion
    }

    @inline(__always)
    func atomic<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func detachLocked(_ node: Node) {
        if node.visitedEpoch == visitEpoch {
            visitedCount -= 1
        }
        residentCount -= 1
        if sieveHand === node {
            sieveHand = node.next ?? (leastRecent === node ? nil : leastRecent)
        }
        if leastRecent === node { leastRecent = node.next }
        if mostRecent === node { mostRecent = node.previous }
        node.previous?.next = node.next
        node.next?.previous = node.previous
        node.previous = nil
        node.next = nil
        totalCost -= node.cost
        if leastRecent == nil {
            mostRecent = nil
            sieveHand = nil
            residentCount = 0
            visitedCount = 0
        }
    }

    func removeLocked(_ node: Node) {
        detachLocked(node)
        entries.removeValue(forKey: node.key)
    }
}
