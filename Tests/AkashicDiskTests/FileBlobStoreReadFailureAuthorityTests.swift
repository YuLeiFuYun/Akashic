import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk read availability does not mutate authority")
struct FileBlobStoreReadFailureAuthorityTests {
  @Test("T102 scheduler queue pressure remains availability and preserves authority")
  func schedulerPressureDoesNotQuarantineCurrentCarrier() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let operations = QueuePressureReadOperations()
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 4_096,
          maximumBlobBytes: 4_096
        ),
        faultInjector: { _ in },
        directoryHeadOperations: .system,
        readOperations: FileBlobStoreReadOperations(read: operations.read)
      )
      let partition = try fileBlobStoreTestPartition("read-scheduler-pressure-authority")
      let data = Data(repeating: 0x6B, count: 1_024)
      let digest = BlobDigest.sha256(of: data)
      let publication = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      #expect(publication.disposition == .created)
      #expect(await store.physicalID(digest: digest, partition: partition) == publication.physicalID)

      operations.failNextWithQueuePressure()
      await expectFileBlobStoreTestAkashicError(.storageUnavailable) {
        _ = try await store.read(digest: digest, partition: partition)
      }

      // Resource admission failure must not become an integrity verdict or persistent tombstone.
      #expect(await store.physicalID(digest: digest, partition: partition) == publication.physicalID)
      #expect(try await store.read(digest: digest, partition: partition) == data)
      #expect(await store.physicalID(digest: digest, partition: partition) == publication.physicalID)
    }
  }
}

private final class QueuePressureReadOperations: @unchecked Sendable {
  private let lock = NSLock()
  private var shouldFailNext = false

  func failNextWithQueuePressure() {
    lock.lock()
    shouldFailNext = true
    lock.unlock()
  }

  func read(
    _ url: URL,
    _ maximumBytes: Int,
    _ expectedBytes: Int?
  ) throws -> BoundedFileReadResult {
    lock.lock()
    let shouldFail = shouldFailNext
    shouldFailNext = false
    lock.unlock()
    if shouldFail {
      throw FileBlobStoreReadSchedulingError.pendingQueueFull
    }
    return try FileBlobStoreReadOperations.systemRead(url, maximumBytes, expectedBytes)
  }
}
