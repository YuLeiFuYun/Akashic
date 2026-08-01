import Foundation

/// 描述一次内存缓存裁剪或清空实际释放的条目数与归一化成本。
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

/// 进程内、按成本设限的 SIEVE 缓存；不感知所存值所属的业务领域。
///
/// 命中只设置单比特访问标记，淘汰时再执行惰性提升。与逐命中改链表的 LRU 相比，
/// 该状态机减少命中热路径写操作，并让一次性对象更快离开 FIFO 驻留集合。
/// 内部用短临界区锁和直接节点链接维护线性化语义，避免 actor 调度、Entry 值拷贝
/// 以及通过键反复回查相邻节点的成本。
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var visitedEpoch: UInt64
        unowned(unsafe) var previous: Node?
        unowned(unsafe) var next: Node?

        init(key: Key, value: Value, cost: Int, previous: Node?) {
            self.key = key
            self.value = value
            self.cost = cost
            self.visitedEpoch = 0
            self.previous = previous
        }
    }

    private let lock = NSLock()
    private var costLimit: Int
    private var totalCost = 0
    private var residentCount = 0
    private var visitedCount = 0
    private var visitEpoch: UInt64 = 1
    private var entries: [Key: Node] = [:]
    private unowned(unsafe) var leastRecent: Node?
    private unowned(unsafe) var mostRecent: Node?
    private unowned(unsafe) var sieveHand: Node?

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
            }
            return node.value
        }
    }

    /// 先淘汰满足成本上限所需的最久未使用项，再插入值。
    public func insert(_ value: Value, for key: Key, cost: Int) {
        atomic {
            let cost = max(1, cost)
            let reusable = entries[key]
            if let reusable { detachLocked(reusable) }
            guard cost <= costLimit else {
                if reusable != nil { entries.removeValue(forKey: key) }
                return
            }

            // 先腾出确定空间，再执行加法；即使 limit 为 Int.max，也不会发生总成本溢出。
            let maximumExistingCost = costLimit - cost
            while totalCost > maximumExistingCost, let victim = nextSieveVictimLocked() {
                removeLocked(victim)
            }

            let node: Node
            if let reusable {
                reusable.value = value
                reusable.cost = cost
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
            if reusable == nil { entries[key] = node }
            totalCost += cost
        }
    }

    /// 原子更新总成本上限，并按当前 SIEVE 状态淘汰到新上限。
    ///
    /// 返回本次收缩实际删除的条目数和成本；扩张或等值更新返回零摘要。
    public func updateCostLimit(_ newLimit: Int) -> MemoryCacheRemovalSummary {
        atomic {
            let normalized = max(1, newLimit)
            costLimit = normalized
            let initialCount = entries.count
            let initialCost = totalCost
            while totalCost > normalized, let victim = nextSieveVictimLocked() {
                removeLocked(victim)
            }
            return MemoryCacheRemovalSummary(
                itemCount: initialCount - entries.count,
                costBytes: initialCost - totalCost
            )
        }
    }

    /// 删除一个键，同时保持其他最近性链接正确。
    public func remove(_ key: Key) {
        atomic {
            guard let node = entries[key] else { return }
            removeLocked(node)
        }
    }

    /// 删除由非隔离且可发送谓词选中的所有键。
    public func removeAll(where predicate: @Sendable (Key) -> Bool) {
        atomic {
            let victims = entries.values.filter { predicate($0.key) }
            for node in victims { removeLocked(node) }
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
            return summary
        }
    }

    /// 当前归一化插入总成本。
    public var currentCost: Int { atomic { totalCost } }

    /// 当前活动缓存项数量。
    public var count: Int { atomic { entries.count } }

    /// SIEVE 将插入链表视作 FIFO 队列。循环指针遇到已访问对象时只清除访问代次，
    /// 遇到未访问对象时才淘汰。若全部驻留对象都已访问，经典 SIEVE 必然完整绕环、
    /// 清除所有访问位并回到同一 hand；此处以 O(1) 推进全局代次得到完全相同的 victim，
    /// 避免高并发读后下一次插入在锁内集中扫描整个缓存。
    private func nextSieveVictimLocked() -> Node? {
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
    private func advanceVisitEpochLocked() {
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

    @inline(__always)
    private func atomic<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func detachLocked(_ node: Node) {
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

    private func removeLocked(_ node: Node) {
        detachLocked(node)
        entries.removeValue(forKey: node.key)
    }
}
