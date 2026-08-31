import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk reopen limit authority semantics")
struct FileBlobStoreLimitReopenAuthorityTests {
  @Test("T102 lowering maximumBlobBytes on reopen retires previously valid authority")
  func lowerMaximumBlobBytesRetiresExistingAuthority() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let partition = try fileBlobStoreTestPartition("reopen-max-blob-authority")
      let data = Data(repeating: 0x7A, count: 40)
      let digest = BlobDigest.sha256(of: data)

      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        )
      )
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      #expect(publication.disposition == .created)
      #expect(try await store!.read(digest: digest, partition: partition) == data)
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      // The tighter limit is not merely a future-write/read admission policy. Current bootstrap
      // reconciliation persistently removes an authoritative entry whose committed byteCount is
      // now above the opener's maximumBlobBytes.
      store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 16
        )
      )
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: digest, partition: partition)
      }
      #expect(await store!.physicalID(digest: digest, partition: partition) == nil)
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      // Restoring the old runtime limit cannot restore authority after the tighter opener has
      // persisted the removal.
      let reopened = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        )
      )
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
    }
  }
}
