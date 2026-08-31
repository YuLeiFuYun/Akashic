import Foundation

extension MemoryCache {
    func resourceProbeRevocationAwareEvictionPlanLocked(
        provisionalResidentLeases: [Key: MemoryCacheRevocationAwareResidentLease<Key>],
        incomingCost: Int
    ) -> MemoryCacheRevocationAwareEvictionPlan<Key> {
        let result = resourceProbeRevocationAwareEvictionPlanBuildLocked(
            provisionalResidentLeases: provisionalResidentLeases,
            incomingCost: incomingCost,
            maximumVictimCount: .max,
            maximumInspectedSlotCount: .max
        )
        guard let plan = result.plan else {
            preconditionFailure("unbounded revocation-aware plan must not hit a resource limit")
        }
        return plan
    }

    func resourceProbeRevocationAwareEvictionPlanBuildLocked(
        provisionalResidentLeases: [Key: MemoryCacheRevocationAwareResidentLease<Key>],
        incomingCost: Int,
        maximumVictimCount: Int,
        maximumInspectedSlotCount: Int
    ) -> MemoryCacheRevocationAwarePlanBuildResult<Key> {
        let maximumVictimCount = max(0, maximumVictimCount)
        let maximumInspectedSlotCount = max(0, maximumInspectedSlotCount)
        func complete(_ plan: MemoryCacheRevocationAwareEvictionPlan<Key>)
            -> MemoryCacheRevocationAwarePlanBuildResult<Key>
        {
            .init(
                plan: plan,
                limitReason: nil,
                victimCount: plan.victims.count,
                inspectedSlotCount: plan.inspectedSlotCount
            )
        }
        func limited(
            _ reason: MemoryCacheRevocationAwareSnapshotLimitReason,
            victimCount: Int,
            inspectedSlotCount: Int
        ) -> MemoryCacheRevocationAwarePlanBuildResult<Key> {
            .init(
                plan: nil,
                limitReason: reason,
                victimCount: victimCount,
                inspectedSlotCount: inspectedSlotCount
            )
        }

        let normalizedCost = max(1, incomingCost)
        guard normalizedCost <= costLimit else {
            return complete(
                MemoryCacheRevocationAwareEvictionPlanner.plan(
                    residentsFromHand: [],
                    requiredReleaseCost: 0
                )
            )
        }
        let maximumExistingCost = costLimit - normalizedCost
        let requiredReleaseCost = max(0, totalCost - maximumExistingCost)
        guard requiredReleaseCost > 0, let leastRecent else {
            return complete(
                MemoryCacheRevocationAwareEvictionPlanner.plan(
                    residentsFromHand: [],
                    requiredReleaseCost: 0
                )
            )
        }

        let effectiveHand = sieveHand ?? leastRecent
        if provisionalResidentLeases.isEmpty, visitedCount == residentCount {
            var victims: [MemoryCacheRevocationAwareVictim<Key>] = []
            var releasedCost = 0
            var inspectedSlotCount = 0
            var limitReason: MemoryCacheRevocationAwareSnapshotLimitReason?

            func appendResetVictim(_ node: Node) -> Bool {
                if victims.count >= maximumVictimCount {
                    limitReason = .victimCount
                    return true
                }
                if inspectedSlotCount >= maximumInspectedSlotCount {
                    limitReason = .inspectedSlotCount
                    return true
                }
                inspectedSlotCount += 1
                victims.append(.init(key: node.key, cost: node.cost))
                releasedCost += node.cost
                return releasedCost >= requiredReleaseCost
            }

            var cursor: Node? = effectiveHand
            while let node = cursor {
                if appendResetVictim(node) { break }
                cursor = node.next
            }
            if releasedCost < requiredReleaseCost, effectiveHand !== leastRecent {
                cursor = leastRecent
                while let node = cursor, node !== effectiveHand {
                    if appendResetVictim(node) { break }
                    cursor = node.next
                }
            }
            if let limitReason {
                return limited(
                    limitReason,
                    victimCount: victims.count,
                    inspectedSlotCount: inspectedSlotCount
                )
            }
            return complete(
                .init(
                    victims: victims,
                    provisionalRevocations: [],
                    releasedCost: releasedCost,
                    fullVisitedEpochResetCount: 1,
                    inspectedSlotCount: inspectedSlotCount
                )
            )
        }

        var victims: [MemoryCacheRevocationAwareVictim<Key>] = []
        var revocations: [Key] = []
        var releasedCost = 0
        var inspectedSlotCount = 0
        var ordinaryVisitedSeen = false
        var coldAfterOrdinaryVisited = false
        var effectiveColdRemaining = residentCount - visitedCount
            + provisionalResidentLeases.count
        var prefixEpochResetApplied = false
        var limitReason: MemoryCacheRevocationAwareSnapshotLimitReason?

        func inspectFirstRevolution(_ node: Node) -> Bool {
            if inspectedSlotCount >= maximumInspectedSlotCount {
                limitReason = .inspectedSlotCount
                return true
            }
            inspectedSlotCount += 1
            if prefixEpochResetApplied {
                if victims.count >= maximumVictimCount {
                    limitReason = .victimCount
                    return true
                }
                victims.append(.init(key: node.key, cost: node.cost))
                releasedCost += node.cost
                return releasedCost >= requiredReleaseCost
            }
            let visited = node.visitedEpoch == visitEpoch
            let provisionalVisited = visited
                && provisionalResidentLeases[node.key]?.matches(
                    identity: node,
                    incarnation: node.incarnation
                ) == true
            if visited && !provisionalVisited {
                ordinaryVisitedSeen = true
                return false
            }
            if ordinaryVisitedSeen { coldAfterOrdinaryVisited = true }
            effectiveColdRemaining -= 1
            precondition(effectiveColdRemaining >= 0)
            if victims.count >= maximumVictimCount {
                limitReason = .victimCount
                return true
            }
            if provisionalVisited { revocations.append(node.key) }
            victims.append(.init(key: node.key, cost: node.cost))
            releasedCost += node.cost
            if releasedCost >= requiredReleaseCost { return true }
            if !ordinaryVisitedSeen, effectiveColdRemaining == 0 {
                prefixEpochResetApplied = true
            }
            return false
        }

        var cursor: Node? = effectiveHand
        while let node = cursor {
            if inspectFirstRevolution(node) {
                if let limitReason {
                    return limited(
                        limitReason,
                        victimCount: victims.count,
                        inspectedSlotCount: inspectedSlotCount
                    )
                }
                return complete(
                    .init(
                        victims: victims,
                        provisionalRevocations: revocations,
                        releasedCost: releasedCost,
                        fullVisitedEpochResetCount: prefixEpochResetApplied ? 1 : 0,
                        inspectedSlotCount: inspectedSlotCount
                    )
                )
            }
            cursor = node.next
        }
        if effectiveHand !== leastRecent {
            cursor = leastRecent
            while let node = cursor, node !== effectiveHand {
                if inspectFirstRevolution(node) {
                    if let limitReason {
                        return limited(
                            limitReason,
                            victimCount: victims.count,
                            inspectedSlotCount: inspectedSlotCount
                        )
                    }
                    return complete(
                        .init(
                            victims: victims,
                            provisionalRevocations: revocations,
                            releasedCost: releasedCost,
                            fullVisitedEpochResetCount: prefixEpochResetApplied ? 1 : 0,
                            inspectedSlotCount: inspectedSlotCount
                        )
                    )
                }
                cursor = node.next
            }
        }

        let epochResetCount = prefixEpochResetApplied
            || (ordinaryVisitedSeen && !coldAfterOrdinaryVisited) ? 1 : 0
        func inspectSecondRevolution(_ node: Node) -> Bool {
            if inspectedSlotCount >= maximumInspectedSlotCount {
                limitReason = .inspectedSlotCount
                return true
            }
            inspectedSlotCount += 1
            let visited = node.visitedEpoch == visitEpoch
            let provisionalVisited = visited
                && provisionalResidentLeases[node.key]?.matches(
                    identity: node,
                    incarnation: node.incarnation
                ) == true
            guard visited && !provisionalVisited else { return false }
            if victims.count >= maximumVictimCount {
                limitReason = .victimCount
                return true
            }
            victims.append(.init(key: node.key, cost: node.cost))
            releasedCost += node.cost
            return releasedCost >= requiredReleaseCost
        }

        if !prefixEpochResetApplied {
            cursor = effectiveHand
            while let node = cursor {
                if inspectSecondRevolution(node) { break }
                cursor = node.next
            }
            if releasedCost < requiredReleaseCost, effectiveHand !== leastRecent {
                cursor = leastRecent
                while let node = cursor, node !== effectiveHand {
                    if inspectSecondRevolution(node) { break }
                    cursor = node.next
                }
            }
        }

        if let limitReason {
            return limited(
                limitReason,
                victimCount: victims.count,
                inspectedSlotCount: inspectedSlotCount
            )
        }
        return complete(
            .init(
                victims: victims,
                provisionalRevocations: revocations,
                releasedCost: releasedCost,
                fullVisitedEpochResetCount: epochResetCount,
                inspectedSlotCount: inspectedSlotCount
            )
        )
    }

    /// Allocation-free commit-side validation of an optimistic snapshot. This deliberately compares
    /// only decision-relevant structural output, not `inspectedSlotCount`: hits outside the final
    /// trace may change unrelated cache state without forcing a false retry.
}
