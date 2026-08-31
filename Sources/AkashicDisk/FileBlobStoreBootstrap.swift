import AkashicCore
import Foundation

extension FileBlobStore {
    private struct BootstrapSchemaEnvelope: Decodable {
        let schemaVersion: UInt16
    }

    func bootstrap(
        root: URL,
        observer: FileBlobStoreBootstrapObserver
    ) throws {
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(blobs)
        observer(.directoriesPrepared)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try BoundedFileReader.read(
                from: manifestURL,
                maximumBytes: Self.maximumManifestBytes
            )
            guard let envelope = try? JSONDecoder().decode(BootstrapSchemaEnvelope.self, from: data)
            else { throw AkashicError.invalidManifest }
            try bootstrapPersistedManifest(
                data: data,
                schemaVersion: envelope.schemaVersion,
                observer: observer
            )
        } else {
            try requireFreshPhysicalStateForMissingManifest()
            let initial = Manifest()
            try persistManifestSnapshot(initial, injectFaults: false)
            manifest = initial
            observer(.manifestSnapshotLoaded)
            observer(.manifestRecordsReplayed)
        }
        try reconcileStorageAfterBootstrap()
        observer(.storageReconciled)
        try trimIfNeeded()
        try rebuildManifestResourceIndexes()
        observer(.trimCompleted)
    }

}
