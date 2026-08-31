import AkashicCore
import Foundation

package typealias FileBlobStoreReadOperation =
    @Sendable (URL, Int, Int?) throws -> BoundedFileReadResult

package enum FileBlobStoreReadSchedulingError: Error, Sendable {
    case pendingQueueFull
}

package struct FileBlobStoreReadOperations: Sendable {
    package let read: FileBlobStoreReadOperation

    package init(
        read: @escaping FileBlobStoreReadOperation = Self.systemRead
    ) {
        self.read = read
    }

    package static let system = Self()

    package static func systemRead(
        _ url: URL,
        _ maximumBytes: Int,
        _ expectedBytes: Int?
    ) throws -> BoundedFileReadResult {
        try BoundedFileReader.readWithMetadata(
            from: url,
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes
        )
    }
}

package enum FileBlobStoreReadBypassLookupMode: Sendable, Equatable {
    case linear
    case conservativeSizeIndex
    /// Package-only research candidate: exact queue-position-aware minimum index over physical
    /// pending slots. Eager point maintenance is intentionally opt-in because cancellation/update
    /// cost differs materially from the current lazy size-class index.
    case exactSlotMinIndex
}

/// Package-only admission rule for the bounded-bypass research path. The public/default store
/// keeps strict FIFO (`maximumBypassesPerBlockedHead == 0`), so neither mode changes default
/// behavior.
package enum FileBlobStoreReadBypassAdmissionMode: Sendable, Equatable {
    /// Existing research behavior: any younger request that fits current worker/byte capacity may
    /// consume bypass credit.
    case currentCapacity
    /// Admit only bytes that fit the exact worst-case slack at the blocked FIFO head's first
    /// byte-admissible state over all completion orders of currently active reads. Oversized heads
    /// have zero structural allowance because production admission requires `activeCount == 0`.
    case structuralHeadReservation
}

package struct FileBlobStoreReadSchedulerResourceSnapshot: Sendable, Equatable {
    package let activeCount: Int
    package let activeBytes: Int
    package let pendingCount: Int
    package let pendingStorageSlots: Int
    package let maximumPendingStorageSlots: Int
    package let bypassSearches: Int
    package let bypassSlotsExamined: Int
    package let maximumSlotsExaminedPerSearch: Int
    package let successfulBypasses: Int
    package let failedBypassSearches: Int
    package let bypassIndexSearches: Int
    package let bypassIndexClassesExamined: Int
    package let maximumBypassIndexClassesPerSearch: Int
    package let bypassIndexStaleTokensDiscarded: Int
    package let pendingBypassIndexTokenSlots: Int
    package let maximumPendingBypassIndexTokenSlots: Int
    package let bypassExactIndexSearches: Int
    package let bypassExactIndexNodesExamined: Int
    package let maximumBypassExactIndexNodesPerSearch: Int
    package let bypassExactIndexPointUpdates: Int
    package let bypassExactIndexNodeWrites: Int
    package let bypassExactIndexRebuilds: Int
    package let bypassExactIndexRebuildNodeWrites: Int
    package let pendingBypassExactIndexScalarSlots: Int
    package let maximumPendingBypassExactIndexScalarSlots: Int
}
