import AkashicCore
import Foundation

extension FileBlobStore {
    struct BlobDirectoryReservation {
        let count: Int
    }

    /// Return whether a mutation can reserve `count` additional crash-visible direct children.
    /// The observed count is rebuilt from a bounded directory enumeration during bootstrap/GC;
    /// reservations cover temporary files as well as final payload/metadata names so a crash at an
    /// intermediate rename boundary cannot create a store that the configured reopen scan rejects.
    func canReserveBlobDirectoryEntries(_ count: Int) -> Bool {
        guard count >= 0,
            let observed = blobDirectoryEntryCount,
            blobDirectoryReservedEntryCount >= 0
        else { return false }
        let used = observed.addingReportingOverflow(blobDirectoryReservedEntryCount)
        guard !used.overflow else { return false }
        let projected = used.partialValue.addingReportingOverflow(count)
        return !projected.overflow
            && projected.partialValue <= limits.maximumDirectoryEntryCount
    }

    func reserveBlobDirectoryEntries(_ count: Int) throws -> BlobDirectoryReservation {
        guard count >= 0,
            let observed = blobDirectoryEntryCount,
            blobDirectoryReservedEntryCount >= 0
        else { throw AkashicError.storageUnavailable }
        let used = observed.addingReportingOverflow(blobDirectoryReservedEntryCount)
        let projected = used.partialValue.addingReportingOverflow(count)
        guard !used.overflow,
            !projected.overflow,
            projected.partialValue <= limits.maximumDirectoryEntryCount
        else { throw AkashicError.limitExceeded }
        let reserved = blobDirectoryReservedEntryCount.addingReportingOverflow(count)
        guard !reserved.overflow else { throw AkashicError.storageUnavailable }
        blobDirectoryReservedEntryCount = reserved.partialValue
        return BlobDirectoryReservation(count: count)
    }

    /// Convert a transient reservation into the number of newly materialized direct children that
    /// remain after the operation. `newEntryCount` can be smaller than the reservation because a
    /// rename replaces an existing name or because temporary files were cleaned before return.
    func settleBlobDirectoryReservation(
        _ reservation: BlobDirectoryReservation,
        newEntryCount: Int
    ) {
        precondition(reservation.count >= 0)
        precondition(newEntryCount >= 0 && newEntryCount <= reservation.count)
        precondition(blobDirectoryReservedEntryCount >= reservation.count)
        blobDirectoryReservedEntryCount -= reservation.count
        guard let observed = blobDirectoryEntryCount else { return }
        let updated = observed.addingReportingOverflow(newEntryCount)
        blobDirectoryEntryCount = updated.overflow ? nil : updated.partialValue
    }

    /// Rebuild exact headroom after a failed physical mutation. The O(N) enumeration is deliberately
    /// failure-only: successful commit/stage paths retain O(1) admission while transient syscall
    /// failures do not consume phantom capacity after their private temporaries were cleaned up.
    ///
    /// If the bounded recount itself cannot establish an exact value, creation fails closed by
    /// invalidating the ledger. Logical revocation can still use root-manifest checkpoints, and a
    /// later reopen/strict GC may rebuild the direct-child count from a fresh bounded scan.
    func reconcileBlobDirectoryReservationAfterFailure(
        _ reservation: BlobDirectoryReservation
    ) {
        precondition(reservation.count >= 0)
        guard blobDirectoryReservedEntryCount == reservation.count else {
            blobDirectoryEntryCount = nil
            blobDirectoryReservedEntryCount = 0
            return
        }
        do {
            let observed = try BoundedDirectoryReader.names(
                in: blobs,
                maximumCount: limits.maximumDirectoryEntryCount
            ).count
            try resetBlobDirectoryEntryCount(observed)
        } catch {
            blobDirectoryEntryCount = nil
            blobDirectoryReservedEntryCount = 0
        }
    }

    func resetBlobDirectoryEntryCount(_ observedCount: Int) throws {
        guard observedCount >= 0,
            observedCount <= limits.maximumDirectoryEntryCount
        else { throw AkashicError.limitExceeded }
        blobDirectoryEntryCount = observedCount
        blobDirectoryReservedEntryCount = 0
    }

    func recordBlobDirectoryEntryRemoved() {
        guard let observed = blobDirectoryEntryCount else { return }
        guard observed > 0 else {
            blobDirectoryEntryCount = nil
            return
        }
        blobDirectoryEntryCount = observed - 1
    }

    @discardableResult
    func removeBlobDirectoryEntryIfPresent(_ url: URL) throws -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return false
        }
        recordBlobDirectoryEntryRemoved()
        return true
    }
}
