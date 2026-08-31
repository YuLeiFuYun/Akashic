import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk authority divergence recovery")
struct FileBlobStoreAuthorityDivergenceTests {
  @Test("AKASHIC-CT-076 tombstone publication error freezes a stale-hit actor until reopen")
  func tombstonePublicationErrorRequiresReopen() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("authority-divergence-tombstone".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("authority-divergence-tombstone")
      var setup: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await setup!.commit(data: data, digest: digest, partition: partition)
      setup = nil
      try await waitForWriterLeaseRelease(root: root)

      let state = FastCommitFaultState()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { point in
          if point == .afterManifestRenamed,
            state.increment("tombstone-rename") == 1
          {
            throw POSIXError(.EIO)
          }
        }
      )

      await expectFastCommitPOSIXError(.EIO) {
        try await store!.remove(digest: digest, partition: partition)
      }
      #expect(state.value("tombstone-rename") == 1)
      #expect(manifestRecordFiles(in: root).count == 1)
      #expect(manifestTestBlobFiles(in: root).count == 1)
      await expectManifestTestAkashicError(.storageUnavailable) {
        try await store!.read(digest: digest, partition: partition)
      }
      #expect(await store!.physicalID(digest: digest, partition: partition) == nil)
      await expectManifestTestAkashicError(.storageUnavailable) {
        try await store!.commit(data: data, digest: digest, partition: partition)
      }
      #expect(state.value("tombstone-rename") == 1)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root)
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
      #expect(manifestTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-077 same-key replacement divergence converges by sequence after reopen")
  func sameKeyReplacementPublicationErrorRequiresReopen() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("authority-divergence-replacement".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("authority-divergence-replacement")
      var setup: FileBlobStore? = try await FileBlobStore.open(root: root)
      let original = try await setup!.commit(data: data, digest: digest, partition: partition)
      let originalID = original.physicalID
      setup = nil
      try await waitForWriterLeaseRelease(root: root)

      let originalURL = manifestTestBlobURL(root: root, id: originalID)
      try Data(repeating: 0x5a, count: data.count).write(to: originalURL)
      #expect(try manifestXattrRecordCount(in: root, generation: 1) == 1)

      let state = FastCommitFaultState()
      let operations = FileBlobStoreFastCommitOperations(
        synchronize: { descriptor in
          let call = state.increment("sync")
          if call == 2 {
            errno = EIO
            return -1
          }
          return FileBlobStoreFastCommitOperations.systemSynchronize(descriptor)
        }
      )
      var store: FileBlobStore? = try await faultInjectedFastStore(
        root: root,
        operations: operations
      )

      await expectFastCommitPOSIXError(.EIO) {
        try await store!.commit(data: data, digest: digest, partition: partition)
      }
      #expect(state.value("sync") == 2)
      #expect(manifestTestBlobFiles(in: root).count == 2)
      #expect(try manifestXattrRecordCount(in: root, generation: 1) == 2)
      await expectManifestTestAkashicError(.storageUnavailable) {
        try await store!.commit(data: data, digest: digest, partition: partition)
      }
      #expect(state.value("sync") == 2)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root)
      #expect(try await reopened.read(digest: digest, partition: partition) == data)
      let recoveredID = await reopened.physicalID(digest: digest, partition: partition)
      #expect(recoveredID != nil)
      #expect(recoveredID != originalID)
      #expect(manifestTestBlobFiles(in: root).count == 1)
    }
  }
}
