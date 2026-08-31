import AkashicCore
import Dispatch
import Foundation

/// Bounded blocking-I/O scheduler for verified payload reads. Strict FIFO remains the default;
/// package-only research bypasses retain hard worker/byte bounds and token-scoped fairness credit.
package final class FileBlobStoreReadIO: @unchecked Sendable {
    package static let maximumConcurrentReads = 4
    package static let maximumDefaultInFlightBytes = 64 * 1024 * 1024
    package static let maximumDefaultPendingReads = 1_024

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "dev.akashic.file-blob-store.read", qos: .userInitiated, attributes: .concurrent
    )
    private let operations: FileBlobStoreReadOperations
    private let maximumConcurrentReads: Int
    let maximumInFlightBytes: Int
    private let maximumPendingReads: Int
    private let maximumPendingStorageSlots: Int
    let maximumBypassesPerBlockedHead: Int
    let bypassLookupMode: FileBlobStoreReadBypassLookupMode
    let bypassAdmissionMode: FileBlobStoreReadBypassAdmissionMode
    var activeCount = 0
    var activeBytes = 0
    // Individual active sizes are needed only by the opt-in bounded-bypass research path. The
    // hard worker bound keeps this dictionary at <=4 entries; strict-FIFO default admissions do
    // not populate it.
    var boundedActiveBytesByToken: [ObjectIdentifier: Int] = [:]
    var pending: [Request?] = []
    var pendingHead = 0
    var pendingCount = 0
    // Direct token-to-slot lookup keeps pending cancellation O(1); compaction rebuilds slot indexes.
    var pendingIndexByToken: [ObjectIdentifier: Int] = [:]
    private var blockedHeadTokenID: ObjectIdentifier?
    private var remainingBypassesForBlockedHead = 0
    var bypassSearches = 0
    var bypassSlotsExamined = 0
    var maximumSlotsExaminedPerSearch = 0
    private var successfulBypasses = 0
    var failedBypassSearches = 0
    var bypassIndexSearches = 0
    var bypassIndexClassesExamined = 0
    var maximumBypassIndexClassesPerSearch = 0
    var bypassIndexStaleTokensDiscarded = 0
    var bypassSizeIndex = FileBlobStoreReadBypassSizeIndex()
    var bypassExactIndexSearches = 0
    var bypassExactIndexNodesExamined = 0
    var maximumBypassExactIndexNodesPerSearch = 0
    var bypassExactIndexPointUpdates = 0
    var bypassExactIndexNodeWrites = 0
    var bypassExactIndexRebuilds = 0
    var bypassExactIndexRebuildNodeWrites = 0
    var maximumPendingBypassExactIndexScalarSlots = 0
    var bypassExactIndex = FileBlobStoreReadBypassExactIndex()

    package init(
        maximumConcurrentReads: Int = FileBlobStoreReadIO.maximumConcurrentReads,
        maximumInFlightBytes: Int = FileBlobStoreReadIO.maximumDefaultInFlightBytes,
        maximumPendingReads: Int = FileBlobStoreReadIO.maximumDefaultPendingReads,
        maximumBypassesPerBlockedHead: Int = 0,
        bypassLookupMode: FileBlobStoreReadBypassLookupMode = .conservativeSizeIndex,
        bypassAdmissionMode: FileBlobStoreReadBypassAdmissionMode = .currentCapacity,
        operations: FileBlobStoreReadOperations = .system
    ) {
        let normalizedConcurrentReads = max(
            1,
            min(Self.maximumConcurrentReads, maximumConcurrentReads)
        )
        self.maximumConcurrentReads = normalizedConcurrentReads
        self.maximumInFlightBytes = max(1, maximumInFlightBytes)
        let normalizedPendingReads = max(1, maximumPendingReads)
        self.maximumPendingReads = normalizedPendingReads
        self.maximumPendingStorageSlots = normalizedPendingReads > Int.max / 2
            ? Int.max
            : normalizedPendingReads * 2
        self.maximumBypassesPerBlockedHead = max(
            0,
            min(normalizedConcurrentReads - 1, maximumBypassesPerBlockedHead)
        )
        self.bypassLookupMode = bypassLookupMode
        self.bypassAdmissionMode = bypassAdmissionMode
        self.operations = operations
    }

    package func resourceSnapshot() -> FileBlobStoreReadSchedulerResourceSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FileBlobStoreReadSchedulerResourceSnapshot(
            activeCount: activeCount,
            activeBytes: activeBytes,
            pendingCount: pendingCount,
            pendingStorageSlots: pending.count,
            maximumPendingStorageSlots: maximumPendingStorageSlots,
            bypassSearches: bypassSearches,
            bypassSlotsExamined: bypassSlotsExamined,
            maximumSlotsExaminedPerSearch: maximumSlotsExaminedPerSearch,
            successfulBypasses: successfulBypasses,
            failedBypassSearches: failedBypassSearches,
            bypassIndexSearches: bypassIndexSearches,
            bypassIndexClassesExamined: bypassIndexClassesExamined,
            maximumBypassIndexClassesPerSearch: maximumBypassIndexClassesPerSearch,
            bypassIndexStaleTokensDiscarded: bypassIndexStaleTokensDiscarded,
            pendingBypassIndexTokenSlots: bypassSizeIndex.tokenSlots,
            maximumPendingBypassIndexTokenSlots: maximumPendingStorageSlots,
            bypassExactIndexSearches: bypassExactIndexSearches,
            bypassExactIndexNodesExamined: bypassExactIndexNodesExamined,
            maximumBypassExactIndexNodesPerSearch: maximumBypassExactIndexNodesPerSearch,
            bypassExactIndexPointUpdates: bypassExactIndexPointUpdates,
            bypassExactIndexNodeWrites: bypassExactIndexNodeWrites,
            bypassExactIndexRebuilds: bypassExactIndexRebuilds,
            bypassExactIndexRebuildNodeWrites: bypassExactIndexRebuildNodeWrites,
            pendingBypassExactIndexScalarSlots: bypassExactIndex.scalarSlots,
            maximumPendingBypassExactIndexScalarSlots: maximumPendingBypassExactIndexScalarSlots
        )
    }

    package func readVerified(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int,
        digest: BlobDigest
    ) async throws -> BoundedFileReadResult {
        do {
            return try await readVerifiedForStore(
                from: url,
                maximumBytes: maximumBytes,
                expectedBytes: expectedBytes,
                digest: digest
            )
        } catch is FileBlobStoreReadSchedulingError {
            // Preserve the existing package-level scheduler contract used by resource probes/tests.
            // FileBlobStore itself uses `readVerifiedForStore` so it can distinguish availability
            // admission from physical-carrier validation before deciding whether to quarantine.
            throw AkashicError.storageUnavailable
        }
    }

    package func readVerifiedForStore(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int,
        digest: BlobDigest
    ) async throws -> BoundedFileReadResult {
        try Task.checkCancellation()
        let token = CancellationToken()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    Request(
                        url: url,
                        maximumBytes: maximumBytes,
                        expectedBytes: expectedBytes,
                        digest: digest,
                        token: token,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            token.cancel()
            cancelPending(token)
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private func enqueue(_ request: Request) {
        let drained: (ready: [Request], cancelled: [Request])
        lock.lock()
        guard pendingCount < maximumPendingReads else {
            lock.unlock()
            request.continuation.resume(
                returning: .failure(FileBlobStoreReadSchedulingError.pendingQueueFull)
            )
            return
        }
        if pending.count >= maximumPendingStorageSlots {
            compactPendingStorageLocked()
        }
        precondition(pending.count < maximumPendingStorageSlots)
        let index = pending.count
        let hadPending = pendingCount > 0
        pending.append(request)
        pendingCount += 1
        pendingIndexByToken[ObjectIdentifier(request.token)] = index
        if hadPending {
            appendBypassSizeClassTokenLocked(request)
            setBypassExactIndexSlotLocked(index, expectedBytes: request.expectedBytes)
        }
        drained = takeReadyLocked()
        lock.unlock()
        resumeCancelled(drained.cancelled)
        dispatch(drained.ready)
    }

    private func cancelPending(_ token: CancellationToken) {
        var cancelled: [Request] = []
        let ready: [Request]
        lock.lock()
        let tokenID = ObjectIdentifier(token)
        if let index = pendingIndexByToken.removeValue(forKey: tokenID),
            index >= pendingHead,
            index < pending.count,
            let request = pending[index],
            request.token === token
        {
            clearBypassExactIndexSlotLocked(index)
            pending[index] = nil
            pendingCount -= 1
            cancelled.append(request)
        }
        let drained = takeReadyLocked()
        cancelled.append(contentsOf: drained.cancelled)
        ready = drained.ready
        lock.unlock()
        resumeCancelled(cancelled)
        dispatch(ready)
    }

    private func takeReadyLocked() -> (ready: [Request], cancelled: [Request]) {
        if maximumBypassesPerBlockedHead == 0 {
            return takeReadyStrictFIFOLocked()
        }
        return takeReadyBoundedBypassLocked()
    }

    /// Exact legacy/default FIFO path. Keeping this state machine intact makes the research
    /// candidate opt-in and prevents scheduler experiments from silently changing public behavior.
    private func takeReadyStrictFIFOLocked() -> (ready: [Request], cancelled: [Request]) {
        var ready: [Request] = []
        var cancelled: [Request] = []
        while pendingHead < pending.count {
            guard let request = pending[pendingHead] else {
                pendingHead += 1
                continue
            }
            if request.token.isCancelled {
                clearBypassExactIndexSlotLocked(pendingHead)
                pending[pendingHead] = nil
                pendingIndexByToken.removeValue(forKey: ObjectIdentifier(request.token))
                pendingCount -= 1
                pendingHead += 1
                cancelled.append(request)
                continue
            }
            guard activeCount < maximumConcurrentReads else { break }
            guard requestFitsLocked(request) else { break }
            clearBypassExactIndexSlotLocked(pendingHead)
            pending[pendingHead] = nil
            pendingIndexByToken.removeValue(forKey: ObjectIdentifier(request.token))
            pendingCount -= 1
            pendingHead += 1
            activeCount += 1
            activeBytes += max(1, request.expectedBytes)
            ready.append(request)
        }
        compactPendingStorageIfNeededLocked()
        return (ready, cancelled)
    }

    private func takeReadyBoundedBypassLocked() -> (ready: [Request], cancelled: [Request]) {
        var ready: [Request] = []
        var cancelled: [Request] = []
        while pendingHead < pending.count {
            // Clear tombstones/cancelled requests only at the queue head first. A tracked blocked
            // head disappearing is the only event (besides its admission) that replenishes credit.
            while pendingHead < pending.count {
                guard let request = pending[pendingHead] else {
                    clearBlockedHeadLocked()
                    pendingHead += 1
                    continue
                }
                guard request.token.isCancelled else { break }
                let tokenID = ObjectIdentifier(request.token)
                clearBypassExactIndexSlotLocked(pendingHead)
                pending[pendingHead] = nil
                pendingIndexByToken.removeValue(forKey: tokenID)
                pendingCount -= 1
                pendingHead += 1
                if blockedHeadTokenID == tokenID { clearBlockedHeadLocked() }
                cancelled.append(request)
            }
            guard pendingHead < pending.count,
                let head = pending[pendingHead],
                activeCount < maximumConcurrentReads
            else { break }

            if requestFitsLocked(head) {
                clearBypassExactIndexSlotLocked(pendingHead)
                pending[pendingHead] = nil
                pendingIndexByToken.removeValue(forKey: ObjectIdentifier(head.token))
                pendingCount -= 1
                pendingHead += 1
                activateBoundedLocked(head)
                clearBlockedHeadLocked()
                ready.append(head)
                continue
            }

            let headID = ObjectIdentifier(head.token)
            if blockedHeadTokenID != headID {
                blockedHeadTokenID = headID
                remainingBypassesForBlockedHead = maximumBypassesPerBlockedHead
            }
            guard remainingBypassesForBlockedHead > 0 else { break }
            let bypassByteLimit = bypassByteLimitLocked(for: head)
            guard bypassByteLimit > 0 else { break }

            let bypassIndex: Int?
            switch bypassLookupMode {
            case .linear:
                bypassIndex = linearBypassIndexLocked(
                    maximumCandidateBytes: bypassByteLimit,
                    cancelled: &cancelled
                )
            case .conservativeSizeIndex:
                bypassIndex = sizeIndexedBypassIndexLocked(
                    maximumCandidateBytes: bypassByteLimit,
                    cancelled: &cancelled
                )
            case .exactSlotMinIndex:
                bypassIndex = exactIndexedBypassIndexLocked(
                    maximumCandidateBytes: bypassByteLimit,
                    cancelled: &cancelled
                )
            }
            guard let bypassIndex, let candidate = pending[bypassIndex] else { break }
            successfulBypasses = saturatingAdd(successfulBypasses, 1)
            clearBypassExactIndexSlotLocked(bypassIndex)
            pending[bypassIndex] = nil
            pendingIndexByToken.removeValue(forKey: ObjectIdentifier(candidate.token))
            pendingCount -= 1
            activateBoundedLocked(candidate)
            remainingBypassesForBlockedHead -= 1
            ready.append(candidate)
        }
        if pendingHead >= pending.count { clearBlockedHeadLocked() }
        compactPendingStorageIfNeededLocked()
        return (ready, cancelled)
    }

    @inline(__always)
    private func activateBoundedLocked(_ request: Request) {
        let bytes = max(1, request.expectedBytes)
        activeCount += 1
        activeBytes += bytes
        let tokenID = ObjectIdentifier(request.token)
        precondition(boundedActiveBytesByToken[tokenID] == nil)
        boundedActiveBytesByToken[tokenID] = bytes
        precondition(boundedActiveBytesByToken.count == activeCount)
    }

    @inline(__always)
    private func deactivateBoundedLocked(_ request: Request) {
        let tokenID = ObjectIdentifier(request.token)
        let expected = max(1, request.expectedBytes)
        guard let tracked = boundedActiveBytesByToken.removeValue(forKey: tokenID) else {
            preconditionFailure("bounded read scheduler lost active request accounting")
        }
        precondition(tracked == expected)
        precondition(boundedActiveBytesByToken.count == activeCount)
    }

    func requestFitsLocked(_ request: Request) -> Bool {
        let bytes = max(1, request.expectedBytes)
        return bytes > maximumInFlightBytes
            ? activeCount == 0
            : activeBytes <= maximumInFlightBytes - bytes
    }

    private func clearBlockedHeadLocked() {
        blockedHeadTokenID = nil
        remainingBypassesForBlockedHead = 0
    }

    func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private func compactPendingStorageIfNeededLocked() {
        if pendingHead > 64, pendingHead * 2 >= pending.count {
            compactPendingStorageLocked()
        }
    }

    private func compactPendingStorageLocked() {
        var compacted: [Request?] = []
        compacted.reserveCapacity(pendingCount)
        if pendingHead < pending.count {
            for index in pendingHead..<pending.count {
                if let request = pending[index] {
                    compacted.append(request)
                }
            }
        }
        precondition(compacted.count == pendingCount)
        pending = compacted
        pendingHead = 0
        pendingIndexByToken.removeAll(keepingCapacity: true)
        for index in pending.indices {
            if let request = pending[index] {
                pendingIndexByToken[ObjectIdentifier(request.token)] = index
            }
        }
        rebuildBypassSizeClassIndexLocked()
        rebuildBypassExactIndexLocked()
    }

    private func dispatch(_ requests: [Request]) {
        for request in requests {
            queue.async { [self] in execute(request) }
        }
    }

    private func execute(_ request: Request) {
        let result = Result<BoundedFileReadResult, any Error> {
            let value = try operations.read(
                request.url,
                request.maximumBytes,
                request.expectedBytes
            )
            guard FileBlobStoreIdentity.digestMatches(
                data: value.data,
                digest: request.digest
            ) else {
                throw AkashicError.integrityMismatch
            }
            return value
        }

        let drained: (ready: [Request], cancelled: [Request])
        lock.lock()
        activeCount -= 1
        activeBytes -= max(1, request.expectedBytes)
        if maximumBypassesPerBlockedHead > 0 {
            deactivateBoundedLocked(request)
        }
        drained = takeReadyLocked()
        lock.unlock()
        request.continuation.resume(returning: result)
        resumeCancelled(drained.cancelled)
        dispatch(drained.ready)
    }
    private func resumeCancelled(_ requests: [Request]) {
        for request in requests {
            request.continuation.resume(returning: .failure(CancellationError()))
        }
    }
}
