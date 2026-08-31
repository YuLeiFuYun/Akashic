import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk directory-head migration maintenance")
struct FileBlobStoreDirectoryHeadMigrationMaintenanceTests {
  @Test("AKASHIC-CT-113 schema4 migration preserves and repays legacy sidecar debt")
  func schema4MigrationRepaysLegacySidecarDebtOnNextMutation() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let legacyData = Data("schema4-legacy-sidecar-debt".utf8)
      let legacyDigest = BlobDigest.sha256(of: legacyData)
      let legacyPartition = try manifestTestPartition("schema4-legacy-sidecar-debt")
      _ = try await publishThroughSidecar(
        store: store,
        data: legacyData,
        digest: legacyDigest,
        partition: legacyPartition
      )
      let legacyGeneration = await store.manifest.generation
      let legacyKey = FileBlobStoreIdentity.manifestKey(
        digest: legacyDigest,
        partition: legacyPartition
      )
      let sidecar = scopedManifestRecordURL(
        root: root,
        generation: legacyGeneration,
        key: legacyKey
      )
      #expect(FileManager.default.fileExists(atPath: sidecar.path))

      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      let migratedDebt = await store.staleManifestRecordCleanupQueue
      #expect(migratedDebt.contains(sidecar))

      let nextData = Data("schema4-legacy-sidecar-debt-next".utf8)
      let nextDigest = BlobDigest.sha256(of: nextData)
      let nextPartition = try manifestTestPartition("schema4-legacy-sidecar-debt-next")
      _ = try await store.commit(
        data: nextData,
        digest: nextDigest,
        partition: nextPartition
      )
      #expect(!FileManager.default.fileExists(atPath: sidecar.path))
      let remainingDebt = await store.staleManifestRecordCleanupQueue
      #expect(!remainingDebt.contains(sidecar))
    }
  }

  @Test("AKASHIC-CT-114 schema4 reopen rebuilds legacy sidecar debt during reconciliation")
  func schema4ReopenRebuildsAndRepaysLegacySidecarDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let legacyData = Data("schema4-reopen-sidecar-debt".utf8)
      let legacyDigest = BlobDigest.sha256(of: legacyData)
      let legacyPartition = try manifestTestPartition("schema4-reopen-sidecar-debt")
      _ = try await publishThroughSidecar(
        store: store!,
        data: legacyData,
        digest: legacyDigest,
        partition: legacyPartition
      )
      let legacyGeneration = await store!.manifest.generation
      let legacyKey = FileBlobStoreIdentity.manifestKey(
        digest: legacyDigest,
        partition: legacyPartition
      )
      let sidecar = scopedManifestRecordURL(
        root: root,
        generation: legacyGeneration,
        key: legacyKey
      )
      #expect(FileManager.default.fileExists(atPath: sidecar.path))
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let reopenedDebt = await store!.staleManifestRecordCleanupQueue
      #expect(reopenedDebt.contains(sidecar))

      let nextData = Data("schema4-reopen-sidecar-debt-next".utf8)
      let nextDigest = BlobDigest.sha256(of: nextData)
      let nextPartition = try manifestTestPartition("schema4-reopen-sidecar-debt-next")
      _ = try await store!.commit(
        data: nextData,
        digest: nextDigest,
        partition: nextPartition
      )
      #expect(!FileManager.default.fileExists(atPath: sidecar.path))
      let remainingDebt = await store!.staleManifestRecordCleanupQueue
      #expect(!remainingDebt.contains(sidecar))
    }
  }

  @Test("AKASHIC-CT-115 schema4 cleanup never adopts symlink sidecar lookalikes")
  func schema4ReopenDoesNotDeleteSymlinkSidecarLookalike() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation
      let fakeData = Data("schema4-sidecar-lookalike".utf8)
      let fakeDigest = BlobDigest.sha256(of: fakeData)
      let fakePartition = try manifestTestPartition("schema4-sidecar-lookalike")
      let fakeKey = FileBlobStoreIdentity.manifestKey(
        digest: fakeDigest,
        partition: fakePartition
      )
      let fakeName = try #require(
        FileBlobStore.ManifestRecord.fileName(generation: generation, key: fakeKey)
      )
      let fakeSidecar = root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(fakeName, isDirectory: false)
      let sentinel = root.appendingPathComponent("sidecar-lookalike-sentinel", isDirectory: false)
      try writePrivateFile(Data("sentinel".utf8), to: sentinel)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try FileManager.default.createSymbolicLink(
        at: fakeSidecar,
        withDestinationURL: sentinel
      )

      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let rebuiltDebt = await store!.staleManifestRecordCleanupQueue
      #expect(!rebuiltDebt.contains(fakeSidecar))
      #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fakeSidecar.path) == sentinel.path)

      let nextData = Data("schema4-sidecar-lookalike-next".utf8)
      _ = try await store!.commit(
        data: nextData,
        digest: BlobDigest.sha256(of: nextData),
        partition: try manifestTestPartition("schema4-sidecar-lookalike-next")
      )
      #expect(FileManager.default.fileExists(atPath: sentinel.path))
      #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fakeSidecar.path) == sentinel.path)
    }
  }

  @Test("AKASHIC-CT-116 explicit GC strictly repays schema4 legacy sidecar debt")
  func schema4ExplicitGarbageCollectRepaysLegacySidecarWithoutMutation() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-explicit-gc-sidecar".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-explicit-gc-sidecar")
      _ = try await publishThroughSidecar(
        store: store,
        data: data,
        digest: digest,
        partition: partition
      )
      let legacyGeneration = await store.manifest.generation
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      let sidecar = scopedManifestRecordURL(
        root: root,
        generation: legacyGeneration,
        key: key
      )
      #expect(FileManager.default.fileExists(atPath: sidecar.path))
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: data.count
      )
      let result = try await store.garbageCollect(
        retaining: [LiveBlobReference(partition: partition, digest: digest)],
        limits: limits
      )
      #expect(result.removedBlobCount == 0)
      #expect(result.removedByteCount == 0)
      #expect(!FileManager.default.fileExists(atPath: sidecar.path))
      let remainingDebt = await store.staleManifestRecordCleanupQueue
      #expect(remainingDebt.isEmpty)
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-117 strict schema4 GC rejects symlink sidecar lookalikes")
  func schema4ExplicitGarbageCollectRejectsSymlinkSidecarLookalike() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation
      let fakeData = Data("schema4-gc-sidecar-lookalike".utf8)
      let fakeDigest = BlobDigest.sha256(of: fakeData)
      let fakePartition = try manifestTestPartition("schema4-gc-sidecar-lookalike")
      let fakeKey = FileBlobStoreIdentity.manifestKey(
        digest: fakeDigest,
        partition: fakePartition
      )
      let fakeName = try #require(
        FileBlobStore.ManifestRecord.fileName(generation: generation, key: fakeKey)
      )
      let fakeSidecar = root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(fakeName, isDirectory: false)
      let sentinel = root.appendingPathComponent("gc-sidecar-lookalike-sentinel", isDirectory: false)
      try writePrivateFile(Data("sentinel".utf8), to: sentinel)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try FileManager.default.createSymbolicLink(
        at: fakeSidecar,
        withDestinationURL: sentinel
      )
      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: 1
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await store!.garbageCollect(retaining: [], limits: limits)
      }
      #expect(FileManager.default.fileExists(atPath: sentinel.path))
      #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fakeSidecar.path) == sentinel.path)
    }
  }

  @Test("AKASHIC-CT-118 schema4 cleanup rejects regular-file sidecar body lookalikes")
  func schema4CleanupRejectsRegularFileSidecarBodyLookalike() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation
      let fakeData = Data("schema4-regular-sidecar-lookalike".utf8)
      let fakeDigest = BlobDigest.sha256(of: fakeData)
      let fakePartition = try manifestTestPartition("schema4-regular-sidecar-lookalike")
      let fakeKey = FileBlobStoreIdentity.manifestKey(
        digest: fakeDigest,
        partition: fakePartition
      )
      let fakeName = try #require(
        FileBlobStore.ManifestRecord.fileName(generation: generation, key: fakeKey)
      )
      let fakeSidecar = root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(fakeName, isDirectory: false)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try writePrivateFile(Data("not-a-manifest-record".utf8), to: fakeSidecar)
      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let rebuiltDebt = await store!.staleManifestRecordCleanupQueue
      #expect(!rebuiltDebt.contains(fakeSidecar))
      #expect(FileManager.default.fileExists(atPath: fakeSidecar.path))

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: 1
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await store!.garbageCollect(retaining: [], limits: limits)
      }
      #expect(FileManager.default.fileExists(atPath: fakeSidecar.path))
      #expect(try Data(contentsOf: fakeSidecar) == Data("not-a-manifest-record".utf8))
    }
  }

  @Test("AKASHIC-CT-119 invalid sidecar lookalikes are never permission-repaired")
  func schema4InvalidSidecarLookalikeKeepsPermissionDrift() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation
      let fakeData = Data("schema4-mode-lookalike".utf8)
      let fakeDigest = BlobDigest.sha256(of: fakeData)
      let fakePartition = try manifestTestPartition("schema4-mode-lookalike")
      let fakeKey = FileBlobStoreIdentity.manifestKey(
        digest: fakeDigest,
        partition: fakePartition
      )
      let fakeName = try #require(
        FileBlobStore.ManifestRecord.fileName(generation: generation, key: fakeKey)
      )
      let fakeSidecar = root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(fakeName, isDirectory: false)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try writePrivateFile(Data("not-a-manifest-record".utf8), to: fakeSidecar)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))],
        ofItemAtPath: fakeSidecar.path
      )
      #expect(try posixPermissions(of: fakeSidecar) == 0o644)

      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try posixPermissions(of: fakeSidecar) == 0o644)
      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: 1
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await store!.garbageCollect(retaining: [], limits: limits)
      }
      #expect(try posixPermissions(of: fakeSidecar) == 0o644)
      #expect(FileManager.default.fileExists(atPath: fakeSidecar.path))
    }
  }

  @Test("AKASHIC-CT-120 valid legacy sidecar cleanup tolerates permission drift")
  func schema4LegacySidecarCleanupToleratesPermissionDrift() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-sidecar-mode-drift".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-sidecar-mode-drift")
      _ = try await publishThroughSidecar(
        store: store,
        data: data,
        digest: digest,
        partition: partition
      )
      let generation = await store.manifest.generation
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      let sidecar = scopedManifestRecordURL(root: root, generation: generation, key: key)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))],
        ofItemAtPath: sidecar.path
      )
      #expect(try posixPermissions(of: sidecar) == 0o644)

      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      let debt = await store.staleManifestRecordCleanupQueue
      #expect(debt.contains(sidecar))
      let next = Data("schema4-sidecar-mode-drift-next".utf8)
      _ = try await store.commit(
        data: next,
        digest: BlobDigest.sha256(of: next),
        partition: try manifestTestPartition("schema4-sidecar-mode-drift-next")
      )
      #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }
  }

  @Test("AKASHIC-CT-121 strict schema4 GC retires validated legacy payload xattrs")
  func schema4ExplicitGarbageCollectRepaysLegacyPayloadXattrDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-explicit-gc-payload-xattr".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-explicit-gc-payload-xattr")
      let publication = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let legacyGeneration = await store.manifest.generation
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      let identity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(
          generation: legacyGeneration,
          key: key
        )
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      #expect(try extendedAttributeExists(identity.name, at: blob))
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: data.count
      )
      let result = try await store.garbageCollect(
        retaining: [LiveBlobReference(partition: partition, digest: digest)],
        limits: limits
      )
      #expect(result.removedBlobCount == 0)
      #expect(result.removedByteCount == 0)
      #expect(!(try extendedAttributeExists(identity.name, at: blob)))
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-122 strict schema4 GC rejects corrupt legacy payload xattrs")
  func schema4ExplicitGarbageCollectRejectsCorruptLegacyPayloadXattr() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-corrupt-legacy-payload-xattr".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-corrupt-legacy-payload-xattr")
      let publication = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let legacyGeneration = await store.manifest.generation
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      let identity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(
          generation: legacyGeneration,
          key: key
        )
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      try replaceExtendedAttribute(
        identity.name,
        value: Data("corrupt-legacy-manifest-xattr".utf8),
        at: blob
      )

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: data.count
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await store.garbageCollect(
          retaining: [LiveBlobReference(partition: partition, digest: digest)],
          limits: limits
        )
      }
      #expect(try extendedAttributeExists(identity.name, at: blob))
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-123 schema4 legacy payload xattr debt is retryable after immutable failure")
  func schema4LegacyPayloadXattrCleanupRetriesAfterImmutableFailure() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-immutable-legacy-payload-xattr".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-immutable-legacy-payload-xattr")
      let publication = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let legacyGeneration = await store.manifest.generation
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      let identity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(
          generation: legacyGeneration,
          key: key
        )
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      try setDirectoryHeadTestUserImmutable(blob, enabled: true)
      defer { try? setDirectoryHeadTestUserImmutable(blob, enabled: false) }

      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: data.count
      )
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await store.garbageCollect(
          retaining: [LiveBlobReference(partition: partition, digest: digest)],
          limits: limits
        )
      }
      #expect(try extendedAttributeExists(identity.name, at: blob))

      try setDirectoryHeadTestUserImmutable(blob, enabled: false)
      _ = try await store.garbageCollect(
        retaining: [LiveBlobReference(partition: partition, digest: digest)],
        limits: limits
      )
      #expect(!(try extendedAttributeExists(identity.name, at: blob)))
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }
}
