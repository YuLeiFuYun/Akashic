import AkashicCore
import Dispatch
import Foundation
import Testing

@testable import AkashicDisk

private final class CompletedReadProbe: @unchecked Sendable {
  private let completedSignal = DispatchSemaphore(value: 0)
  private let continueSignal = DispatchSemaphore(value: 0)

  func read(_ url: URL, _ maximumBytes: Int, _ expectedBytes: Int?) throws
    -> BoundedFileReadResult
  {
    let result = try BoundedFileReader.readWithMetadata(
      from: url,
      maximumBytes: maximumBytes,
      expectedBytes: expectedBytes
    )
    completedSignal.signal()
    continueSignal.wait()
    return result
  }

  func waitUntilCompleted() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let observed = self.completedSignal.wait(timeout: .now() + 2) == .success
        continuation.resume(returning: observed)
      }
    }
  }

  func continueRead() { continueSignal.signal() }
}

@Suite("AkashicDisk completed concurrent reads")
struct FileBlobStoreConcurrentReadCompletionTests {
  @Test("AKASHIC-CT-136 a completed old read may linearize before a concurrent remove")
  func completedReadReturnsSnapshotAfterRemove() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let probe = CompletedReadProbe()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: .system,
        readOperations: FileBlobStoreReadOperations(read: probe.read)
      )
      let partition = try fileBlobStoreTestPartition("concurrent-read-completed-remove")
      let data = Data(repeating: 0x6D, count: 16_384)
      let digest = BlobDigest.sha256(of: data)
      _ = try await store.commit(data: data, digest: digest, partition: partition)

      let readTask = Task { try await store.read(digest: digest, partition: partition) }
      let completed = await probe.waitUntilCompleted()
      #expect(completed)
      defer { probe.continueRead() }
      try await store.remove(digest: digest, partition: partition)
      probe.continueRead()

      #expect(try await readTask.value == data)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        try await store.read(digest: digest, partition: partition)
      }
    }
  }
}
