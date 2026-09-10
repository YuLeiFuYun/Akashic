import AkashicCore
import AkashicDisk
import Foundation

public enum AkashicBlobStoreConformanceFixture {
    public static func open(
        root: URL,
        softTotalBytes: Int,
        maximumBlobBytes: Int
    ) async throws -> any BlobStoreMaintaining & TransactionalBlobStoring {
        try await FileBlobStore.open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: softTotalBytes,
                maximumBlobBytes: maximumBlobBytes
            )
        )
    }

    public static func openGeneration(
        root: URL,
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationDescriptor {
        let handle = try await StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        )
        return try handle.descriptor
    }
}
