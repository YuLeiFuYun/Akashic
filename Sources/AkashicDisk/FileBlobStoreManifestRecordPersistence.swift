import AkashicCore
import Foundation

extension FileBlobStore {
    func persistManifestRecord(
        _ record: ManifestRecord,
        to destination: URL
    ) throws {
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
        let directoryReservation = try reserveBlobDirectoryEntries(1)
        var directoryReservationSettled = false
        defer {
            if !directoryReservationSettled {
                reconcileBlobDirectoryReservationAfterFailure(directoryReservation)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumManifestRecordBytes else {
            throw AkashicError.storageUnavailable
        }
        let injector = faultInjector
        var authorityRenamed = false
        do {
            try DurableFileWriter.writeReplacing(
                data,
                to: destination,
                faultInjector: { point in
                    try Self.forwardManifestFault(point, to: injector)
                },
                renameObserver: { authorityRenamed = true }
            )
            settleBlobDirectoryReservation(
                directoryReservation,
                newEntryCount: destinationExisted ? 0 : 1
            )
            directoryReservationSettled = true
        } catch {
            if authorityRenamed {
                settleBlobDirectoryReservation(
                    directoryReservation,
                    newEntryCount: destinationExisted ? 0 : 1
                )
                directoryReservationSettled = true
                requiresReopenBeforeFurtherAccess = true
            }
            throw error
        }
    }

}
