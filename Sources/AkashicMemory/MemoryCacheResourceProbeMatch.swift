import Foundation

extension MemoryCache {
    func resourceProbeRevocationAwareEvictionPlanMatchesLocked(
        _ expectedSnapshot: MemoryCacheRevocationAwareEvictionSnapshot<Key>,
        incomingCost: Int,
        inspectedSlotCount: inout Int,
        maximumInspectedSlotCount: Int?,
        limitExceeded: inout Bool
    ) -> Bool {
        let normalizedCost = max(1, incomingCost)
        guard normalizedCost == expectedSnapshot.normalizedIncomingCost,
            normalizedCost <= costLimit
        else { return false }

        let validationInspectionLimit = maximumInspectedSlotCount.map { max(0, $0) }
        func consumeInspection() -> Bool {
            if let validationInspectionLimit,
                inspectedSlotCount >= validationInspectionLimit
            {
                limitExceeded = true
                return false
            }
            inspectedSlotCount += 1
            return true
        }

        let expected = expectedSnapshot.plan
        let maximumExistingCost = costLimit - normalizedCost
        let requiredReleaseCost = max(0, totalCost - maximumExistingCost)
        guard requiredReleaseCost > 0, let leastRecent else {
            return expected.victims.isEmpty
                && expected.provisionalRevocations.isEmpty
                && expected.releasedCost == 0
                && expected.fullVisitedEpochResetCount == 0
        }

        let effectiveHand = sieveHand ?? leastRecent
        if expectedSnapshot.provisionalResidentLeases.isEmpty, visitedCount == residentCount {
            guard expected.provisionalRevocations.isEmpty,
                expected.fullVisitedEpochResetCount == 1
            else { return false }
            var victimIndex = 0
            var releasedCost = 0
            var mismatch = false

            func matchResetVictim(_ node: Node) -> Bool {
                guard consumeInspection() else {
                    mismatch = true
                    return true
                }
                guard victimIndex < expected.victims.count else { return true }
                let expectedVictim = expected.victims[victimIndex]
                guard expectedVictim.key == node.key, expectedVictim.cost == node.cost else {
                    return true
                }
                victimIndex += 1
                releasedCost += node.cost
                return releasedCost >= requiredReleaseCost
            }

            var cursor: Node? = effectiveHand
            while let node = cursor {
                let before = victimIndex
                if matchResetVictim(node) {
                    mismatch = victimIndex == before
                    break
                }
                cursor = node.next
            }
            if !mismatch,
                releasedCost < requiredReleaseCost,
                effectiveHand !== leastRecent
            {
                cursor = leastRecent
                while let node = cursor, node !== effectiveHand {
                    let before = victimIndex
                    if matchResetVictim(node) {
                        mismatch = victimIndex == before
                        break
                    }
                    cursor = node.next
                }
            }
            return !mismatch
                && victimIndex == expected.victims.count
                && releasedCost == expected.releasedCost
        }

        var victimIndex = 0
        var revocationIndex = 0
        var releasedCost = 0
        var ordinaryVisitedSeen = false
        var coldAfterOrdinaryVisited = false
        var mismatch = false
        var matchingProvisionalVisitedCount = 0
        for (key, lease) in expectedSnapshot.provisionalResidentLeases {
            guard let node = entries[key], node.visitedEpoch == visitEpoch else { continue }
            if lease.matches(identity: node, incarnation: node.incarnation) {
                matchingProvisionalVisitedCount += 1
            }
        }
        var effectiveColdRemaining = residentCount - visitedCount
            + matchingProvisionalVisitedCount
        var prefixEpochResetApplied = false

        func matchFirstRevolution(_ node: Node) -> Bool {
            guard consumeInspection() else {
                mismatch = true
                return true
            }
            if prefixEpochResetApplied {
                guard victimIndex < expected.victims.count else {
                    mismatch = true
                    return true
                }
                let expectedVictim = expected.victims[victimIndex]
                guard expectedVictim.key == node.key, expectedVictim.cost == node.cost else {
                    mismatch = true
                    return true
                }
                victimIndex += 1
                releasedCost += node.cost
                return releasedCost >= requiredReleaseCost
            }
            let visited = node.visitedEpoch == visitEpoch
            let provisionalVisited = visited
                && expectedSnapshot.provisionalResidentLeases[node.key]?.matches(
                    identity: node,
                    incarnation: node.incarnation
                ) == true
            if visited && !provisionalVisited {
                ordinaryVisitedSeen = true
                return false
            }
            if ordinaryVisitedSeen { coldAfterOrdinaryVisited = true }
            effectiveColdRemaining -= 1
            if effectiveColdRemaining < 0 {
                mismatch = true
                return true
            }
            if provisionalVisited {
                guard revocationIndex < expected.provisionalRevocations.count,
                    expected.provisionalRevocations[revocationIndex] == node.key
                else {
                    mismatch = true
                    return true
                }
                revocationIndex += 1
            }
            guard victimIndex < expected.victims.count else {
                mismatch = true
                return true
            }
            let expectedVictim = expected.victims[victimIndex]
            guard expectedVictim.key == node.key, expectedVictim.cost == node.cost else {
                mismatch = true
                return true
            }
            victimIndex += 1
            releasedCost += node.cost
            if releasedCost >= requiredReleaseCost { return true }
            if !ordinaryVisitedSeen, effectiveColdRemaining == 0 {
                prefixEpochResetApplied = true
            }
            return false
        }

        var cursor: Node? = effectiveHand
        while let node = cursor {
            if matchFirstRevolution(node) { break }
            cursor = node.next
        }
        if !mismatch,
            releasedCost < requiredReleaseCost,
            effectiveHand !== leastRecent
        {
            cursor = leastRecent
            while let node = cursor, node !== effectiveHand {
                if matchFirstRevolution(node) { break }
                cursor = node.next
            }
        }
        if mismatch { return false }

        var epochResetCount = prefixEpochResetApplied ? 1 : 0
        if releasedCost < requiredReleaseCost, !prefixEpochResetApplied {
            epochResetCount = ordinaryVisitedSeen && !coldAfterOrdinaryVisited ? 1 : 0

            func matchSecondRevolution(_ node: Node) -> Bool {
                guard consumeInspection() else {
                    mismatch = true
                    return true
                }
                let visited = node.visitedEpoch == visitEpoch
                let provisionalVisited = visited
                    && expectedSnapshot.provisionalResidentLeases[node.key]?.matches(
                        identity: node,
                        incarnation: node.incarnation
                    ) == true
                guard visited && !provisionalVisited else { return false }
                guard victimIndex < expected.victims.count else {
                    mismatch = true
                    return true
                }
                let expectedVictim = expected.victims[victimIndex]
                guard expectedVictim.key == node.key, expectedVictim.cost == node.cost else {
                    mismatch = true
                    return true
                }
                victimIndex += 1
                releasedCost += node.cost
                return releasedCost >= requiredReleaseCost
            }

            cursor = effectiveHand
            while let node = cursor {
                if matchSecondRevolution(node) { break }
                cursor = node.next
            }
            if !mismatch,
                releasedCost < requiredReleaseCost,
                effectiveHand !== leastRecent
            {
                cursor = leastRecent
                while let node = cursor, node !== effectiveHand {
                    if matchSecondRevolution(node) { break }
                    cursor = node.next
                }
            }
        }

        return !mismatch
            && victimIndex == expected.victims.count
            && revocationIndex == expected.provisionalRevocations.count
            && releasedCost == expected.releasedCost
            && epochResetCount == expected.fullVisitedEpochResetCount
    }
}
