import Foundation

/// Package-only exact pending-slot index for bounded-bypass research.
///
/// Leaves are physical `pending` array slots. A live indexed request stores its exact normalized
/// expected byte count; tombstones/nonindexed slots store `Int.max`. Internal nodes store the
/// minimum leaf size in their range, so a range first-fit query can descend to the earliest slot
/// whose exact size is <= the structural/current byte margin.
///
/// The index deliberately owns no request/token objects. The scheduler's primary pending array and
/// token->slot map remain authoritative; this is only a resource-accounted acceleration structure.
package struct FileBlobStoreReadBypassExactIndex {
    package struct SearchResult: Sendable, Equatable {
        package let slot: Int?
        package let nodesExamined: Int
    }

    private static let empty = Int.max
    private var capacity = 0
    private var tree: [Int] = []

    package var scalarSlots: Int { tree.count }
    package var leafCapacity: Int { capacity }

    /// Point update. Returns the number of scalar tree slots written, including the leaf.
    @discardableResult
    package mutating func update(slot: Int, expectedBytes: Int?) -> Int {
        precondition(slot >= 0)
        if expectedBytes == nil, slot >= capacity { return 0 }
        var writes = ensureCapacity(forSlotCount: slot + 1)
        guard capacity > 0 else { return writes }
        var index = capacity + slot
        let normalized = expectedBytes.map { max(1, $0) } ?? Self.empty
        if tree[index] != normalized {
            tree[index] = normalized
            writes += 1
        }
        while index > 1 {
            index /= 2
            let next = min(tree[index * 2], tree[index * 2 + 1])
            if tree[index] != next {
                tree[index] = next
                writes += 1
            }
        }
        return writes
    }

    /// Rebuilds from exact physical pending slots. `nil` means tombstone/nonindexed.
    /// Returns total scalar writes used to materialize the new tree payload.
    @discardableResult
    package mutating func rebuild(_ expectedBytesBySlot: [Int?]) -> Int {
        guard !expectedBytesBySlot.isEmpty else {
            capacity = 0
            tree.removeAll(keepingCapacity: false)
            return 0
        }
        capacity = Self.nextPowerOfTwo(expectedBytesBySlot.count)
        tree = [Int](repeating: Self.empty, count: capacity * 2)
        var writes = tree.count
        for (slot, expectedBytes) in expectedBytesBySlot.enumerated() {
            if let expectedBytes {
                tree[capacity + slot] = max(1, expectedBytes)
                writes += 1
            }
        }
        if capacity > 1 {
            for index in stride(from: capacity - 1, through: 1, by: -1) {
                tree[index] = min(tree[index * 2], tree[index * 2 + 1])
                writes += 1
            }
        }
        return writes
    }

    /// Earliest exact-fit physical slot in `[start, slotCount)`. The returned node count includes
    /// every range aggregate/leaf predicate actually inspected by the descent.
    package func firstSlot(
        startingAt start: Int,
        slotCount: Int,
        maximumBytes: Int
    ) -> SearchResult {
        precondition(start >= 0 && slotCount >= 0 && maximumBytes > 0)
        guard capacity > 0, start < slotCount else {
            return .init(slot: nil, nodesExamined: 0)
        }
        let effectiveCount = min(slotCount, capacity)
        var examined = 0

        func search(_ node: Int, _ lower: Int, _ upper: Int) -> Int? {
            if upper <= start || lower >= effectiveCount { return nil }
            examined += 1
            if tree[node] > maximumBytes { return nil }
            if upper - lower == 1 { return lower }
            let middle = lower + (upper - lower) / 2
            if let left = search(node * 2, lower, middle) { return left }
            return search(node * 2 + 1, middle, upper)
        }

        return .init(
            slot: search(1, 0, capacity),
            nodesExamined: examined
        )
    }

    private mutating func ensureCapacity(forSlotCount count: Int) -> Int {
        guard count > capacity else { return 0 }
        let newCapacity = Self.nextPowerOfTwo(count)
        let oldCapacity = capacity
        let oldTree = tree
        capacity = newCapacity
        tree = [Int](repeating: Self.empty, count: newCapacity * 2)
        var writes = tree.count
        if oldCapacity > 0 {
            for slot in 0..<oldCapacity {
                tree[newCapacity + slot] = oldTree[oldCapacity + slot]
                writes += 1
            }
            if newCapacity > 1 {
                for index in stride(from: newCapacity - 1, through: 1, by: -1) {
                    tree[index] = min(tree[index * 2], tree[index * 2 + 1])
                    writes += 1
                }
            }
        }
        return writes
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        precondition(value > 0)
        var result = 1
        while result < value {
            let doubled = result.multipliedReportingOverflow(by: 2)
            precondition(!doubled.overflow)
            result = doubled.partialValue
        }
        return result
    }
}
