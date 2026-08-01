import AkashicCore
import AkashicDisk
import AkashicMemory
import Foundation

@main
struct AkashicConsumerSmoke {
    static func main() async throws {
        let payload = Data("consumer-smoke".utf8)
        let digest = BlobDigest.sha256(of: payload)
        let partition = try CachePartitionID.derive(
            domain: "consumer-smoke",
            material: Data([0x01, 0x02])
        )
        let reference = LiveBlobReference(partition: partition, digest: digest)
        let limits = try BlobMaintenanceLimits(
            maximumReferenceCount: 1,
            maximumReferencedBytes: payload.count
        )
        try limits.validate([reference])

        let cache = MemoryCache<BlobDigest, Data>(costLimit: 1024)
        cache.insert(payload, for: digest, cost: payload.count)
        precondition(cache.value(for: digest) == payload)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-consumer-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: "consumer-smoke-v1"
        )
        let store = try await FileBlobStore.open(
            root: generation.root.appendingPathComponent("blobs", isDirectory: true)
        )
        _ = try await store.commit(
            data: payload,
            digest: digest,
            partition: partition
        )
        let restored = try await store.read(digest: digest, partition: partition)
        precondition(restored == payload)
        print(digest.canonicalString)
    }
}
