import Foundation

extension FileBlobStoreReadIO {
    func linearBypassIndexLocked(
        maximumCandidateBytes: Int,
        cancelled: inout [Request]
    ) -> Int? {
        precondition(maximumCandidateBytes > 0)
        bypassSearches = saturatingAdd(bypassSearches, 1)
        var bypassIndex: Int?
        var examined = 0
        var index = pendingHead + 1
        while index < pending.count {
            examined += 1
            guard let candidate = pending[index] else {
                index += 1
                continue
            }
            if candidate.token.isCancelled {
                clearBypassExactIndexSlotLocked(index)
                pending[index] = nil
                pendingIndexByToken.removeValue(forKey: ObjectIdentifier(candidate.token))
                pendingCount -= 1
                cancelled.append(candidate)
                index += 1
                continue
            }
            if max(1, candidate.expectedBytes) <= maximumCandidateBytes,
                requestFitsLocked(candidate)
            {
                bypassIndex = index
                break
            }
            index += 1
        }
        bypassSlotsExamined = saturatingAdd(bypassSlotsExamined, examined)
        maximumSlotsExaminedPerSearch = max(maximumSlotsExaminedPerSearch, examined)
        if bypassIndex == nil {
            failedBypassSearches = saturatingAdd(failedBypassSearches, 1)
        }
        return bypassIndex
    }

    func sizeIndexedBypassIndexLocked(
        maximumCandidateBytes: Int,
        cancelled: inout [Request]
    ) -> Int? {
        precondition(maximumCandidateBytes > 0)
        bypassIndexSearches = saturatingAdd(bypassIndexSearches, 1)

        var bestIndex: Int?
        var bestClassIndex: Int?
        var classesExamined = 0
        for classIndex in 0..<bypassSizeIndex.classCount {
            if bypassSizeIndex.upperBound(for: classIndex) > maximumCandidateBytes { break }
            classesExamined += 1
            guard let tokenID = bypassSizeIndex.frontToken(in: classIndex) else { continue }
            guard let slot = pendingIndexByToken[tokenID],
                slot > pendingHead,
                slot < pending.count,
                let candidate = pending[slot]
            else {
                bypassSizeIndex.discardFront(in: classIndex)
                bypassIndexStaleTokensDiscarded = saturatingAdd(
                    bypassIndexStaleTokensDiscarded,
                    1
                )
                continue
            }
            if candidate.token.isCancelled {
                pending[slot] = nil
                pendingIndexByToken.removeValue(forKey: tokenID)
                pendingCount -= 1
                cancelled.append(candidate)
                bypassSizeIndex.discardFront(in: classIndex)
                bypassIndexStaleTokensDiscarded = saturatingAdd(
                    bypassIndexStaleTokensDiscarded,
                    1
                )
                continue
            }
            if bestIndex.map({ slot < $0 }) ?? true {
                bestIndex = slot
                bestClassIndex = classIndex
            }
        }
        bypassIndexClassesExamined = saturatingAdd(
            bypassIndexClassesExamined,
            classesExamined
        )
        maximumBypassIndexClassesPerSearch = max(
            maximumBypassIndexClassesPerSearch,
            classesExamined
        )
        guard let bestIndex,
            let bestClassIndex,
            let candidate = pending[bestIndex],
            max(1, candidate.expectedBytes) <= maximumCandidateBytes,
            requestFitsLocked(candidate)
        else { return nil }
        bypassSizeIndex.discardFront(in: bestClassIndex)
        return bestIndex
    }

    func exactIndexedBypassIndexLocked(
        maximumCandidateBytes: Int,
        cancelled: inout [Request]
    ) -> Int? {
        precondition(maximumCandidateBytes > 0)
        bypassExactIndexSearches = saturatingAdd(bypassExactIndexSearches, 1)
        var searchNodes = 0

        while pendingHead + 1 < pending.count {
            let result = bypassExactIndex.firstSlot(
                startingAt: pendingHead + 1,
                slotCount: pending.count,
                maximumBytes: maximumCandidateBytes
            )
            searchNodes = saturatingAdd(searchNodes, result.nodesExamined)
            guard let slot = result.slot else { break }

            guard slot > pendingHead,
                slot < pending.count,
                let candidate = pending[slot]
            else {
                // The primary pending array is authoritative. Repair any disagreement eagerly and
                // retry the exact search rather than returning a stale physical slot.
                clearBypassExactIndexSlotLocked(slot)
                continue
            }

            let tokenID = ObjectIdentifier(candidate.token)
            if candidate.token.isCancelled {
                clearBypassExactIndexSlotLocked(slot)
                pending[slot] = nil
                pendingIndexByToken.removeValue(forKey: tokenID)
                pendingCount -= 1
                cancelled.append(candidate)
                continue
            }

            let bytes = max(1, candidate.expectedBytes)
            guard bytes <= maximumCandidateBytes,
                requestFitsLocked(candidate)
            else {
                preconditionFailure("exact read-bypass index returned a non-fitting live request")
            }

            bypassExactIndexNodesExamined = saturatingAdd(
                bypassExactIndexNodesExamined,
                searchNodes
            )
            maximumBypassExactIndexNodesPerSearch = max(
                maximumBypassExactIndexNodesPerSearch,
                searchNodes
            )
            return slot
        }

        bypassExactIndexNodesExamined = saturatingAdd(
            bypassExactIndexNodesExamined,
            searchNodes
        )
        maximumBypassExactIndexNodesPerSearch = max(
            maximumBypassExactIndexNodesPerSearch,
            searchNodes
        )
        return nil
    }

    func appendBypassSizeClassTokenLocked(_ request: Request) {
        guard maximumBypassesPerBlockedHead > 0,
            bypassLookupMode == .conservativeSizeIndex
        else { return }
        bypassSizeIndex.append(
            token: request.token,
            expectedBytes: request.expectedBytes
        )
    }

    func setBypassExactIndexSlotLocked(_ slot: Int, expectedBytes: Int) {
        guard maximumBypassesPerBlockedHead > 0,
            bypassLookupMode == .exactSlotMinIndex
        else { return }
        bypassExactIndexPointUpdates = saturatingAdd(bypassExactIndexPointUpdates, 1)
        let writes = bypassExactIndex.update(slot: slot, expectedBytes: expectedBytes)
        bypassExactIndexNodeWrites = saturatingAdd(bypassExactIndexNodeWrites, writes)
        maximumPendingBypassExactIndexScalarSlots = max(
            maximumPendingBypassExactIndexScalarSlots,
            bypassExactIndex.scalarSlots
        )
    }

    func clearBypassExactIndexSlotLocked(_ slot: Int) {
        guard maximumBypassesPerBlockedHead > 0,
            bypassLookupMode == .exactSlotMinIndex
        else { return }
        bypassExactIndexPointUpdates = saturatingAdd(bypassExactIndexPointUpdates, 1)
        let writes = bypassExactIndex.update(slot: slot, expectedBytes: nil)
        bypassExactIndexNodeWrites = saturatingAdd(bypassExactIndexNodeWrites, writes)
    }

    func rebuildBypassSizeClassIndexLocked() {
        guard maximumBypassesPerBlockedHead > 0,
            bypassLookupMode == .conservativeSizeIndex
        else {
            bypassSizeIndex.rebuild([])
            return
        }
        bypassSizeIndex.rebuild(
            pending.compactMap { request in
                request.map { ($0.token as AnyObject, $0.expectedBytes) }
            }
        )
    }

    func rebuildBypassExactIndexLocked() {
        guard maximumBypassesPerBlockedHead > 0,
            bypassLookupMode == .exactSlotMinIndex
        else {
            _ = bypassExactIndex.rebuild([])
            return
        }
        let expectedBytes = pending.map { request -> Int? in
            guard let request, !request.token.isCancelled else { return nil }
            return request.expectedBytes
        }
        bypassExactIndexRebuilds = saturatingAdd(bypassExactIndexRebuilds, 1)
        let writes = bypassExactIndex.rebuild(expectedBytes)
        bypassExactIndexRebuildNodeWrites = saturatingAdd(
            bypassExactIndexRebuildNodeWrites,
            writes
        )
        maximumPendingBypassExactIndexScalarSlots = max(
            maximumPendingBypassExactIndexScalarSlots,
            bypassExactIndex.scalarSlots
        )
    }

    func bypassByteLimitLocked(for head: Request) -> Int {
        let availableBytes = activeBytes >= maximumInFlightBytes
            ? 0
            : maximumInFlightBytes - activeBytes
        guard availableBytes > 0 else { return 0 }
        switch bypassAdmissionMode {
        case .currentCapacity:
            return availableBytes
        case .structuralHeadReservation:
            let headBytes = max(1, head.expectedBytes)
            guard headBytes <= maximumInFlightBytes else { return 0 }
            let headResidualBound = maximumInFlightBytes - headBytes
            // This helper is reached only for a byte-blocked normal head. Keep the invariant
            // explicit because a worker-blocked head is handled before bypass search.
            precondition(activeBytes > headResidualBound)
            precondition(boundedActiveBytesByToken.count == activeCount)
            precondition(boundedActiveBytesByToken.values.reduce(0, +) == activeBytes)
            let activeSizes = Array(boundedActiveBytesByToken.values)
            var maximumResidual = 0
            for mask in 0..<(1 << activeSizes.count) {
                var residual = 0
                for index in activeSizes.indices where mask & (1 << index) != 0 {
                    residual += activeSizes[index]
                }
                if residual <= headResidualBound {
                    maximumResidual = max(maximumResidual, residual)
                }
            }
            let structuralMargin = headResidualBound - maximumResidual
            precondition(structuralMargin >= 0)
            return min(availableBytes, structuralMargin)
        }
    }
}
