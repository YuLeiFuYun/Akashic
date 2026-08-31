import AkashicCore
import Foundation

extension FileBlobStore {
    /// Package-only resource diagnostic for schema4-compatible immutable base snapshots.
    ///
    /// Unlike `resourceProbeDecodeDirectoryHeadSnapshot`, this includes the same entry/key,
    /// byte-count, timestamp and PhysicalBlobID ownership proof used by production bootstrap.
    package static func resourceProbeDecodeAndValidateDirectoryHeadSnapshot(
        _ data: Data
    ) throws -> [String: FileBlobStoreRecordShadowEntry] {
        guard data.count <= maximumManifestBytes else { throw AkashicError.invalidManifest }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw AkashicError.invalidManifest
        }
        guard manifest.schemaVersion == directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            validatedManifestOwnershipIndexCore(manifest) != nil
        else { throw AkashicError.invalidManifest }
        return manifest.entries.mapValues { entry in
            FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }
}
