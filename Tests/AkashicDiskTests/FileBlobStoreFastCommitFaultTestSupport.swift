import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

final class FastCommitFaultState: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [String: Int] = [:]

  func increment(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    let next = (counts[key] ?? 0) + 1
    counts[key] = next
    return next
  }

  func value(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return counts[key] ?? 0
  }
}

func faultInjectedFastStore(
  root: URL,
  operations: FileBlobStoreFastCommitOperations
) async throws -> FileBlobStore {
  try await FileBlobStore.open(
    root: root,
    faultInjector: { _ in },
    fastCommitOperations: operations
  )
}

func verifyFastCommitSuccess(
  root: URL,
  label: String,
  operations: FileBlobStoreFastCommitOperations
) async throws {
  let data = Data((label + "-payload").utf8)
  let digest = BlobDigest.sha256(of: data)
  let partition = try manifestTestPartition(label)
  let store = try await faultInjectedFastStore(root: root, operations: operations)
  let publication = try await store.commit(data: data, digest: digest, partition: partition)
  #expect(publication.disposition == .created)
  #expect(try await store.read(digest: digest, partition: partition) == data)
  #expect(fastFaultTemporaryFiles(in: root).isEmpty)
}

func verifyFastCommitHardFailure(
  root: URL,
  label: String,
  expected: POSIXErrorCode,
  operations: FileBlobStoreFastCommitOperations
) async throws {
  let data = Data((label + "-payload").utf8)
  let digest = BlobDigest.sha256(of: data)
  let partition = try manifestTestPartition(label)
  let store = try await faultInjectedFastStore(root: root, operations: operations)
  await expectFastCommitPOSIXError(expected) {
    try await store.commit(data: data, digest: digest, partition: partition)
  }
  try await expectFastCommitMissAndNoPhysicalAuthority(
    store: store,
    root: root,
    digest: digest,
    partition: partition
  )
}

func verifyPostRenameFastCommitFailure(
  root: URL,
  label: String,
  expected: POSIXErrorCode,
  operations: FileBlobStoreFastCommitOperations
) async throws {
  let data = Data((label + "-payload").utf8)
  let digest = BlobDigest.sha256(of: data)
  let partition = try manifestTestPartition(label)
  var store: FileBlobStore? = try await faultInjectedFastStore(root: root, operations: operations)

  await expectFastCommitPOSIXError(expected) {
    try await store!.commit(data: data, digest: digest, partition: partition)
  }
  #expect(await store!.physicalID(digest: digest, partition: partition) == nil)
  await expectManifestTestAkashicError(.storageUnavailable) {
    try await store!.read(digest: digest, partition: partition)
  }
  #expect(manifestRecordFiles(in: root).isEmpty)
  #expect(manifestTestBlobFiles(in: root).count == 1)
  #expect(try manifestXattrRecordCount(in: root, generation: 1) == 1)
  #expect(fastFaultTemporaryFiles(in: root).isEmpty)

  store = nil
  try await waitForWriterLeaseRelease(root: root)
  let reopened = try await FileBlobStore.open(root: root)
  #expect(try await reopened.read(digest: digest, partition: partition) == data)
}

func expectFastCommitMissAndNoPhysicalAuthority(
  store: FileBlobStore,
  root: URL,
  digest: BlobDigest,
  partition: CachePartitionID
) async throws {
  #expect(await store.physicalID(digest: digest, partition: partition) == nil)
  await expectManifestTestAkashicError(.notFound) {
    try await store.read(digest: digest, partition: partition)
  }
  #expect(manifestRecordFiles(in: root).isEmpty)
  #expect(manifestTestBlobFiles(in: root).isEmpty)
  #expect(fastFaultTemporaryFiles(in: root).isEmpty)
}

func fastFaultTemporaryFiles(in root: URL) -> [URL] {
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

func expectFastCommitPOSIXError<T>(
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
