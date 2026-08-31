import AkashicCore
import Darwin
import Dispatch
import Foundation
import Testing

@testable import AkashicDisk

private final class ConcurrentReadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var activeBytes = 0
  private var peak = 0
  private var peakBytes = 0
  private var calls = 0
  private let delayMicroseconds: useconds_t
  private let blockFirst: Bool
  let firstEntered = DispatchSemaphore(value: 0)
  private let firstRelease = DispatchSemaphore(value: 0)

  init(delayMicroseconds: useconds_t = 0, blockFirst: Bool = false) {
    self.delayMicroseconds = delayMicroseconds
    self.blockFirst = blockFirst
  }

  func read(_ url: URL, _ maximumBytes: Int, _ expectedBytes: Int?) throws
    -> BoundedFileReadResult
  {
    let call: Int
    let bytes = max(0, expectedBytes ?? 0)
    lock.lock()
    calls += 1
    call = calls
    active += 1
    activeBytes += bytes
    peak = max(peak, active)
    peakBytes = max(peakBytes, activeBytes)
    lock.unlock()
    defer {
      lock.lock()
      active -= 1
      activeBytes -= bytes
      lock.unlock()
    }

    if blockFirst, call == 1 {
      firstEntered.signal()
      firstRelease.wait()
    }
    if delayMicroseconds > 0 { usleep(delayMicroseconds) }
    return try BoundedFileReader.readWithMetadata(
      from: url,
      maximumBytes: maximumBytes,
      expectedBytes: expectedBytes
    )
  }

  func waitForFirstEntry() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          returning: self.firstEntered.wait(timeout: .now() + 2) == .success
        )
      }
    }
  }

  func releaseFirst() {
    firstRelease.signal()
  }

  var peakActive: Int {
    lock.lock()
    defer { lock.unlock() }
    return peak
  }

  var peakActiveBytes: Int {
    lock.lock()
    defer { lock.unlock() }
    return peakBytes
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
}

@Suite("AkashicDisk concurrent verified reads")
struct FileBlobStoreConcurrentReadTests {
  @Test("AKASHIC-CT-133 verified payload reads use a bounded four-worker blocking-I/O pool")
  func verifiedReadsUseBoundedConcurrentWorkers() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let recorder = ConcurrentReadRecorder(delayMicroseconds: 20_000)
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: .system,
        readOperations: FileBlobStoreReadOperations(read: recorder.read)
      )
      let partition = try fileBlobStoreTestPartition("concurrent-worker-bound")
      var items: [(Data, BlobDigest)] = []
      for index in 0..<8 {
        var data = Data(repeating: UInt8(index), count: 4_096)
        data[0] = UInt8(index &* 17)
        let digest = BlobDigest.sha256(of: data)
        _ = try await store.commit(data: data, digest: digest, partition: partition)
        items.append((data, digest))
      }
      let frozenItems = items

      let results = try await withThrowingTaskGroup(of: Bool.self) { group in
        for index in 0..<16 {
          group.addTask {
            let item = frozenItems[index % frozenItems.count]
            return try await store.read(digest: item.1, partition: partition) == item.0
          }
        }
        var values: [Bool] = []
        for try await value in group { values.append(value) }
        return values
      }

      #expect(results.allSatisfy { $0 })
      #expect(recorder.peakActive == FileBlobStoreReadIO.maximumConcurrentReads)
      #expect(recorder.peakActive == 4)
    }
  }

  @Test("AKASHIC-CT-134 remove while a snapped read is waiting does not quarantine stale authority")
  func removeWhileReadWaitsReturnsNotFound() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: .system,
        readOperations: FileBlobStoreReadOperations(read: recorder.read)
      )
      let partition = try fileBlobStoreTestPartition("concurrent-read-remove")
      let data = Data(repeating: 0x34, count: 16_384)
      let digest = BlobDigest.sha256(of: data)
      _ = try await store.commit(data: data, digest: digest, partition: partition)

      let readTask = Task { try await store.read(digest: digest, partition: partition) }
      let entered = await recorder.waitForFirstEntry()
      #expect(entered)
      defer { recorder.releaseFirst() }
      try await store.remove(digest: digest, partition: partition)
      recorder.releaseFirst()

      await expectFileBlobStoreTestAkashicError(.notFound) {
        try await readTask.value
      }
      await expectFileBlobStoreTestAkashicError(.notFound) {
        try await store.read(digest: digest, partition: partition)
      }
    }
  }

  @Test("AKASHIC-CT-135 failed read of an old carrier retries one same-key physical repair")
  func oldCarrierFailureRetriesCurrentReplacement() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: .system,
        readOperations: FileBlobStoreReadOperations(read: recorder.read)
      )
      let partition = try fileBlobStoreTestPartition("concurrent-read-repair")
      let data = Data(repeating: 0x57, count: 16_384)
      let digest = BlobDigest.sha256(of: data)
      let original = try await store.commit(data: data, digest: digest, partition: partition)
      let originalURL = fileBlobStoreTestBlobURL(root: root, id: original.physicalID)

      let readTask = Task { try await store.read(digest: digest, partition: partition) }
      let entered = await recorder.waitForFirstEntry()
      #expect(entered)
      defer { recorder.releaseFirst() }
      try FileManager.default.removeItem(at: originalURL)
      let replacement = try await store.commit(data: data, digest: digest, partition: partition)
      #expect(replacement.physicalID != original.physicalID)
      recorder.releaseFirst()

      #expect(try await readTask.value == data)
      #expect(recorder.callCount == 2)
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-138 cancelling a pending read removes it before blocking I/O")
  func cancellingPendingReadDoesNotConsumeWorker() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let data = Data(repeating: 0x4C, count: 4_096)
      let url = root.appendingPathComponent("cancel-pending-read")
      try writePrivateFile(data, to: url)
      let digest = BlobDigest.sha256(of: data)
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let scheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 1,
        maximumInFlightBytes: 8_192,
        operations: FileBlobStoreReadOperations(read: recorder.read)
      )

      let first = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      #expect(await recorder.waitForFirstEntry())
      defer { recorder.releaseFirst() }

      let cancelled = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      try await Task.sleep(for: .milliseconds(5))
      cancelled.cancel()
      let third = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      recorder.releaseFirst()

      #expect(try await first.value.data == data)
      do {
        _ = try await cancelled.value
        Issue.record("cancelled pending read unexpectedly returned bytes")
      } catch is CancellationError {
      } catch {
        Issue.record("cancelled pending read returned unexpected error: \(error)")
      }
      #expect(try await third.value.data == data)
      #expect(recorder.callCount == 2)
    }
  }

  @Test("AKASHIC-CT-137 verified reads obey worker and in-flight byte bounds")
  func verifiedReadsObeyByteBudget() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
      )
      let smallData = Data(repeating: 0xA5, count: 4_096)
      let smallURL = root.appendingPathComponent("small-read")
      try writePrivateFile(smallData, to: smallURL)
      let smallRecorder = ConcurrentReadRecorder(delayMicroseconds: 20_000)
      let smallScheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 4,
        maximumInFlightBytes: 8_192,
        operations: FileBlobStoreReadOperations(read: smallRecorder.read)
      )
      let smallDigest = BlobDigest.sha256(of: smallData)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
          group.addTask {
            _ = try await smallScheduler.readVerified(
              from: smallURL,
              maximumBytes: smallData.count,
              expectedBytes: smallData.count,
              digest: smallDigest
            )
          }
        }
        try await group.waitForAll()
      }
      #expect(smallRecorder.peakActive == 2)
      #expect(smallRecorder.peakActiveBytes == 8_192)

      let largeData = Data(repeating: 0x5A, count: 12_288)
      let largeURL = root.appendingPathComponent("large-read")
      try writePrivateFile(largeData, to: largeURL)
      let largeRecorder = ConcurrentReadRecorder(delayMicroseconds: 20_000)
      let largeScheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 4,
        maximumInFlightBytes: 8_192,
        operations: FileBlobStoreReadOperations(read: largeRecorder.read)
      )
      let largeDigest = BlobDigest.sha256(of: largeData)
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
          group.addTask {
            _ = try await largeScheduler.readVerified(
              from: largeURL,
              maximumBytes: largeData.count,
              expectedBytes: largeData.count,
              digest: largeDigest
            )
          }
        }
        try await group.waitForAll()
      }
      #expect(largeRecorder.peakActive == 1)
      #expect(largeRecorder.peakActiveBytes == largeData.count)
    }
  }


  @Test("AKASHIC-CT-139 reverse pending-cancellation storms never enter blocking I/O")
  func reversePendingCancellationStormOnlyRunsSurvivor() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let data = Data(repeating: 0x6D, count: 4_096)
      let url = root.appendingPathComponent("cancel-storm-read")
      try writePrivateFile(data, to: url)
      let digest = BlobDigest.sha256(of: data)
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let scheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 1,
        maximumInFlightBytes: data.count,
        operations: FileBlobStoreReadOperations(read: recorder.read)
      )

      let first = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      #expect(await recorder.waitForFirstEntry())
      defer { recorder.releaseFirst() }

      let cancelled = (0..<256).map { _ in
        Task {
          try await scheduler.readVerified(
            from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
        }
      }
      let survivor = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      try await Task.sleep(for: .milliseconds(25))
      for task in cancelled.reversed() { task.cancel() }
      recorder.releaseFirst()

      #expect(try await first.value.data == data)
      for task in cancelled {
        do {
          _ = try await task.value
          Issue.record("cancelled pending read unexpectedly entered blocking I/O")
        } catch is CancellationError {
        } catch {
          Issue.record("cancelled pending read returned unexpected error: \(error)")
        }
      }
      #expect(try await survivor.value.data == data)
      #expect(recorder.callCount == 2)
    }
  }


  @Test("AKASHIC-CT-140 pending read queue has a hard recoverable bound")
  func pendingReadQueueHasHardRecoverableBound() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let data = Data(repeating: 0x71, count: 4_096)
      let url = root.appendingPathComponent("pending-bound-read")
      try writePrivateFile(data, to: url)
      let digest = BlobDigest.sha256(of: data)
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let scheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 1,
        maximumInFlightBytes: data.count,
        maximumPendingReads: 1,
        operations: FileBlobStoreReadOperations(read: recorder.read)
      )

      let first = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      #expect(await recorder.waitForFirstEntry())
      defer { recorder.releaseFirst() }

      let contenders = (0..<2).map { _ in
        Task {
          try await scheduler.readVerified(
            from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
        }
      }

      var completed: [Result<BoundedFileReadResult, any Error>] = []
      await withTaskGroup(of: Result<BoundedFileReadResult, any Error>.self) { group in
        for contender in contenders {
          group.addTask { await contender.result }
        }
        if let overflow = await group.next() {
          completed.append(overflow)
          switch overflow {
          case .failure(let error as AkashicError):
            #expect(error == .storageUnavailable)
          default:
            Issue.record("pending overflow did not fail with storageUnavailable")
          }
        }
        #expect(recorder.callCount == 1)
        recorder.releaseFirst()
        if let survivor = await group.next() { completed.append(survivor) }
      }

      #expect(try await first.value.data == data)
      #expect(completed.count == 2)
      #expect(completed.filter { if case .success = $0 { return true }; return false }.count == 1)
      #expect(recorder.callCount == 2)

      let recovered = try await scheduler.readVerified(
        from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      #expect(recovered.data == data)
      #expect(recorder.callCount == 3)
    }
  }


  @Test("T102 store-internal scheduler path preserves queue-full provenance")
  func storeInternalSchedulerPathPreservesQueueFullProvenance() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let data = Data(repeating: 0x72, count: 4_096)
      let url = root.appendingPathComponent("pending-provenance-read")
      try writePrivateFile(data, to: url)
      let digest = BlobDigest.sha256(of: data)
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let scheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 1,
        maximumInFlightBytes: data.count,
        maximumPendingReads: 1,
        operations: FileBlobStoreReadOperations(read: recorder.read)
      )

      let first = Task {
        try await scheduler.readVerifiedForStore(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      #expect(await recorder.waitForFirstEntry())
      defer { recorder.releaseFirst() }

      let contenders = (0..<2).map { _ in
        Task {
          try await scheduler.readVerifiedForStore(
            from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
        }
      }

      var completed: [Result<BoundedFileReadResult, any Error>] = []
      await withTaskGroup(of: Result<BoundedFileReadResult, any Error>.self) { group in
        for contender in contenders {
          group.addTask { await contender.result }
        }
        if let overflow = await group.next() {
          completed.append(overflow)
          switch overflow {
          case .failure(let error as FileBlobStoreReadSchedulingError):
            switch error {
            case .pendingQueueFull:
              break
            }
          default:
            Issue.record("store-internal pending overflow lost scheduling provenance")
          }
        }
        #expect(recorder.callCount == 1)
        recorder.releaseFirst()
        if let survivor = await group.next() { completed.append(survivor) }
      }

      #expect(try await first.value.data == data)
      #expect(completed.count == 2)
      #expect(completed.filter { if case .success = $0 { return true }; return false }.count == 1)
      #expect(recorder.callCount == 2)
    }
  }


  @Test("AKASHIC-CT-141 pending backing storage stays bounded behind an uncancelled FIFO head")
  func pendingBackingStorageStaysBoundedBehindBlockedHead() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let data = Data(repeating: 0x73, count: 4_096)
      let url = root.appendingPathComponent("pending-storage-bound-read")
      try writePrivateFile(data, to: url)
      let digest = BlobDigest.sha256(of: data)
      let recorder = ConcurrentReadRecorder(blockFirst: true)
      let scheduler = FileBlobStoreReadIO(
        maximumConcurrentReads: 1,
        maximumInFlightBytes: data.count,
        maximumPendingReads: 4,
        operations: FileBlobStoreReadOperations(read: recorder.read)
      )

      func waitForPendingCount(_ expected: Int) async -> Bool {
        for _ in 0..<2_000 {
          if scheduler.resourceSnapshot().pendingCount == expected { return true }
          await Task.yield()
        }
        return false
      }

      let first = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      #expect(await recorder.waitForFirstEntry())

      let anchor = Task {
        try await scheduler.readVerified(
          from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
      }
      #expect(await waitForPendingCount(1))

      for _ in 0..<128 {
        let churn = Task {
          try await scheduler.readVerified(
            from: url, maximumBytes: data.count, expectedBytes: data.count, digest: digest)
        }
        #expect(await waitForPendingCount(2))
        var snapshot = scheduler.resourceSnapshot()
        #expect(snapshot.pendingStorageSlots <= snapshot.maximumPendingStorageSlots)
        churn.cancel()
        do {
          _ = try await churn.value
          Issue.record("cancelled churn read unexpectedly completed")
        } catch is CancellationError {
        } catch {
          Issue.record("cancelled churn read returned unexpected error: \(error)")
        }
        #expect(await waitForPendingCount(1))
        snapshot = scheduler.resourceSnapshot()
        #expect(snapshot.pendingStorageSlots <= snapshot.maximumPendingStorageSlots)
      }

      let bounded = scheduler.resourceSnapshot()
      #expect(bounded.pendingCount == 1)
      #expect(bounded.pendingStorageSlots <= 8)
      #expect(bounded.maximumPendingStorageSlots == 8)
      #expect(recorder.callCount == 1)

      recorder.releaseFirst()
      #expect(try await first.value.data == data)
      #expect(try await anchor.value.data == data)
      #expect(recorder.callCount == 2)
    }
  }
}
