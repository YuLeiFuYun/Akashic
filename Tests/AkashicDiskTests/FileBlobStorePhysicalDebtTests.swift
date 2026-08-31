import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk physical cleanup debt")
struct FileBlobStorePhysicalDebtTests {
  @Test("AKASHIC-CT-078 logical remove survives undeletable physical cleanup debt")
  func logicalRemoveSurvivesPhysicalDeletionFailure() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-remove".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-remove")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(data: data, digest: digest, partition: partition)
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      try setUserImmutable(blob, enabled: true)
      defer { try? setUserImmutable(blob, enabled: false) }

      // Logical deletion is authoritative even though physical unlink returns EPERM.
      try await store!.remove(digest: digest, partition: partition)
      await expectManifestTestAkashicError(.notFound) {
        try await store!.read(digest: digest, partition: partition)
      }
      #expect(await store!.physicalID(digest: digest, partition: partition) == nil)
      #expect(FileManager.default.fileExists(atPath: blob.path))

      let maintenanceLimits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: max(1, data.count)
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        try await store!.garbageCollect(retaining: [], limits: maintenanceLimits)
      }

      // Reopen must not let a logically irrelevant undeletable orphan block valid authority.
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root)
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
      #expect(FileManager.default.fileExists(atPath: blob.path))

      try setUserImmutable(blob, enabled: false)
      let cleanup = try await reopened.garbageCollect(retaining: [], limits: maintenanceLimits)
      #expect(cleanup.removedBlobCount == 1)
      #expect(cleanup.removedByteCount == data.count)
      #expect(!FileManager.default.fileExists(atPath: blob.path))
    }
  }

  @Test("AKASHIC-CT-079 removeAll keeps logical revoke atomic across partial physical cleanup")
  func removeAllSurvivesPartialPhysicalDeletionFailure() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let partition = try manifestTestPartition("physical-debt-remove-all")
      let first = Data("physical-debt-remove-all-a".utf8)
      let second = Data("physical-debt-remove-all-b".utf8)
      let firstDigest = BlobDigest.sha256(of: first)
      let secondDigest = BlobDigest.sha256(of: second)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let firstPublication = try await store!.commit(
        data: first,
        digest: firstDigest,
        partition: partition
      )
      _ = try await store!.commit(data: second, digest: secondDigest, partition: partition)
      let immutableBlob = manifestTestBlobURL(root: root, id: firstPublication.physicalID)
      try setUserImmutable(immutableBlob, enabled: true)
      defer { try? setUserImmutable(immutableBlob, enabled: false) }

      try await store!.removeAll(partition: partition)
      for digest in [firstDigest, secondDigest] {
        await expectManifestTestAkashicError(.notFound) {
          try await store!.read(digest: digest, partition: partition)
        }
      }
      #expect(manifestTestBlobFiles(in: root).count == 1)
      #expect(FileManager.default.fileExists(atPath: immutableBlob.path))

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root)
      for digest in [firstDigest, secondDigest] {
        await expectManifestTestAkashicError(.notFound) {
          try await reopened.read(digest: digest, partition: partition)
        }
      }
      #expect(FileManager.default.fileExists(atPath: immutableBlob.path))

      try setUserImmutable(immutableBlob, enabled: false)
      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: max(first.count, second.count)
      )
      let cleanup = try await reopened.garbageCollect(retaining: [], limits: limits)
      #expect(cleanup.removedBlobCount == 1)
      #expect(cleanup.removedByteCount == first.count)
      #expect(manifestTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-081 bootstrap rejects undeletable foreign cleanup debt")
  func bootstrapRejectsUndeletableForeignCleanupDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      #expect(store != nil)
      let foreign = root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(".tmp-foreign-debt", isDirectory: false)
      try writePrivateFile(Data("foreign-cleanup-debt".utf8), to: foreign)
      try setUserImmutable(foreign, enabled: true)
      defer { try? setUserImmutable(foreign, enabled: false) }

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      await expectFileBlobStoreOpenError(.storageUnavailable, root: root)
      #expect(FileManager.default.fileExists(atPath: foreign.path))

      try setUserImmutable(foreign, enabled: false)
      _ = try await reopenFileBlobStore(root: root)
      #expect(!FileManager.default.fileExists(atPath: foreign.path))
    }
  }

  @Test("AKASHIC-CT-082 lost tombstone carrier cannot resurrect payload cleanup debt")
  func lostTombstoneCarrierCannotResurrectPayloadDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-lost-tombstone".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-lost-tombstone")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(data: data, digest: digest, partition: partition)
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)

      // The witness requires the current fast-create payload xattr so that the lower-sequence
      // create carrier remains physically present with the immutable payload after tombstone loss.
      #expect(try manifestXattrRecordCount(in: root, generation: 1) == 1)
      try setUserImmutable(blob, enabled: true)
      defer { try? setUserImmutable(blob, enabled: false) }

      try await store!.remove(digest: digest, partition: partition)
      await expectManifestTestAkashicError(.notFound) {
        try await store!.read(digest: digest, partition: partition)
      }
      let tombstones = manifestRecordFiles(in: root)
      #expect(tombstones.count == 1)
      #expect(FileManager.default.fileExists(atPath: blob.path))

      // Simulate loss of the higher-sequence logical carrier while physical cleanup debt keeps the
      // lower-sequence create carrier alive on the payload inode.
      try FileManager.default.removeItem(at: tombstones[0])
      #expect(manifestRecordFiles(in: root).isEmpty)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await reopenFileBlobStore(root: root)

      // A committed deletion may not roll back to the surviving lower-sequence create authority.
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
    }
  }

  @Test("AKASHIC-CT-083 replacement debt cannot roll back after current carrier loss")
  func replacementDebtCannotRollBackAfterCurrentCarrierLoss() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-replacement-rollback".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-replacement-rollback")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let original = try await store!.commit(data: data, digest: digest, partition: partition)
      let oldBlob = manifestTestBlobURL(root: root, id: original.physicalID)
      try Data(repeating: 0x31, count: data.count).write(to: oldBlob)
      try setUserImmutable(oldBlob, enabled: true)
      defer { try? setUserImmutable(oldBlob, enabled: false) }

      let replacement = try await store!.commit(data: data, digest: digest, partition: partition)
      #expect(replacement.physicalID != original.physicalID)
      #expect(FileManager.default.fileExists(atPath: oldBlob.path))

      // Losing the new payload after the replacement completed must converge to a miss. The
      // undeletable lower-sequence payload xattr may not become authoritative again.
      let currentBlob = manifestTestBlobURL(root: root, id: replacement.physicalID)
      try FileManager.default.removeItem(at: currentBlob)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await reopenFileBlobStore(root: root)
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
    }
  }

  @Test("AKASHIC-CT-084 single-key removeAll debt survives tombstone carrier loss")
  func singleKeyRemoveAllDebtSurvivesTombstoneLoss() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-remove-all-single".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-remove-all-single")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(data: data, digest: digest, partition: partition)
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      try setUserImmutable(blob, enabled: true)
      defer { try? setUserImmutable(blob, enabled: false) }

      try await store!.removeAll(partition: partition)
      let tombstones = manifestRecordFiles(in: root)
      #expect(tombstones.count == 1)
      try FileManager.default.removeItem(at: tombstones[0])

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await reopenFileBlobStore(root: root)
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
    }
  }

  @Test("AKASHIC-CT-085 single-victim GC debt survives tombstone carrier loss")
  func singleVictimGarbageCollectionDebtSurvivesTombstoneLoss() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-gc-single".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-gc-single")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(data: data, digest: digest, partition: partition)
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      try setUserImmutable(blob, enabled: true)
      defer { try? setUserImmutable(blob, enabled: false) }

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: max(1, data.count)
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        try await store!.garbageCollect(retaining: [], limits: limits)
      }
      let tombstones = manifestRecordFiles(in: root)
      #expect(tombstones.count == 1)
      try FileManager.default.removeItem(at: tombstones[0])

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await reopenFileBlobStore(root: root)
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
    }
  }

  @Test("AKASHIC-CT-086 quarantine debt cannot regain logical authority")
  func quarantineDebtCannotRegainLogicalAuthority() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-quarantine".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-quarantine")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(data: data, digest: digest, partition: partition)
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      try Data(repeating: 0x7c, count: data.count).write(to: blob)
      try setUserImmutable(blob, enabled: true)
      defer { try? setUserImmutable(blob, enabled: false) }

      await expectManifestTestAkashicError(.integrityMismatch) {
        try await store!.read(digest: digest, partition: partition)
      }
      let tombstones = manifestRecordFiles(in: root)
      #expect(tombstones.count == 1)
      try FileManager.default.removeItem(at: tombstones[0])

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await reopenFileBlobStore(root: root)
      #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
      await expectManifestTestAkashicError(.notFound) {
        try await reopened.read(digest: digest, partition: partition)
      }
    }
  }

  @Test("AKASHIC-CT-087 failed debt seal freezes writer until reopen")
  func failedDebtSealRequiresReopen() async throws {
    for (label, target) in [
      ("pre-rename", FileBlobStoreSwitchPoint.afterManifestDataWritten),
      ("post-rename", FileBlobStoreSwitchPoint.afterManifestRenamed),
    ] {
      try await withManifestTestTemporaryDirectory { parent in
        let root = parent.appendingPathComponent(label, isDirectory: true)
        let data = Data("physical-debt-seal-fault-\(label)".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try manifestTestPartition("physical-debt-seal-fault-\(label)")
        let faultState = PhysicalDebtSealFaultState(target: target, failOccurrence: 3)
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          faultInjector: { point in try faultState.inject(point) }
        )
        let publication = try await store!.commit(
          data: data,
          digest: digest,
          partition: partition
        )
        let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
        try setUserImmutable(blob, enabled: true)
        defer { try? setUserImmutable(blob, enabled: false) }

        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.remove(digest: digest, partition: partition)
        }
        #expect(faultState.occurrences == 3)
        await expectManifestTestAkashicError(.storageUnavailable) {
          try await store!.read(digest: digest, partition: partition)
        }
        #expect(await store!.physicalID(digest: digest, partition: partition) == nil)

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await reopenFileBlobStore(root: root)
        await expectManifestTestAkashicError(.notFound) {
          try await reopened.read(digest: digest, partition: partition)
        }
        #expect(await reopened.physicalID(digest: digest, partition: partition) == nil)
      }
    }
  }

  @Test("AKASHIC-CT-080 replacement keeps new authority when old carrier cleanup is blocked")
  func replacementSurvivesOldCarrierDeletionFailure() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("physical-debt-replacement".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("physical-debt-replacement")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let original = try await store!.commit(data: data, digest: digest, partition: partition)
      let oldBlob = manifestTestBlobURL(root: root, id: original.physicalID)
      try Data(repeating: 0x5a, count: data.count).write(to: oldBlob)
      try setUserImmutable(oldBlob, enabled: true)
      defer { try? setUserImmutable(oldBlob, enabled: false) }

      let replacement = try await store!.commit(data: data, digest: digest, partition: partition)
      #expect(replacement.disposition == .created)
      #expect(replacement.physicalID != original.physicalID)
      #expect(try await store!.read(digest: digest, partition: partition) == data)
      #expect(manifestTestBlobFiles(in: root).count == 2)
      #expect(FileManager.default.fileExists(atPath: oldBlob.path))

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root)
      #expect(try await reopened.read(digest: digest, partition: partition) == data)
      #expect(await reopened.physicalID(digest: digest, partition: partition) == replacement.physicalID)
      #expect(FileManager.default.fileExists(atPath: oldBlob.path))

      try setUserImmutable(oldBlob, enabled: false)
      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: max(1, data.count)
      )
      let retained: Set<LiveBlobReference> = [
        LiveBlobReference(partition: partition, digest: digest)
      ]
      let cleanup = try await reopened.garbageCollect(retaining: retained, limits: limits)
      #expect(cleanup.removedBlobCount == 1)
      #expect(cleanup.removedByteCount == data.count)
      #expect(manifestTestBlobFiles(in: root).count == 1)
      #expect(try await reopened.read(digest: digest, partition: partition) == data)
    }
  }
}

private final class PhysicalDebtSealFaultState: @unchecked Sendable {
  private let lock = NSLock()
  private let target: FileBlobStoreSwitchPoint
  private let failOccurrence: Int
  private var count = 0

  init(target: FileBlobStoreSwitchPoint, failOccurrence: Int) {
    self.target = target
    self.failOccurrence = failOccurrence
  }

  var occurrences: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func inject(_ point: FileBlobStoreSwitchPoint) throws {
    guard point.rawValue == target.rawValue else { return }
    lock.lock()
    count += 1
    let shouldFail = count == failOccurrence
    lock.unlock()
    if shouldFail { throw POSIXError(.EIO) }
  }
}

private func setUserImmutable(_ url: URL, enabled: Bool) throws {
  let flags: UInt32 = enabled ? UInt32(UF_IMMUTABLE) : 0
  let result = url.path.withCString { Darwin.chflags($0, flags) }
  guard result == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
