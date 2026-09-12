import AkashicBlobStoreConformanceFixture
import AkashicCore
import Foundation

enum BlobStoreUnderTest {
    static func open(
        root: URL,
        softTotalBytes: Int,
        maximumBlobBytes: Int
    ) async throws -> any BlobStoreMaintaining & TransactionalBlobStoring {
        try await AkashicBlobStoreConformanceFixture.open(
            root: root,
            softTotalBytes: softTotalBytes,
            maximumBlobBytes: maximumBlobBytes
        )
    }

    static func openGeneration(
        root: URL,
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationDescriptor {
        try await AkashicBlobStoreConformanceFixture.openGeneration(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        )
    }
}
