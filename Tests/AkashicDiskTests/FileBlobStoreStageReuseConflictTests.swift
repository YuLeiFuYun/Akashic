import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk staged reuse authority conflicts")
struct FileBlobStoreStageReuseConflictTests {
  @Test("T102 reuse stage conflicts after trim retires observed physical authority")
  func reuseStageConflictsAfterTrimRetiresAuthority() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        )
      )
      let partition = try fileBlobStoreTestPartition("stage-reuse-trim-conflict")
      let oldData = Data(repeating: 0x41, count: 40)
      let oldDigest = BlobDigest.sha256(of: oldData)
      let newData = Data(repeating: 0x42, count: 40)
      let newDigest = BlobDigest.sha256(of: newData)

      let original = try await store.commit(
        data: oldData,
        digest: oldDigest,
        partition: partition
      )
      #expect(original.disposition == .created)

      // This stage writes no new file. It only remembers that `original.physicalID` was current
      // authority at staging time.
      let reuseStage = try await store.stage(
        data: oldData,
        digest: oldDigest,
        partition: partition
      )

      // Make the staged/reused entry strictly older than the next commit so the 64-byte soft limit
      // deterministically chooses it as the one 40-byte trim victim after live bytes reach 80.
      try await Task.sleep(nanoseconds: 10_000_000)
      let replacement = try await store.commit(
        data: newData,
        digest: newDigest,
        partition: partition
      )
      #expect(replacement.disposition == .created)
      #expect(try await store.read(digest: newDigest, partition: partition) == newData)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: oldDigest, partition: partition)
      }

      // A reuse-stage owns no unpublished carrier that could legitimately re-establish authority.
      // Once trim has retired the observed PhysicalBlobID, publish must conflict rather than return
      // `.reused` with a stale/non-authoritative physical identity.
      await expectFileBlobStoreTestAkashicError(.transactionConflict) {
        _ = try await store.publish(reuseStage)
      }
      #expect(try await store.read(digest: newDigest, partition: partition) == newData)
    }
  }

  @Test("T102 stale reuse token does not poison a later stage for the same bytes")
  func staleReuseTokenDoesNotPoisonLaterStage() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        )
      )
      let partition = try fileBlobStoreTestPartition("stage-reuse-restage")
      let oldData = Data(repeating: 0x51, count: 40)
      let oldDigest = BlobDigest.sha256(of: oldData)
      let newData = Data(repeating: 0x52, count: 40)
      let newDigest = BlobDigest.sha256(of: newData)

      let original = try await store.commit(
        data: oldData,
        digest: oldDigest,
        partition: partition
      )
      let staleReuse = try await store.stage(
        data: oldData,
        digest: oldDigest,
        partition: partition
      )
      try await Task.sleep(nanoseconds: 10_000_000)
      _ = try await store.commit(
        data: newData,
        digest: newDigest,
        partition: partition
      )
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: oldDigest, partition: partition)
      }

      // The old reuse token is deliberately still outstanding. A new stage for A must not clone
      // that stale observation; it must own a fresh unpublished carrier that can be committed.
      let freshStage = try await store.stage(
        data: oldData,
        digest: oldDigest,
        partition: partition
      )
      let freshPublication = try await store.publish(freshStage)
      #expect(freshPublication.disposition == .created)
      #expect(freshPublication.physicalID != original.physicalID)
      #expect(try await store.read(digest: oldDigest, partition: partition) == oldData)

      await expectFileBlobStoreTestAkashicError(.transactionConflict) {
        _ = try await store.publish(staleReuse)
      }
      #expect(try await store.read(digest: oldDigest, partition: partition) == oldData)
    }
  }
}
