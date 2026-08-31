import Foundation

extension MemoryCache {
    package func resourceProbeTryInsertAllVisitedUsingBoundedSurvivors(
        _ value: Value,
        for key: Key,
        cost: Int,
        maximumSurvivorCount: Int,
        maximumInspectedSlotCount: Int,
        maximumConcurrentRetirements: Int,
        retirementMode: MemoryCacheDeferredRetirementMode = .releaseBeforeReturn,
        afterLogicalSwapBeforeRetirement: () -> Void = {}
    ) -> MemoryCacheAllVisitedSurvivorAttempt {
        let survivorLimit = max(0, maximumSurvivorCount)
        let inspectionLimit = max(0, maximumInspectedSlotCount)
        let retirementLimit = max(0, maximumConcurrentRetirements)
        var retiredEntries: [Key: Node]? = nil
        var reservedRetirement = false
        var queuedRetirement = false

        let attempt = atomic { () -> MemoryCacheAllVisitedSurvivorAttempt in
            let normalizedCost = max(1, cost)
            guard normalizedCost <= costLimit,
                entries[key] == nil,
                residentCount > 0,
                visitedCount == residentCount
            else {
                return .init(
                    disposition: .ineligible,
                    summary: nil,
                    survivorCount: 0,
                    survivorCost: 0,
                    inspectedSlotCount: 0
                )
            }

            let maximumExistingCost = costLimit - normalizedCost
            guard totalCost > maximumExistingCost else {
                return .init(
                    disposition: .ineligible,
                    summary: nil,
                    survivorCount: residentCount,
                    survivorCost: totalCost,
                    inspectedSlotCount: 0
                )
            }
            guard visitEpoch != .max else {
                return .init(
                    disposition: .epochNormalizationRequired,
                    summary: nil,
                    survivorCount: 0,
                    survivorCost: 0,
                    inspectedSlotCount: 0
                )
            }

            guard let effectiveHand = sieveHand ?? leastRecent,
                let currentMostRecent = mostRecent
            else {
                preconditionFailure("nonempty cache must have hand and most-recent resident")
            }

            var survivorsReverse: [Node] = []
            survivorsReverse.reserveCapacity(min(survivorLimit, residentCount))
            var survivorCost = 0
            var inspectedSlotCount = 0
            var candidate: Node? = effectiveHand.previous ?? currentMostRecent
            var remainingCandidates = residentCount

            while maximumExistingCost > survivorCost,
                remainingCandidates > 0,
                let current = candidate
            {
                guard inspectedSlotCount < inspectionLimit else {
                    return .init(
                        disposition: .inspectionLimit,
                        summary: nil,
                        survivorCount: survivorsReverse.count,
                        survivorCost: survivorCost,
                        inspectedSlotCount: inspectedSlotCount
                    )
                }
                inspectedSlotCount += 1

                let remainingBudget = maximumExistingCost - survivorCost
                guard current.cost <= remainingBudget else { break }
                guard survivorsReverse.count < survivorLimit else {
                    return .init(
                        disposition: .survivorLimit,
                        summary: nil,
                        survivorCount: survivorsReverse.count,
                        survivorCost: survivorCost,
                        inspectedSlotCount: inspectedSlotCount
                    )
                }

                survivorsReverse.append(current)
                survivorCost += current.cost
                remainingCandidates -= 1
                if survivorCost == maximumExistingCost { break }
                candidate = current.previous ?? currentMostRecent
            }

            // Eviction is required, so the backward suffix must stop before consuming the complete
            // resident ring. Reaching every resident would contradict totalCost > maximumExistingCost.
            precondition(survivorsReverse.count < residentCount)
            guard retirementGenerationCountLocked() < retirementLimit,
                retirementMode != .queueForExplicitDrain || queuedRetirementEntries == nil
            else {
                return .init(
                    disposition: .retirementBackpressured,
                    summary: nil,
                    survivorCount: survivorsReverse.count,
                    survivorCost: survivorCost,
                    inspectedSlotCount: inspectedSlotCount
                )
            }

            let survivorForwardCircular = Array(survivorsReverse.reversed())
            var survivorFIFO: [Node] = []
            survivorFIFO.reserveCapacity(survivorForwardCircular.count)
            if let currentLeastRecent = leastRecent,
                let leastIndex = survivorForwardCircular.firstIndex(where: {
                    $0 === currentLeastRecent
                })
            {
                for offset in 0..<survivorForwardCircular.count {
                    survivorFIFO.append(
                        survivorForwardCircular[
                            (leastIndex + offset) % survivorForwardCircular.count
                        ]
                    )
                }
            } else {
                survivorFIFO = survivorForwardCircular
            }

            var nextEntries: [Key: Node] = [:]
            nextEntries.reserveCapacity(survivorFIFO.count + 1)
            for survivor in survivorFIFO { nextEntries[survivor.key] = survivor }
            let incoming = Node(
                key: key,
                value: value,
                cost: normalizedCost,
                previous: survivorFIFO.last
            )
            nextEntries[key] = incoming

            let summary = MemoryCacheRemovalSummary(
                itemCount: residentCount - survivorFIFO.count,
                costBytes: totalCost - survivorCost
            )
            retiredEntries = entries

            for index in survivorFIFO.indices {
                survivorFIFO[index].previous = index == survivorFIFO.startIndex
                    ? nil
                    : survivorFIFO[survivorFIFO.index(before: index)]
                let nextIndex = survivorFIFO.index(after: index)
                survivorFIFO[index].next = nextIndex == survivorFIFO.endIndex
                    ? incoming
                    : survivorFIFO[nextIndex]
            }
            incoming.previous = survivorFIFO.last
            incoming.next = nil

            entries = nextEntries
            leastRecent = survivorFIFO.first ?? incoming
            mostRecent = incoming
            sieveHand = survivorForwardCircular.first
            totalCost = survivorCost + normalizedCost
            residentCount = survivorFIFO.count + 1
            // `visitEpoch == .max` was rejected above, so this is the same O(1) epoch transition
            // classic SIEVE performs before selecting the first all-visited victim.
            visitEpoch += 1
            visitedCount = 0
            switch retirementMode {
            case .releaseBeforeReturn:
                beginRetirementInFlightLocked(summary)
                reservedRetirement = true
            case .queueForExplicitDrain:
                // `entries` now owns every survivor through a fresh dictionary. The old dictionary
                // is uniquely held by `retiredEntries`; removing only the bounded survivors leaves
                // an exact victim-only queued generation without destroying those survivor nodes.
                for survivor in survivorFIFO {
                    precondition(retiredEntries?.removeValue(forKey: survivor.key) != nil)
                }
                precondition(retiredEntries?.count == summary.itemCount)
                queuedRetirementEntries = retiredEntries
                queuedRetirementItemCount = summary.itemCount
                queuedRetirementCost = summary.costBytes
                queuedRetirement = true
            }
            markEvictionStateChangedLocked()
            afterLogicalSwapBeforeRetirement()

            return .init(
                disposition: .replaced,
                summary: summary,
                survivorCount: survivorFIFO.count,
                survivorCost: survivorCost,
                inspectedSlotCount: inspectedSlotCount
            )
        }

        if queuedRetirement {
            retiredEntries = nil
            return attempt
        }
        guard reservedRetirement else { return attempt }
        withExtendedLifetime(retiredEntries) {}
        retiredEntries = nil
        atomic { finishRetirementInFlightLocked(attempt.summary!) }
        return attempt
    }

    /// Exact package-only accounting for retired logical cache generations whose values/nodes are
    /// still physically alive. `costBytes` is normalized cache cost, not allocator/RSS bytes.
    package func resourceProbeRetirementDebtSnapshot() -> MemoryCacheRetirementDebt {
        atomic {
            let itemTotal = deferredRetirementInFlightItemCount.addingReportingOverflow(
                queuedRetirementItemCount
            )
            let costTotal = deferredRetirementInFlightCost.addingReportingOverflow(
                queuedRetirementCost
            )
            precondition(!itemTotal.overflow && !costTotal.overflow)
            return .init(
                queuedGenerationCount: queuedRetirementEntries == nil ? 0 : 1,
                inFlightGenerationCount: deferredRetirementInFlight,
                itemCount: itemTotal.partialValue,
                costBytes: costTotal.partialValue
            )
        }
    }

    /// Moves the single queued retirement generation into an in-flight drain under the cache mutex,
    /// then destroys its values/nodes after unlock. Re-entrant bounded bulk mutation observes the
    /// in-flight generation and backpressures when the configured generation limit is one.
    @discardableResult
    package func resourceProbeDrainQueuedRetirement() -> MemoryCacheRemovalSummary {
        var retiredEntries: [Key: Node]? = nil
        var summary = MemoryCacheRemovalSummary(itemCount: 0, costBytes: 0)
        var draining = false
        atomic {
            guard let queuedRetirementEntries else { return }
            retiredEntries = queuedRetirementEntries
            summary = .init(
                itemCount: queuedRetirementItemCount,
                costBytes: queuedRetirementCost
            )
            self.queuedRetirementEntries = nil
            queuedRetirementItemCount = 0
            queuedRetirementCost = 0
            beginRetirementInFlightLocked(summary)
            draining = true
        }
        guard draining else { return summary }

        withExtendedLifetime(retiredEntries) {}
        retiredEntries = nil
        atomic { finishRetirementInFlightLocked(summary) }
        return summary
    }

}
