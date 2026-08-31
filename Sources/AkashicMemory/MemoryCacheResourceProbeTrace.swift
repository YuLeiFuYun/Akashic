import Foundation

extension MemoryCache {
    func resourceProbeEvictionTraceLocked(
        incomingCost: Int
    ) -> MemoryCacheEvictionTrace<Key> {
        let normalizedCost = max(1, incomingCost)
        guard normalizedCost <= costLimit else {
            return MemoryCacheEvictionTrace(
                clearedVisitedKeys: [],
                victims: [],
                fullVisitedEpochResetCount: 0
            )
        }
        let maximumExistingCost = costLimit - normalizedCost
        guard totalCost > maximumExistingCost else {
            return MemoryCacheEvictionTrace(
                clearedVisitedKeys: [],
                victims: [],
                fullVisitedEpochResetCount: 0
            )
        }

        var ring: [Node] = []
        ring.reserveCapacity(residentCount)
        var cursor = leastRecent
        while let node = cursor {
            ring.append(node)
            cursor = node.next
        }
        guard ring.count == residentCount else {
            return MemoryCacheEvictionTrace(
                clearedVisitedKeys: [],
                victims: [],
                fullVisitedEpochResetCount: 0
            )
        }

        var visited: [ObjectIdentifier: Bool] = [:]
        visited.reserveCapacity(ring.count)
        for node in ring {
            visited[ObjectIdentifier(node)] = node.visitedEpoch == visitEpoch
        }
        var handID = sieveHand.map(ObjectIdentifier.init)
        var simulatedCost = totalCost
        var clearedVisitedKeys: [Key] = []
        var victims: [MemoryCacheEvictionVictim<Key>] = []
        var fullVisitedEpochResetCount = 0

        while simulatedCost > maximumExistingCost, !ring.isEmpty {
            if handID == nil { handID = ObjectIdentifier(ring[0]) }
            if ring.allSatisfy({ visited[ObjectIdentifier($0)] == true }) {
                fullVisitedEpochResetCount += 1
                // The production epoch jump is equivalent to one complete hand revolution
                // starting at the current hand, consuming every current second-chance, and
                // returning to that same hand before choosing a victim. Preserve that event order
                // here: hand-coupled research policies must not confuse FIFO order with hand order.
                guard let currentHandID = handID,
                    let handIndex = ring.firstIndex(where: {
                        ObjectIdentifier($0) == currentHandID
                    })
                else {
                    preconditionFailure("SIEVE shadow hand must reference a resident node")
                }
                for offset in 0..<ring.count {
                    let node = ring[(handIndex + offset) % ring.count]
                    let id = ObjectIdentifier(node)
                    if visited[id] == true { clearedVisitedKeys.append(node.key) }
                    visited[id] = false
                }
            }

            var victimIndex: Int?
            while victimIndex == nil {
                guard let currentID = handID,
                    let index = ring.firstIndex(where: { ObjectIdentifier($0) == currentID })
                else {
                    handID = ObjectIdentifier(ring[0])
                    continue
                }
                let nextID = ObjectIdentifier(ring[(index + 1) % ring.count])
                if visited[currentID] == true {
                    clearedVisitedKeys.append(ring[index].key)
                    visited[currentID] = false
                    handID = nextID
                } else {
                    victimIndex = index
                    handID = ring.count == 1 ? nil : nextID
                }
            }

            guard let victimIndex else { break }
            let victim = ring.remove(at: victimIndex)
            visited.removeValue(forKey: ObjectIdentifier(victim))
            simulatedCost -= victim.cost
            victims.append(
                MemoryCacheEvictionVictim(key: victim.key, cost: victim.cost)
            )
        }
        return MemoryCacheEvictionTrace(
            clearedVisitedKeys: clearedVisitedKeys,
            victims: victims,
            fullVisitedEpochResetCount: fullVisitedEpochResetCount
        )
    }

    /// 当前归一化插入总成本。
}
