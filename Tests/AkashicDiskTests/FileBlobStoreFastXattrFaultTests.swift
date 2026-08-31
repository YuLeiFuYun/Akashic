import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk fast xattr syscall classification")
struct FileBlobStoreFastXattrFaultTests {
  @Test("AKASHIC-CT-071 only explicit xattr incompatibility falls back to sidecar")
  func xattrUnsupportedFallbackAndHardErrorsRemainDistinct() async throws {
    try await withManifestTestTemporaryDirectory { parent in
      for code in [POSIXErrorCode.ENOTSUP, .E2BIG] {
        let root = parent.appendingPathComponent("unsupported-\(code.rawValue)", isDirectory: true)
        let data = Data("xattr-fallback-\(code.rawValue)".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("xattr-fallback-\(code.rawValue)")
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          fastCommitOperations: FileBlobStoreFastCommitOperations(
            setManifestXattr: failingManifestXattrSetOperation(code)
          )
        )

        let publication = try await store!.commit(
          data: data,
          digest: digest,
          partition: partition
        )

        #expect(publication.disposition == .created)
        #expect(try await store!.read(digest: digest, partition: partition) == data)
        #expect(manifestRecordFiles(in: root).count == 1)
        #expect(manifestTestBlobFiles(in: root).count == 1)
        #expect(try manifestXattrRecordCount(in: root, generation: 1) == 0)
        #expect(fastTransactionTemporaryFiles(in: root).isEmpty)

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        #expect(try await reopened.read(digest: digest, partition: partition) == data)
      }

      for code in [POSIXErrorCode.ENOSPC, .EIO] {
        let root = parent.appendingPathComponent("hard-error-\(code.rawValue)", isDirectory: true)
        let data = Data("xattr-hard-error-\(code.rawValue)".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("xattr-hard-error-\(code.rawValue)")
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          fastCommitOperations: FileBlobStoreFastCommitOperations(
            setManifestXattr: failingManifestXattrSetOperation(code)
          )
        )

        await expectFastXattrPOSIXError(code) {
          try await store!.commit(data: data, digest: digest, partition: partition)
        }
        #expect(await store!.physicalID(digest: digest, partition: partition) == nil)
        await expectManifestTestAkashicError(.notFound) {
          try await store!.read(digest: digest, partition: partition)
        }
        #expect(manifestRecordFiles(in: root).isEmpty)
        #expect(manifestTestBlobFiles(in: root).isEmpty)
        #expect(fastTransactionTemporaryFiles(in: root).isEmpty)

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await FileBlobStore.open(root: root)
        await expectManifestTestAkashicError(.notFound) {
          try await reopened.read(digest: digest, partition: partition)
        }
      }
    }
  }

  @Test("T102 sidecar fallback reserves two slots while unrelated staged data occupies the third")
  func sidecarFallbackRespectsRecoveryBudgetWithStagedPressure() async throws {
    try await withManifestTestTemporaryDirectory { parent in
      let root = parent.appendingPathComponent("sidecar-three-slot-budget", isDirectory: true)
      let limits = FileBlobStoreLimits(
        softTotalBytes: 1_024,
        maximumBlobBytes: 1_024,
        maximumDirectoryEntryCount: 3
      )
      let data = Data(repeating: 0x6a, count: 32)
      let digest = BlobDigest.sha256(of: data)
      let stagedData = Data(repeating: 0x6b, count: 32)
      let stagedDigest = BlobDigest.sha256(of: stagedData)
      let partition = try manifestTestPartition("sidecar-three-slot-budget")
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        limits: limits,
        faultInjector: { _ in },
        fastCommitOperations: FileBlobStoreFastCommitOperations(
          setManifestXattr: failingManifestXattrSetOperation(.ENOTSUP)
        )
      )

      let staged = try await store!.stage(
        data: stagedData,
        digest: stagedDigest,
        partition: partition
      )
      _ = try await store!.commit(data: data, digest: digest, partition: partition)
      let blobs = root.appendingPathComponent("blobs", isDirectory: true)
      #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 3)
      #expect(manifestRecordFiles(in: root).count == 1)
      #expect(manifestTestBlobFiles(in: root).count == 2)

      await store!.discard(staged)
      #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 2)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root, limits: limits)
      #expect(try await reopened.read(digest: digest, partition: partition) == data)
    }
  }

}

private func failingManifestXattrSetOperation(
  _ code: POSIXErrorCode
) -> FileBlobStoreManifestXattrSetOperation {
  { _, _, _ in
    errno = code.rawValue
    return -1
  }
}

private func fastTransactionTemporaryFiles(in root: URL) -> [URL] {
  let blobs = root.appendingPathComponent("blobs", isDirectory: true)
  let children =
    (try? FileManager.default.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: []
    )) ?? []
  return children.filter {
    let name = $0.lastPathComponent
    return name.hasPrefix(".fast-xattr-blob-")
      || name.hasPrefix(".fast-blob-")
      || name.hasPrefix(".fast-record-")
  }
}

private func expectFastXattrPOSIXError<T>(
  _ expected: POSIXErrorCode,
  operation: () async throws -> T
) async {
  do {
    _ = try await operation()
    Issue.record("Expected POSIXError.\(expected)")
  } catch let error as POSIXError {
    #expect(error.code == expected)
  } catch {
    Issue.record("Expected POSIXError.\(expected), received \(error)")
  }
}
