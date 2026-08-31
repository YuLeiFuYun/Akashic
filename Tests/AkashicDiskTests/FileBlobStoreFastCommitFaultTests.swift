import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk fast commit syscall faults")
struct FileBlobStoreFastCommitFaultTests {
  @Test("AKASHIC-CT-072 fast close failures are never retried on the same descriptor")
  func closeFailureIsNotRetried() async throws {
    try await withManifestTestTemporaryDirectory { parent in
      do {
        let root = parent.appendingPathComponent("xattr-close", isDirectory: true)
        let data = Data("fast-xattr-close-failure".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("fast-xattr-close-failure")
        let state = FastCommitFaultState()
        let operations = FileBlobStoreFastCommitOperations(
          close: { descriptor in
            let call = state.increment("close")
            let result = FileBlobStoreFastCommitOperations.systemClose(descriptor)
            if call == 1 {
              errno = EIO
              return -1
            }
            return result
          }
        )
        let store = try await faultInjectedFastStore(root: root, operations: operations)

        await expectFastCommitPOSIXError(.EIO) {
          try await store.commit(data: data, digest: digest, partition: partition)
        }
        #expect(state.value("close") == 1)
        try await expectFastCommitMissAndNoPhysicalAuthority(
          store: store,
          root: root,
          digest: digest,
          partition: partition
        )
      }

      do {
        let root = parent.appendingPathComponent("sidecar-close", isDirectory: true)
        let data = Data("fast-sidecar-close-failure".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("fast-sidecar-close-failure")
        let state = FastCommitFaultState()
        let operations = FileBlobStoreFastCommitOperations(
          setManifestXattr: { _, _, _ in
            errno = ENOTSUP
            return -1
          },
          close: { descriptor in
            let call = state.increment("close")
            let result = FileBlobStoreFastCommitOperations.systemClose(descriptor)
            if call == 2 {
              errno = EIO
              return -1
            }
            return result
          }
        )
        let store = try await faultInjectedFastStore(root: root, operations: operations)

        await expectFastCommitPOSIXError(.EIO) {
          try await store.commit(data: data, digest: digest, partition: partition)
        }
        #expect(state.value("close") == 2)
        try await expectFastCommitMissAndNoPhysicalAuthority(
          store: store,
          root: root,
          digest: digest,
          partition: partition
        )
      }
    }
  }

  @Test("AKASHIC-CT-073 fast pre-rename syscall faults preserve a clean miss")
  func preRenameFaultMatrix() async throws {
    try await withManifestTestTemporaryDirectory { parent in
      try await verifyFastCommitSuccess(
        root: parent.appendingPathComponent("write-retry", isDirectory: true),
        label: "fast-write-retry",
        operations: {
          let state = FastCommitFaultState()
          return FileBlobStoreFastCommitOperations(
            write: { descriptor, bytes, count in
              let call = state.increment("write")
              if call == 1 {
                errno = EINTR
                return -1
              }
              return FileBlobStoreFastCommitOperations.systemWrite(
                descriptor,
                bytes,
                min(count, 7)
              )
            }
          )
        }()
      )

      do {
        let state = FastCommitFaultState()
        try await verifyFastCommitSuccess(
          root: parent.appendingPathComponent("fsync-retry", isDirectory: true),
          label: "fast-fsync-retry",
          operations: FileBlobStoreFastCommitOperations(
            synchronize: { descriptor in
              if state.increment("sync") == 1 {
                errno = EINTR
                return -1
              }
              return FileBlobStoreFastCommitOperations.systemSynchronize(descriptor)
            }
          )
        )
        #expect(state.value("sync") >= 3)
      }

      try await verifyFastCommitHardFailure(
        root: parent.appendingPathComponent("open-failure", isDirectory: true),
        label: "fast-open-failure",
        expected: .EACCES,
        operations: FileBlobStoreFastCommitOperations(
          open: { _, _, _ in
            errno = EACCES
            return -1
          }
        )
      )

      do {
        let state = FastCommitFaultState()
        try await verifyFastCommitHardFailure(
          root: parent.appendingPathComponent("write-enospc", isDirectory: true),
          label: "fast-write-enospc",
          expected: .ENOSPC,
          operations: FileBlobStoreFastCommitOperations(
            write: { descriptor, bytes, count in
              let call = state.increment("write")
              if call == 1 {
                return FileBlobStoreFastCommitOperations.systemWrite(
                  descriptor,
                  bytes,
                  min(count, 11)
                )
              }
              errno = ENOSPC
              return -1
            }
          )
        )
      }

      try await verifyFastCommitHardFailure(
        root: parent.appendingPathComponent("fsync-eio", isDirectory: true),
        label: "fast-fsync-eio",
        expected: .EIO,
        operations: FileBlobStoreFastCommitOperations(
          synchronize: { _ in
            errno = EIO
            return -1
          }
        )
      )

      try await verifyFastCommitHardFailure(
        root: parent.appendingPathComponent("rename-enospc", isDirectory: true),
        label: "fast-rename-enospc",
        expected: .ENOSPC,
        operations: FileBlobStoreFastCommitOperations(
          rename: { _, _ in
            errno = ENOSPC
            return -1
          }
        )
      )
    }
  }

  @Test("AKASHIC-CT-074 post-rename directory faults are visible but recoverable")
  func postRenameDirectoryFaultsRecoverPublishedAuthority() async throws {
    try await withManifestTestTemporaryDirectory { parent in
      do {
        let state = FastCommitFaultState()
        try await verifyPostRenameFastCommitFailure(
          root: parent.appendingPathComponent("directory-open", isDirectory: true),
          label: "fast-directory-open",
          expected: .EACCES,
          operations: FileBlobStoreFastCommitOperations(
            open: { path, flags, mode in
              let call = state.increment("open")
              if call == 2 {
                errno = EACCES
                return -1
              }
              return FileBlobStoreFastCommitOperations.systemOpen(path, flags, mode)
            }
          )
        )
        #expect(state.value("open") == 2)
      }

      do {
        let state = FastCommitFaultState()
        try await verifyPostRenameFastCommitFailure(
          root: parent.appendingPathComponent("directory-fsync", isDirectory: true),
          label: "fast-directory-fsync",
          expected: .EIO,
          operations: FileBlobStoreFastCommitOperations(
            synchronize: { descriptor in
              let call = state.increment("sync")
              if call == 2 {
                errno = EIO
                return -1
              }
              return FileBlobStoreFastCommitOperations.systemSynchronize(descriptor)
            }
          )
        )
        #expect(state.value("sync") == 2)
      }
    }
  }

  @Test("AKASHIC-CT-075 authority publication errors freeze the writer until reopen")
  func authorityPublicationErrorsRequireReopen() async throws {
    try await withManifestTestTemporaryDirectory { parent in
      // Fast xattr: after UUID+xattr authority is visible, a directory-fsync error must freeze the
      // actor. Retrying on the stale sequence state would otherwise create a second sequence-1 xattr
      // carrier and make reopen fail closed with duplicate sequence authority.
      do {
        let root = parent.appendingPathComponent("fast-xattr-retry", isDirectory: true)
        let data = Data("authority-divergence-fast-xattr".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("authority-divergence-fast-xattr")
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
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.commit(data: data, digest: digest, partition: partition)
        }
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.read(digest: digest, partition: partition)
        }
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.stage(data: data, digest: digest, partition: partition)
        }
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.remove(digest: digest, partition: partition)
        }
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.removeAll(partition: partition)
        }
        let maintenanceLimits = try BlobMaintenanceLimits(
          maximumReferenceCount: 1,
          maximumReferencedBytes: 1
        )
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.garbageCollect(retaining: [], limits: maintenanceLimits)
        }
        #expect(await store!.physicalID(digest: digest, partition: partition) == nil)
        #expect(state.value("sync") == 2)
        #expect(manifestTestBlobFiles(in: root).count == 1)
        #expect(try manifestXattrRecordCount(in: root, generation: 1) == 1)

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        #expect(try await reopened.read(digest: digest, partition: partition) == data)
      }

      // Fast sidecar fallback: explicit xattr incompatibility selects the old two-file transaction.
      // Its record rename is still an authority switch, so a later directory-fsync error must freeze
      // the actor instead of allowing sequence reuse.
      do {
        let root = parent.appendingPathComponent("fast-sidecar-retry", isDirectory: true)
        let data = Data("authority-divergence-fast-sidecar".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("authority-divergence-fast-sidecar")
        let state = FastCommitFaultState()
        let operations = FileBlobStoreFastCommitOperations(
          setManifestXattr: { _, _, _ in
            errno = ENOTSUP
            return -1
          },
          synchronize: { descriptor in
            let call = state.increment("sync")
            if call == 3 {
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
        #expect(state.value("sync") == 3)
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.commit(data: data, digest: digest, partition: partition)
        }
        #expect(state.value("sync") == 3)
        #expect(manifestRecordFiles(in: root).count == 1)
        #expect(manifestTestBlobFiles(in: root).count == 1)

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        #expect(try await reopened.read(digest: digest, partition: partition) == data)
      }

      // Explicit sidecar: a failed publish after the sidecar rename must also freeze the actor.
      // discard(stage) is deliberately a no-op in that state because the visible sidecar may already
      // reference the staged blob; reopen owns reconciliation.
      do {
        let root = parent.appendingPathComponent("sidecar-publish", isDirectory: true)
        let data = Data("authority-divergence-sidecar".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("authority-divergence-sidecar")
        let state = FastCommitFaultState()
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          faultInjector: { point in
            if point == .afterManifestRenamed,
              state.increment("manifest-rename") == 1
            {
              throw POSIXError(.EIO)
            }
          }
        )
        let stage = try await store!.stage(
          data: data,
          digest: digest,
          partition: partition
        )

        await expectFastCommitPOSIXError(.EIO) {
          try await store!.publish(stage)
        }
        #expect(manifestRecordFiles(in: root).count == 1)
        #expect(manifestTestBlobFiles(in: root).count == 1)
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.publish(stage)
        }
        await store!.discard(stage)
        #expect(manifestTestBlobFiles(in: root).count == 1)
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.remove(digest: digest, partition: partition)
        }

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        #expect(try await reopened.read(digest: digest, partition: partition) == data)
      }

      // Explicit publish can also fail after the durable writer has fully returned. That path does
      // not inherit a rename-observer error, so the publish-level afterManifestPublished catch must
      // independently freeze the actor before it can reuse stale in-memory manifest state.
      do {
        let root = parent.appendingPathComponent("sidecar-after-published", isDirectory: true)
        let data = Data("authority-divergence-after-published".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("authority-divergence-after-published")
        let state = FastCommitFaultState()
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          faultInjector: { point in
            if point == .afterManifestPublished,
              state.increment("after-published") == 1
            {
              throw POSIXError(.EIO)
            }
          }
        )
        let stage = try await store!.stage(
          data: data,
          digest: digest,
          partition: partition
        )

        await expectFastCommitPOSIXError(.EIO) {
          try await store!.publish(stage)
        }
        #expect(state.value("after-published") == 1)
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.publish(stage)
        }
        await store!.discard(stage)
        #expect(manifestRecordFiles(in: root).count == 1)
        #expect(manifestTestBlobFiles(in: root).count == 1)

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        #expect(try await reopened.read(digest: digest, partition: partition) == data)
      }

      // Checkpoint: if manifest generation G+1 is already visible when the operation fails, this
      // actor must not continue writing generation-G deltas. Reopen must converge to the visible
      // checkpoint and no post-error mutation may be admitted on the stale actor.
      do {
        let root = parent.appendingPathComponent("checkpoint-generation", isDirectory: true)
        let partition = try manifestTestPartition("authority-divergence-checkpoint")
        let first = Data("authority-divergence-checkpoint-a".utf8)
        let second = Data("authority-divergence-checkpoint-b".utf8)
        let firstDigest = BlobDigest.sha256(of: first)
        let secondDigest = BlobDigest.sha256(of: second)
        var setup: FileBlobStore? = try await FileBlobStore.open(root: root)
        _ = try await setup!.commit(data: first, digest: firstDigest, partition: partition)
        _ = try await setup!.commit(data: second, digest: secondDigest, partition: partition)
        setup = nil
        try await waitForWriterLeaseRelease(root: root)

        let state = FastCommitFaultState()
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          faultInjector: { point in
            if point == .afterManifestRenamed,
              state.increment("manifest-rename") == 1
            {
              throw POSIXError(.EIO)
            }
          }
        )
        await expectFastCommitPOSIXError(.EIO) {
          try await store!.removeAll(partition: partition)
        }
        let visibleSnapshot = try JSONDecoder().decode(
          FileBlobStore.Manifest.self,
          from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        )
        #expect(visibleSnapshot.generation == 2)
        #expect(visibleSnapshot.entries.isEmpty)

        let later = Data("authority-divergence-checkpoint-later".utf8)
        let laterDigest = BlobDigest.sha256(of: later)
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.commit(data: later, digest: laterDigest, partition: partition)
        }

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        for digest in [firstDigest, secondDigest, laterDigest] {
          await expectManifestTestAkashicError(.notFound) {
            try await reopened.read(digest: digest, partition: partition)
          }
        }
      }
    }
  }
}
