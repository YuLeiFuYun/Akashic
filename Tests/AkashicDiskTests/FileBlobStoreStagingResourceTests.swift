import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk staging resource semantics")
struct FileBlobStoreStagingResourceTests {
  @Test("T102 pending tokens, unique staged files, and soft live bytes are distinct resources")
  func pendingTokensAndUniqueStagedFilesAreDistinct() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        )
      )
      let partition = try fileBlobStoreTestPartition("staging-resource")
      let firstData = Data(repeating: 0x71, count: 40)
      let firstDigest = BlobDigest.sha256(of: firstData)
      let secondData = Data(repeating: 0x72, count: 40)
      let secondDigest = BlobDigest.sha256(of: secondData)
      let blobs = root.appendingPathComponent("blobs", isDirectory: true)

      let firstStage = try await store.stage(
        data: firstData,
        digest: firstDigest,
        partition: partition
      )
      let firstNames = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
      #expect(firstNames.count == 1)

      // A second token for the same unpublished logical object reuses the first staged carrier.
      let duplicateToken = try await store.stage(
        data: firstData,
        digest: firstDigest,
        partition: partition
      )
      let duplicateNames = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
      #expect(duplicateNames.count == 1)

      // A distinct 40-byte stage creates a second durable physical carrier. Aggregate unpublished
      // payload bytes are now 80, above softTotalBytes=64, yet staging remains admitted because the
      // soft live-set target is not an aggregate staged-physical-byte limit.
      let secondStage = try await store.stage(
        data: secondData,
        digest: secondDigest,
        partition: partition
      )
      let distinctNames = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
      #expect(distinctNames.count == 2)

      // None of the staged bytes is logically authoritative before publish.
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: firstDigest, partition: partition)
      }
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: secondDigest, partition: partition)
      }

      // Discarding one duplicate token must not unlink a carrier still referenced by the other
      // created-stage token. Only the last owning token should make that unpublished file eligible
      // for cleanup.
      await store.discard(duplicateToken)
      #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 2)
      await store.discard(firstStage)
      #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 1)
      await store.discard(secondStage)
      #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).isEmpty)
    }
  }
}
