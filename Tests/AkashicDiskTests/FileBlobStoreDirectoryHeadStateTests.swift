import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk directory-head state and fault protocol")
struct FileBlobStoreDirectoryHeadStateTests {
  @Test("AKASHIC-CT-098 committed directory-head record deletion fails closed on reopen")
  func committedDirectoryHeadCarrierDeletionFailsClosedOnStoreOpen() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let data = Data("schema4-current-record-deletion".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-current-record-deletion")
      _ = try await store!.commit(data: data, digest: digest, partition: partition)
      let currentRecord = try #require(
        memory.attributeNames().first { $0.hasPrefix("dev.akashic.md1.") }
      )

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      memory.remove(currentRecord)
      await expectManifestTestAkashicError(.invalidManifest) {
        _ = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          directoryHeadOperations: memory.operations
        )
      }
    }
  }

  @Test("AKASHIC-CT-099 consecutive schema4 checkpoints bound older metadata debt")
  func consecutiveMultiKeyCheckpointsRetireOlderDirectoryHeadDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let partitionA = try manifestTestPartition("schema4-checkpoint-a")
      let partitionB = try manifestTestPartition("schema4-checkpoint-b")
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      for index in 0..<2 {
        let data = Data("schema4-a-\(index)".utf8)
        _ = try await store.commit(
          data: data,
          digest: BlobDigest.sha256(of: data),
          partition: partitionA
        )
      }
      for index in 0..<2 {
        let data = Data("schema4-b-\(index)".utf8)
        _ = try await store.commit(
          data: data,
          digest: BlobDigest.sha256(of: data),
          partition: partitionB
        )
      }
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation2 = await store.manifest.generation
      try await store.removeAll(partition: partitionA)
      let generation3 = await store.manifest.generation
      #expect(generation3 == generation2 + 1)
      #expect(await store.staleDirectoryHeadCleanupQueue.count == 2)

      try await store.removeAll(partition: partitionB)
      let generation4 = await store.manifest.generation
      #expect(generation4 == generation3 + 1)
      #expect(await store.staleDirectoryHeadCleanupQueue.count == 2)
      for slot: UInt8 in [0, 1] {
        #expect(!memory.attributeNames().contains(
          FileBlobStore.DirectoryHeadIdentity(generation: generation2, slot: slot).name
        ))
        #expect(memory.attributeNames().contains(
          FileBlobStore.DirectoryHeadIdentity(generation: generation3, slot: slot).name
        ))
        #expect(memory.attributeNames().contains(
          FileBlobStore.DirectoryHeadIdentity(generation: generation4, slot: slot).name
        ))
      }
    }
  }

  @Test("AKASHIC-CT-100 reopen reconstructs stale directory-head cleanup debt")
  func reopenRebuildsOlderGenerationMetadataDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let partitionA = try manifestTestPartition("schema4-rebuild-a")
      let partitionB = try manifestTestPartition("schema4-rebuild-b")
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      for (partition, prefix) in [(partitionA, "a"), (partitionB, "b")] {
        for index in 0..<2 {
          let data = Data("schema4-rebuild-\(prefix)-\(index)".utf8)
          _ = try await store!.commit(
            data: data,
            digest: BlobDigest.sha256(of: data),
            partition: partition
          )
        }
      }
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let retiredGeneration = await store!.manifest.generation
      try await store!.removeAll(partition: partitionA)
      #expect(await store!.staleDirectoryHeadCleanupQueue.count == 2)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(await store!.staleDirectoryHeadCleanupQueue.count == 2)
      try await store!.removeAll(partition: partitionB)
      #expect(await store!.staleDirectoryHeadCleanupQueue.count == 2)
      for slot: UInt8 in [0, 1] {
        #expect(!memory.attributeNames().contains(
          FileBlobStore.DirectoryHeadIdentity(generation: retiredGeneration, slot: slot).name
        ))
      }
    }
  }

  @Test("AKASHIC-CT-101 stale metadata cleanup failure blocks the next checkpoint pre-authority")
  func staleMetadataCleanupFailureDoesNotAdvanceCheckpointAuthority() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let partitionA = try manifestTestPartition("schema4-cleanup-fail-a")
      let partitionB = try manifestTestPartition("schema4-cleanup-fail-b")
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      var bFixtures: [(BlobDigest, Data)] = []
      for index in 0..<2 {
        let data = Data("schema4-cleanup-a-\(index)".utf8)
        _ = try await store.commit(
          data: data,
          digest: BlobDigest.sha256(of: data),
          partition: partitionA
        )
      }
      for index in 0..<2 {
        let data = Data("schema4-cleanup-b-\(index)".utf8)
        let digest = BlobDigest.sha256(of: data)
        bFixtures.append((digest, data))
        _ = try await store.commit(data: data, digest: digest, partition: partitionB)
      }
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation2 = await store.manifest.generation
      try await store.removeAll(partition: partitionA)
      let generation3 = await store.manifest.generation
      #expect(generation3 == generation2 + 1)
      #expect(await store.staleDirectoryHeadCleanupQueue.count == 2)

      for slot: UInt8 in [0, 1] {
        memory.failRemove(
          name: FileBlobStore.DirectoryHeadIdentity(
            generation: generation2,
            slot: slot
          ).name,
          code: .EIO
        )
      }
      do {
        try await store.removeAll(partition: partitionB)
        Issue.record("Expected stale directory-head cleanup failure")
      } catch let error as POSIXError {
        #expect(error.code == .EIO)
      } catch {
        Issue.record("Expected POSIX EIO, received \(error)")
      }

      #expect(await store.manifest.generation == generation3)
      #expect(!(await store.requiresReopenBeforeFurtherAccess))
      #expect(await store.staleDirectoryHeadCleanupQueue.count == 2)
      for (digest, data) in bFixtures {
        #expect(try await store.read(digest: digest, partition: partitionB) == data)
      }
      for slot: UInt8 in [0, 1] {
        #expect(!memory.attributeNames().contains(
          FileBlobStore.DirectoryHeadIdentity(
            generation: generation3 + 1,
            slot: slot
          ).name
        ))
      }

      memory.clearRemoveFailures()
      try await store.removeAll(partition: partitionB)
      #expect(await store.manifest.generation == generation3 + 1)
      #expect(await store.staleDirectoryHeadCleanupQueue.count == 2)
      for (digest, _) in bFixtures {
        await expectManifestTestAkashicError(.notFound) {
          _ = try await store.read(digest: digest, partition: partitionB)
        }
      }
    }
  }

  @Test("AKASHIC-CT-102 directory-head record write failure freezes writer and reopens old state")
  func directoryHeadRecordWriteFailureRecoversOldState() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation
      let data = Data("schema4-record-set-failure".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-record-set-failure")
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      let recordIdentity = try FileBlobStore.DirectoryHeadRecordIdentity.make(
        generation: generation,
        sequence: 1,
        key: key
      )
      memory.failSet(name: recordIdentity.name, code: .EIO)

      do {
        _ = try await store!.commit(data: data, digest: digest, partition: partition)
        Issue.record("Expected directory-head record write failure")
      } catch let error as POSIXError {
        #expect(error.code == .EIO)
      } catch {
        Issue.record("Expected POSIX EIO, received \(error)")
      }
      #expect(await store!.requiresReopenBeforeFurtherAccess)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      memory.clearSetFailures()
      let reopened = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      await expectManifestTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: partition)
      }
      #expect(manifestTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-103 directory-head head-write failure leaves body uncommitted")
  func directoryHeadHeadWriteFailureRecoversOldState() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation
      let recoveredState = try #require(await store!.directoryHeadState)
      let inactiveSlot = UInt8(1 - recoveredState.activeSlot)
      let inactiveHeadName = FileBlobStore.DirectoryHeadIdentity(
        generation: generation,
        slot: inactiveSlot
      ).name
      memory.failSet(name: inactiveHeadName, code: .EIO)
      let data = Data("schema4-head-set-failure".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-head-set-failure")

      do {
        _ = try await store!.commit(data: data, digest: digest, partition: partition)
        Issue.record("Expected directory-head head replacement failure")
      } catch let error as POSIXError {
        #expect(error.code == .EIO)
      } catch {
        Issue.record("Expected POSIX EIO, received \(error)")
      }
      #expect(await store!.requiresReopenBeforeFurtherAccess)
      #expect(memory.attributeNames().filter { $0.hasPrefix("dev.akashic.md1.") }.count == 1)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      memory.clearSetFailures()
      let reopened = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      await expectManifestTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.directoryHeadState?.activeHead.s == 0)
      #expect(await reopened.directoryHeadState?.uncommittedRecordNames.count == 1)
      #expect(manifestTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-104 directory sync failure after head update recovers new state")
  func directoryHeadSynchronizationFailureRecoversCommittedHead() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let data = Data("schema4-directory-sync-failure".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-directory-sync-failure")
      memory.failNextSynchronize()

      do {
        _ = try await store!.commit(data: data, digest: digest, partition: partition)
        Issue.record("Expected directory-head directory synchronization failure")
      } catch let error as POSIXError {
        #expect(error.code == .EIO)
      } catch {
        Issue.record("Expected POSIX EIO, received \(error)")
      }
      #expect(await store!.requiresReopenBeforeFurtherAccess)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await reopened.read(digest: digest, partition: partition) == data)
      #expect(await reopened.directoryHeadState?.activeHead.s == 1)
      #expect(!(await reopened.requiresReopenBeforeFurtherAccess))
    }
  }

  @Test("AKASHIC-CT-105 schema4 single-key commit coalesces payload and head directory durability")
  func schema4SingleKeyCommitUsesOneDirectoryDurabilityBoundary() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let gate = BlobDirectorySyncFaultGate()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { point in try gate.inject(point) },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      memory.resetSynchronizeCallCount()
      gate.setFailureEnabled(true)

      let data = Data("schema4-coalesced-single-key".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-coalesced-single-key")
      _ = try await store.commit(data: data, digest: digest, partition: partition)

      #expect(memory.synchronizeCallCount() == 1)
      #expect(gate.observedBlobDirectorySyncCount() == 0)
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-106 schema4 checkpoint boundary keeps the payload directory fsync")
  func schema4CheckpointBoundaryDoesNotCoalesceIntoRootManifestSync() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let gate = BlobDirectorySyncFaultGate()
      let partition = try manifestTestPartition("schema4-checkpoint-durability")
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 4 * 1024 * 1024,
          maximumBlobBytes: 128
        ),
        faultInjector: { point in try gate.inject(point) },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())

      for index in 0..<511 {
        let data = Data("schema4-checkpoint-prefix-\(index)".utf8)
        _ = try await store.commit(
          data: data,
          digest: BlobDigest.sha256(of: data),
          partition: partition
        )
      }
      let generationBeforeBoundary = await store.manifest.generation
      #expect(await store.directoryHeadState?.activeHead.c == 511)
      #expect(gate.observedBlobDirectorySyncCount() == 0)

      let boundaryData = Data("schema4-checkpoint-boundary-511".utf8)
      let boundaryDigest = BlobDigest.sha256(of: boundaryData)
      gate.setFailureEnabled(true)
      do {
        _ = try await store.commit(
          data: boundaryData,
          digest: boundaryDigest,
          partition: partition
        )
        Issue.record("Expected the non-coalesced payload directory sync to fail")
      } catch let error as POSIXError {
        #expect(error.code == .EIO)
      } catch {
        Issue.record("Expected POSIX EIO, received \(error)")
      }

      #expect(gate.observedBlobDirectorySyncCount() == 1)
      #expect(await store.manifest.generation == generationBeforeBoundary)
      #expect(!(await store.requiresReopenBeforeFurtherAccess))
      await expectManifestTestAkashicError(.notFound) {
        _ = try await store.read(digest: boundaryDigest, partition: partition)
      }

      gate.setFailureEnabled(false)
      _ = try await store.commit(
        data: boundaryData,
        digest: boundaryDigest,
        partition: partition
      )
      #expect(await store.manifest.generation == generationBeforeBoundary + 1)
      #expect(gate.observedBlobDirectorySyncCount() == 2)
      #expect(try await store.read(digest: boundaryDigest, partition: partition) == boundaryData)
    }
  }

  @Test("AKASHIC-CT-107 schema4 ownership index matches full proof across create remove and repair")
  func schema4OwnershipIndexMatchesFullManifestProof() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 4 * 1024 * 1024,
          maximumBlobBytes: 256
        ),
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      try await expectOwnershipIndexMatchesFullProof(store)

      let partition = try manifestTestPartition("schema4-ownership-differential")
      var fixtures: [(BlobDigest, Data)] = []
      for index in 0..<24 {
        let data = Data("schema4-ownership-\(index)".utf8)
        let digest = BlobDigest.sha256(of: data)
        fixtures.append((digest, data))
        _ = try await store.commit(data: data, digest: digest, partition: partition)
        try await expectOwnershipIndexMatchesFullProof(store)
      }

      for index in stride(from: 0, to: fixtures.count, by: 3) {
        try await store.remove(digest: fixtures[index].0, partition: partition)
        try await expectOwnershipIndexMatchesFullProof(store)
      }

      let repairIndex = 1
      let repair = fixtures[repairIndex]
      let oldPhysicalID = try #require(
        await store.physicalID(digest: repair.0, partition: partition)
      )
      try FileManager.default.removeItem(at: root
        .appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(oldPhysicalID.rawValue.uuidString.lowercased()))
      _ = try await store.commit(
        data: repair.1,
        digest: repair.0,
        partition: partition
      )
      let newPhysicalID = try #require(
        await store.physicalID(digest: repair.0, partition: partition)
      )
      #expect(newPhysicalID != oldPhysicalID)
      try await expectOwnershipIndexMatchesFullProof(store)
    }
  }

  @Test("AKASHIC-CT-108 schema4 O1 ownership proof rejects duplicate PhysicalBlobID before publication")
  func schema4OwnershipIndexRejectsDuplicatePhysicalOwner() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())

      let firstData = Data("schema4-owner-first".utf8)
      let firstDigest = BlobDigest.sha256(of: firstData)
      let firstPartition = try manifestTestPartition("schema4-owner-first")
      _ = try await store.commit(
        data: firstData,
        digest: firstDigest,
        partition: firstPartition
      )
      let firstPhysicalID = try #require(
        await store.physicalID(digest: firstDigest, partition: firstPartition)
      )
      let sequenceBefore = try #require(await store.directoryHeadState?.activeHead.s)
      let attributesBefore = Set(memory.attributeNames())

      let secondData = Data("schema4-owner-second".utf8)
      let secondDigest = BlobDigest.sha256(of: secondData)
      let secondPartition = try manifestTestPartition("schema4-owner-second")
      let secondKey = FileBlobStoreIdentity.manifestKey(
        digest: secondDigest,
        partition: secondPartition
      )
      let duplicateOwnerEntry = FileBlobStore.Entry(
        physicalID: firstPhysicalID,
        partition: secondPartition,
        digest: secondDigest,
        byteCount: secondData.count,
        lastAccess: Date()
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await store.persistSingleKeyManifestEntry(
          key: secondKey,
          entry: duplicateOwnerEntry
        )
      }

      #expect(await store.directoryHeadState?.activeHead.s == sequenceBefore)
      #expect(Set(memory.attributeNames()) == attributesBefore)
      #expect(try await store.read(digest: firstDigest, partition: firstPartition) == firstData)
      await expectManifestTestAkashicError(.notFound) {
        _ = try await store.read(digest: secondDigest, partition: secondPartition)
      }
      try await expectOwnershipIndexMatchesFullProof(store)
    }
  }

  @Test("AKASHIC-CT-109 schema4 cached live bytes drives trim without stale resource state")
  func schema4OwnershipTotalKeepsTrimBounded() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        ),
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      let partition = try manifestTestPartition("schema4-trim-live-bytes")
      var fixtures: [(BlobDigest, Data)] = []
      for index in 0..<3 {
        var data = Data(repeating: UInt8(0x40 + index), count: 40)
        data[0] = UInt8(index)
        let digest = BlobDigest.sha256(of: data)
        fixtures.append((digest, data))
        _ = try await store.commit(data: data, digest: digest, partition: partition)
        try await expectOwnershipIndexMatchesFullProof(store)
        let cached = try #require(await store.manifestOwnershipIndex)
        #expect(cached.totalBytes <= 64)
      }
      #expect(await store.manifest.entries.count == 1)
      #expect(try await store.read(digest: fixtures[2].0, partition: partition) == fixtures[2].1)
    }
  }
}
