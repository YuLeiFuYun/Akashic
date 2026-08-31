import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk directory-scan recoverability bounds")
struct FileBlobStoreDirectoryScanRecoverabilityTests {
  @Test("AKASHIC-CT-168 running mutation preserves configured blob-directory scan recoverability")
  func runningMutationPreservesConfiguredBlobDirectoryScanRecoverability() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
      let partition = try fileBlobStoreTestPartition("directory-recovery-bound")
      let payloads = (1...8).map { value in
        Data(repeating: UInt8(value), count: 16)
      }
      var committed: [(data: Data, digest: BlobDigest)] = []
      var rejected = false

      for data in payloads {
        let digest = BlobDigest.sha256(of: data)
        do {
          _ = try await store!.commit(data: data, digest: digest, partition: partition)
          committed.append((data, digest))
          #expect(try directBlobDirectoryEntryCount(root: root) <= limits.maximumDirectoryEntryCount)
        } catch let error as AkashicError where error == .limitExceeded {
          rejected = true
          break
        }
      }

      #expect(!committed.isEmpty)
      #expect(rejected)
      #expect(try directBlobDirectoryEntryCount(root: root) <= limits.maximumDirectoryEntryCount)
      for item in committed {
        #expect(try await store!.read(digest: item.digest, partition: partition) == item.data)
      }

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root, limits: limits)
      for item in committed {
        #expect(try await reopened.read(digest: item.digest, partition: partition) == item.data)
      }
    }
  }

  @Test("AKASHIC-CT-170 metadata pressure falls back to root checkpoint before exceeding recovery bound")
  func metadataPressureFallsBackToRootCheckpoint() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        limits: limits,
        faultInjector: { _ in },
        fastCommitOperations: FileBlobStoreFastCommitOperations(
          setManifestXattr: directoryRecoverabilityUnsupportedXattr
        )
      )
      let partition = try fileBlobStoreTestPartition("directory-metadata-pressure")
      let first = Data(repeating: 0x51, count: 16)
      let firstDigest = BlobDigest.sha256(of: first)
      let second = Data(repeating: 0x52, count: 16)
      let secondDigest = BlobDigest.sha256(of: second)
      let third = Data(repeating: 0x53, count: 16)
      let thirdDigest = BlobDigest.sha256(of: third)
      let fourth = Data(repeating: 0x54, count: 16)
      let fourthDigest = BlobDigest.sha256(of: fourth)

      // Forced sidecar fallback makes the first commit consume payload + metadata = two slots.
      _ = try await store!.commit(data: first, digest: firstDigest, partition: partition)
      #expect(try directBlobDirectoryEntryCount(root: root) == 2)

      // Only one direct-child slot remains. The second commit must stage its payload there and
      // publish logical authority through the root manifest checkpoint rather than trying another
      // sidecar temporary that would make crash recovery unscannable.
      _ = try await store!.commit(data: second, digest: secondDigest, partition: partition)
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)

      // That root checkpoint makes the first sidecar stale physical metadata debt. The next commit
      // must repay that known-owned debt before reserving its payload slot, so the store keeps making
      // progress without requiring an explicit GC. After three real payloads occupy all slots, only
      // then should a fourth unique payload receive recovery-budget backpressure.
      _ = try await store!.commit(data: third, digest: thirdDigest, partition: partition)
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)
      await expectFileBlobStoreTestAkashicError(.limitExceeded) {
        _ = try await store!.commit(data: fourth, digest: fourthDigest, partition: partition)
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)

      #expect(try await store!.read(digest: firstDigest, partition: partition) == first)
      #expect(try await store!.read(digest: secondDigest, partition: partition) == second)
      #expect(try await store!.read(digest: thirdDigest, partition: partition) == third)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root, limits: limits)
      #expect(try await reopened.read(digest: firstDigest, partition: partition) == first)
      #expect(try await reopened.read(digest: secondDigest, partition: partition) == second)
      #expect(try await reopened.read(digest: thirdDigest, partition: partition) == third)
    }
  }

  @Test("AKASHIC-CT-172 fast pre-rename failure recounts headroom instead of retaining phantom slots")
  func fastPreRenameFailureRecountsRecoveryHeadroom() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      let partition = try fileBlobStoreTestPartition("directory-fast-failure-recount")
      let failedData = Data(repeating: 0x71, count: 16)
      let failedDigest = BlobDigest.sha256(of: failedData)
      let store = try await FileBlobStore.open(
        root: root,
        limits: limits,
        faultInjector: { _ in },
        fastCommitOperations: FileBlobStoreFastCommitOperations(
          setManifestXattr: directoryRecoverabilityHardFailXattr
        )
      )

      do {
        _ = try await store.commit(
          data: failedData,
          digest: failedDigest,
          partition: partition
        )
        Issue.record("expected pre-rename xattr failure")
      } catch let error as POSIXError {
        #expect(error.code == .EIO)
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 0)

      // The failed fast transaction reserved two transient slots. Its cleanup is exact, so all
      // three physical slots must remain usable by the same live store without reopen or GC.
      var stages: [BlobStage] = []
      for value in 0..<3 {
        let data = Data(repeating: UInt8(0x72 + value), count: 16)
        let digest = BlobDigest.sha256(of: data)
        stages.append(
          try await store.stage(data: data, digest: digest, partition: partition)
        )
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)
      for stage in stages { await store.discard(stage) }
      #expect(try directBlobDirectoryEntryCount(root: root) == 0)
    }
  }

  @Test("AKASHIC-CT-173 failed stage write recounts headroom instead of retaining a phantom payload")
  func failedStageWriteRecountsRecoveryHeadroom() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      let partition = try fileBlobStoreTestPartition("directory-stage-failure-recount")
      let fault = DirectoryRecoverabilityOneShotFault()
      let store = try await FileBlobStore.open(
        root: root,
        limits: limits,
        faultInjector: { point in
          if point == .afterBlobDataWritten, fault.take() {
            throw DirectoryRecoverabilityInjectedError.stageWrite
          }
        }
      )
      let failedData = Data(repeating: 0x81, count: 16)
      let failedDigest = BlobDigest.sha256(of: failedData)

      do {
        _ = try await store.stage(
          data: failedData,
          digest: failedDigest,
          partition: partition
        )
        Issue.record("expected injected stage failure")
      } catch DirectoryRecoverabilityInjectedError.stageWrite {
        // Expected.
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 0)

      var stages: [BlobStage] = []
      for value in 0..<3 {
        let data = Data(repeating: UInt8(0x82 + value), count: 16)
        let digest = BlobDigest.sha256(of: data)
        stages.append(
          try await store.stage(data: data, digest: digest, partition: partition)
        )
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)
      for stage in stages { await store.discard(stage) }
    }
  }

  @Test("AKASHIC-CT-174 failed manifest sidecar write recounts metadata headroom before retry")
  func failedManifestSidecarWriteRecountsRecoveryHeadroom() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      let partition = try fileBlobStoreTestPartition("directory-manifest-failure-recount")
      let fault = DirectoryRecoverabilityOneShotManifestFault()
      let store = try await FileBlobStore.open(
        root: root,
        limits: limits,
        faultInjector: { point in
          if point == .afterManifestDataWritten, fault.take() {
            throw DirectoryRecoverabilityInjectedError.manifestWrite
          }
        }
      )
      let data = Data(repeating: 0x91, count: 16)
      let digest = BlobDigest.sha256(of: data)
      let stage = try await store.stage(data: data, digest: digest, partition: partition)
      #expect(try directBlobDirectoryEntryCount(root: root) == 1)

      do {
        _ = try await store.publish(stage)
        Issue.record("expected injected manifest sidecar failure")
      } catch DirectoryRecoverabilityInjectedError.manifestWrite {
        // Expected before manifest rename: payload remains staged but not authoritative.
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 1)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: digest, partition: partition)
      }

      await store.discard(stage)
      #expect(try directBlobDirectoryEntryCount(root: root) == 0)

      var stages: [BlobStage] = []
      for value in 0..<3 {
        let nextData = Data(repeating: UInt8(0x92 + value), count: 16)
        let nextDigest = BlobDigest.sha256(of: nextData)
        stages.append(
          try await store.stage(data: nextData, digest: nextDigest, partition: partition)
        )
      }
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)
      for nextStage in stages { await store.discard(nextStage) }
    }
  }

  @Test("AKASHIC-CT-171 staged payload removal returns recovery headroom without a directory rescan")
  func stagedPayloadRemovalReturnsRecoveryHeadroom() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      let store = try await FileBlobStore.open(root: root, limits: limits)
      let partition = try fileBlobStoreTestPartition("directory-stage-reuse")
      let payloads = (1...4).map { value in Data(repeating: UInt8(0x60 + value), count: 16) }
      let digests = payloads.map(BlobDigest.sha256(of:))

      let first = try await store.stage(data: payloads[0], digest: digests[0], partition: partition)
      let second = try await store.stage(data: payloads[1], digest: digests[1], partition: partition)
      let third = try await store.stage(data: payloads[2], digest: digests[2], partition: partition)
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)

      await expectFileBlobStoreTestAkashicError(.limitExceeded) {
        _ = try await store.stage(data: payloads[3], digest: digests[3], partition: partition)
      }

      await store.discard(second)
      #expect(try directBlobDirectoryEntryCount(root: root) == 2)
      let fourth = try await store.stage(data: payloads[3], digest: digests[3], partition: partition)
      #expect(try directBlobDirectoryEntryCount(root: root) == 3)

      await store.discard(first)
      await store.discard(third)
      await store.discard(fourth)
      #expect(try directBlobDirectoryEntryCount(root: root) == 0)
    }
  }
}

private enum DirectoryRecoverabilityInjectedError: Error {
  case stageWrite
  case manifestWrite
}

private final class DirectoryRecoverabilityOneShotManifestFault: @unchecked Sendable {
  private let lock = NSLock()
  private var available = true

  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard available else { return false }
    available = false
    return true
  }
}

private final class DirectoryRecoverabilityOneShotFault: @unchecked Sendable {
  private let lock = NSLock()
  private var available = true

  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard available else { return false }
    available = false
    return true
  }
}

private func directBlobDirectoryEntryCount(root: URL) throws -> Int {
  try FileManager.default.contentsOfDirectory(
    at: root.appendingPathComponent("blobs", isDirectory: true),
    includingPropertiesForKeys: nil,
    options: []
  ).count
}

private func directoryRecoverabilityHardFailXattr(
  _ descriptor: Int32,
  _ name: String,
  _ data: Data
) -> Int32 {
  _ = descriptor
  _ = name
  _ = data
  errno = EIO
  return -1
}

private func directoryRecoverabilityUnsupportedXattr(
  _ descriptor: Int32,
  _ name: String,
  _ data: Data
) -> Int32 {
  _ = descriptor
  _ = name
  _ = data
  errno = ENOTSUP
  return -1
}
