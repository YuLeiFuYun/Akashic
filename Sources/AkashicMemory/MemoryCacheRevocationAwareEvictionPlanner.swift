import Foundation

package struct MemoryCacheRevocationAwareResident<Key: Sendable>: Sendable {
    package let key: Key
    package let cost: Int
    package let visited: Bool
    package let provisionalVisited: Bool

    package init(
        key: Key,
        cost: Int,
        visited: Bool,
        provisionalVisited: Bool
    ) {
        self.key = key
        self.cost = cost
        self.visited = visited
        self.provisionalVisited = provisionalVisited
    }
}

package struct MemoryCacheRevocationAwareVictim<Key: Sendable>: Sendable {
    package let key: Key
    package let cost: Int

    package init(key: Key, cost: Int) {
        self.key = key
        self.cost = cost
    }
}

package struct MemoryCacheRevocationAwareEvictionPlan<Key: Sendable>: Sendable {
    package let victims: [MemoryCacheRevocationAwareVictim<Key>]
    package let provisionalRevocations: [Key]
    package let releasedCost: Int
    package let fullVisitedEpochResetCount: Int
    package let inspectedSlotCount: Int

    package init(
        victims: [MemoryCacheRevocationAwareVictim<Key>],
        provisionalRevocations: [Key],
        releasedCost: Int,
        fullVisitedEpochResetCount: Int,
        inspectedSlotCount: Int
    ) {
        self.victims = victims
        self.provisionalRevocations = provisionalRevocations
        self.releasedCost = releasedCost
        self.fullVisitedEpochResetCount = fullVisitedEpochResetCount
        self.inspectedSlotCount = inspectedSlotCount
    }
}

/// Weak resident identity bound to one cache-node incarnation. The weak reference prevents an
/// optimistic admission snapshot from retaining an evicted value merely to defend against ABA;
/// same-node replacement is distinguished by `incarnation`, while remove/reinsert uses a different
/// object identity and the old weak reference may safely become nil.
package final class MemoryCacheRevocationAwareResidentLease<Key: Hashable & Sendable>:
    @unchecked Sendable
{
    package let key: Key
    package let incarnation: UInt64
    private weak var identity: AnyObject?

    package init(key: Key, identity: AnyObject, incarnation: UInt64) {
        self.key = key
        self.identity = identity
        self.incarnation = incarnation
    }

    package func matches(identity candidate: AnyObject, incarnation: UInt64) -> Bool {
        guard self.incarnation == incarnation, let identity else { return false }
        return identity === candidate
    }
}

/// Package-only optimistic observation token for revocation-aware admission research. Besides the
/// structural plan, the token binds the normalized incoming cost and weak resident incarnations for
/// provisional protection so commit cannot accidentally validate different pressure inputs or let a
/// stale provisional lease transfer to a same-key replacement.
package struct MemoryCacheRevocationAwareEvictionSnapshot<Key: Hashable & Sendable>: Sendable {
    package let normalizedIncomingCost: Int
    package let evictionStateVersion: UInt64?
    package let maximumValidationInspectedSlotCount: Int?
    package let provisionalResidentLeases: [Key: MemoryCacheRevocationAwareResidentLease<Key>]
    package let plan: MemoryCacheRevocationAwareEvictionPlan<Key>

    package init(
        normalizedIncomingCost: Int,
        evictionStateVersion: UInt64?,
        maximumValidationInspectedSlotCount: Int? = nil,
        provisionalResidentLeases: [Key: MemoryCacheRevocationAwareResidentLease<Key>],
        plan: MemoryCacheRevocationAwareEvictionPlan<Key>
    ) {
        self.normalizedIncomingCost = normalizedIncomingCost
        self.evictionStateVersion = evictionStateVersion
        self.maximumValidationInspectedSlotCount = maximumValidationInspectedSlotCount
        self.provisionalResidentLeases = provisionalResidentLeases
        self.plan = plan
    }
}

package enum MemoryCacheRevocationAwareSnapshotLimitReason: String, Sendable {
    case provisionalLeaseCount
    case victimCount
    case inspectedSlotCount
}

/// Resource-bounded structural observation. A limited result never contains a partial executable
/// snapshot: callers may choose a separately specified fallback policy, but cannot accidentally
/// commit a truncated victim trace as if it were exact.
package struct MemoryCacheRevocationAwareBoundedSnapshotResult<Key: Hashable & Sendable>: Sendable {
    package let snapshot: MemoryCacheRevocationAwareEvictionSnapshot<Key>?
    package let limitReason: MemoryCacheRevocationAwareSnapshotLimitReason?
    package let provisionalInputCount: Int
    package let provisionalLeaseCount: Int
    package let victimCount: Int
    package let inspectedSlotCount: Int

    package init(
        snapshot: MemoryCacheRevocationAwareEvictionSnapshot<Key>?,
        limitReason: MemoryCacheRevocationAwareSnapshotLimitReason?,
        provisionalInputCount: Int,
        provisionalLeaseCount: Int,
        victimCount: Int,
        inspectedSlotCount: Int
    ) {
        self.snapshot = snapshot
        self.limitReason = limitReason
        self.provisionalInputCount = provisionalInputCount
        self.provisionalLeaseCount = provisionalLeaseCount
        self.victimCount = victimCount
        self.inspectedSlotCount = inspectedSlotCount
    }
}

package struct MemoryCacheRevocationAwarePlanBuildResult<Key: Hashable & Sendable>: Sendable {
    package let plan: MemoryCacheRevocationAwareEvictionPlan<Key>?
    package let limitReason: MemoryCacheRevocationAwareSnapshotLimitReason?
    package let victimCount: Int
    package let inspectedSlotCount: Int

    package init(
        plan: MemoryCacheRevocationAwareEvictionPlan<Key>?,
        limitReason: MemoryCacheRevocationAwareSnapshotLimitReason?,
        victimCount: Int,
        inspectedSlotCount: Int
    ) {
        self.plan = plan
        self.limitReason = limitReason
        self.victimCount = victimCount
        self.inspectedSlotCount = inspectedSlotCount
    }
}

package enum MemoryCacheRevocationAwareValidationMode: String, Sendable {
    case inputRejected
    case versionFastPath
    case exactStreaming
    case validationLimited
}

package struct MemoryCacheRevocationAwareCommitResult: Sendable {
    package let accepted: Bool
    package let validationMode: MemoryCacheRevocationAwareValidationMode
    package let validationInspectedSlotCount: Int

    package init(
        accepted: Bool,
        validationMode: MemoryCacheRevocationAwareValidationMode,
        validationInspectedSlotCount: Int = 0
    ) {
        self.accepted = accepted
        self.validationMode = validationMode
        self.validationInspectedSlotCount = validationInspectedSlotCount
    }
}

package enum MemoryCacheDeferredRetirementDisposition: String, Sendable {
    case replaced
    case ineligible
    case backpressured
}

package enum MemoryCacheDeferredRetirementMode: String, Sendable {
    case releaseBeforeReturn
    case queueForExplicitDrain
}

/// Package-only accounting for retired logical cache generations whose values/nodes are still
/// physically alive. Cost is the cache's normalized logical cost, not allocator or RSS bytes.
package struct MemoryCacheRetirementDebt: Hashable, Sendable {
    package let queuedGenerationCount: Int
    package let inFlightGenerationCount: Int
    package let itemCount: Int
    package let costBytes: Int

    package var generationCount: Int { queuedGenerationCount + inFlightGenerationCount }

    package init(
        queuedGenerationCount: Int,
        inFlightGenerationCount: Int,
        itemCount: Int,
        costBytes: Int
    ) {
        self.queuedGenerationCount = queuedGenerationCount
        self.inFlightGenerationCount = inFlightGenerationCount
        self.itemCount = itemCount
        self.costBytes = costBytes
    }
}

/// Package-only result for the exact-full-cost deferred-retirement research path. `backpressured`
/// is intentionally distinct from `ineligible`: the former means the logical operation is eligible
/// but admitting it would exceed the caller-selected bound on simultaneously retiring generations.
package struct MemoryCacheDeferredRetirementAttempt: Sendable {
    package let disposition: MemoryCacheDeferredRetirementDisposition
    package let summary: MemoryCacheRemovalSummary?

    package init(
        disposition: MemoryCacheDeferredRetirementDisposition,
        summary: MemoryCacheRemovalSummary?
    ) {
        self.disposition = disposition
        self.summary = summary
    }
}

package enum MemoryCacheAllVisitedSurvivorDisposition: String, Sendable {
    case replaced
    case ineligible
    case retirementBackpressured
    case survivorLimit
    case inspectionLimit
    case epochNormalizationRequired
}

/// Package-only result for the all-visited survivor-oriented bulk replacement candidate. Counts are
/// exact for the attempted linearization point and deliberately describe structural work rather than
/// physical memory: host cache cost is not an allocator-byte contract.
package struct MemoryCacheAllVisitedSurvivorAttempt: Sendable {
    package let disposition: MemoryCacheAllVisitedSurvivorDisposition
    package let summary: MemoryCacheRemovalSummary?
    package let survivorCount: Int
    package let survivorCost: Int
    package let inspectedSlotCount: Int

    package init(
        disposition: MemoryCacheAllVisitedSurvivorDisposition,
        summary: MemoryCacheRemovalSummary?,
        survivorCount: Int,
        survivorCost: Int,
        inspectedSlotCount: Int
    ) {
        self.disposition = disposition
        self.summary = summary
        self.survivorCount = survivorCount
        self.survivorCost = survivorCost
        self.inspectedSlotCount = inspectedSlotCount
    }
}

/// Package-only research candidate for victim-aware admission.
///
/// This computes the final SIEVE eviction trace directly. A provisional visit that the restart
/// fixed-point would eventually revoke is treated as cold when the final hand reaches it. Ordinary
/// visits are only simulated-cleared. No intermediate eviction trace is restarted.
///
/// The representation is intentionally a bounded shadow snapshot rather than the production hot
/// path. The final trace needs at most two forward sweeps over hand order: the first consumes
/// original-cold/provisional victims while ordinary visits spend their second chance; only if that
/// does not release enough cost does the second sweep evict those now-cold ordinary survivors.
/// No per-resident alive/visited shadow arrays or intermediate trace restarts are required.
package enum MemoryCacheRevocationAwareEvictionPlanner {
    package static func plan<Key: Sendable>(
        residentsFromHand: [MemoryCacheRevocationAwareResident<Key>],
        requiredReleaseCost: Int
    ) -> MemoryCacheRevocationAwareEvictionPlan<Key> {
        guard requiredReleaseCost > 0, !residentsFromHand.isEmpty else {
            return .init(
                victims: [],
                provisionalRevocations: [],
                releasedCost: 0,
                fullVisitedEpochResetCount: 0,
                inspectedSlotCount: 0
            )
        }

        var victims: [MemoryCacheRevocationAwareVictim<Key>] = []
        var revocations: [Key] = []
        var releasedCost = 0
        var epochResetCount = 0
        var inspectedSlotCount = 0

        // First hand revolution. Ordinary visited residents spend their second chance and remain;
        // original-cold residents are victims immediately. A provisional visit is the fixed-point
        // exception: explicitly revoke it and make that same resident the cold victim rather than
        // restarting the whole trace.
        var ordinaryVisitedSeen = false
        var coldAfterOrdinaryVisited = false
        for resident in residentsFromHand {
            inspectedSlotCount += 1
            if resident.visited && !resident.provisionalVisited {
                ordinaryVisitedSeen = true
                continue
            }

            if ordinaryVisitedSeen { coldAfterOrdinaryVisited = true }
            if resident.visited && resident.provisionalVisited {
                revocations.append(resident.key)
            }
            victims.append(.init(key: resident.key, cost: resident.cost))
            releasedCost += resident.cost
            if releasedCost >= requiredReleaseCost {
                return .init(
                    victims: victims,
                    provisionalRevocations: revocations,
                    releasedCost: releasedCost,
                    fullVisitedEpochResetCount: 0,
                    inspectedSlotCount: inspectedSlotCount
                )
            }
        }

        // The production O(1) all-visited shortcut can also appear after a leading cold/provisional
        // prefix has been removed. It occurs exactly when some ordinary-visited survivor exists and
        // no cold/provisional resident appears after the first ordinary visit. If a cold resident is
        // encountered after an ordinary visit, that ordinary visit was already cleared while the hand
        // searched for the cold victim and prevents any later all-visited reset in this insertion.
        if ordinaryVisitedSeen && !coldAfterOrdinaryVisited { epochResetCount = 1 }

        // Second revolution only evicts the original ordinary-visited class. Every original-cold or
        // provisional resident was selected on the first revolution when execution reaches here, so
        // immutable input state itself encodes survivor membership without an alive bitset.
        for resident in residentsFromHand {
            inspectedSlotCount += 1
            guard resident.visited && !resident.provisionalVisited else { continue }
            victims.append(.init(key: resident.key, cost: resident.cost))
            releasedCost += resident.cost
            if releasedCost >= requiredReleaseCost { break }
        }

        return .init(
            victims: victims,
            provisionalRevocations: revocations,
            releasedCost: releasedCost,
            fullVisitedEpochResetCount: epochResetCount,
            inspectedSlotCount: inspectedSlotCount
        )
    }
}
