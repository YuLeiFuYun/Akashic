import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk FileBlobStore")
struct FileBlobStoreTests {
  @Test("AKASHIC-CT-004 partition logical isolation")
  func partitionLogicalIsolation() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("partition-isolation".utf8)
      let digest = BlobDigest.sha256(of: data)
      let first = try fileBlobStoreTestPartition("first")
      let second = try fileBlobStoreTestPartition("second")

      _ = try await store.commit(data: data, digest: digest, partition: first)
      #expect(try await store.read(digest: digest, partition: first) == data)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: digest, partition: second)
      }

      try await store.removeAll(partition: second)
      #expect(try await store.read(digest: digest, partition: first) == data)
    }
  }

  @Test("AKASHIC-CT-005 stage remains invisible")
  func stageRemainsInvisible() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("invisible-stage".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("stage")

      let stage = try await store.stage(
        data: data,
        digest: digest,
        partition: partition
      )
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: digest, partition: partition)
      }
      #expect(await store.physicalID(digest: digest, partition: partition) == nil)

      _ = try await store.publish(stage)
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-006 publish has one terminal transition")
  func publishSingleTerminalTransition() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("single-terminal".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("publish")
      let stage = try await store.stage(
        data: data,
        digest: digest,
        partition: partition
      )

      let publication = try await store.publish(stage)
      #expect(publication.disposition == .created)
      await expectFileBlobStoreTestAkashicError(.transactionConflict) {
        _ = try await store.publish(stage)
      }
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-007 discard is idempotent and terminal")
  func discardIdempotentAndTerminal() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("discard-terminal".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("discard")
      let stage = try await store.stage(
        data: data,
        digest: digest,
        partition: partition
      )

      await store.discard(stage)
      await store.discard(stage)
      await expectFileBlobStoreTestAkashicError(.transactionConflict) {
        _ = try await store.publish(stage)
      }
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: digest, partition: partition)
      }
    }
  }

  @Test("AKASHIC-CT-008 same-partition duplicate commit reuses physical blob")
  func samePartitionDuplicateCommit() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("same-partition-reuse".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("reuse")

      let first = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let second = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )

      #expect(first.disposition == .created)
      #expect(second.disposition == .reused)
      #expect(first.physicalID == second.physicalID)
      #expect(fileBlobStoreTestBlobFiles(in: root).count == 1)
    }
  }

  @Test("AKASHIC-CT-009 cross-partition physical deduplication is forbidden")
  func crossPartitionNoPhysicalDeduplication() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("cross-partition".utf8)
      let digest = BlobDigest.sha256(of: data)
      let firstPartition = try fileBlobStoreTestPartition("partition-a")
      let secondPartition = try fileBlobStoreTestPartition("partition-b")

      let first = try await store.commit(
        data: data,
        digest: digest,
        partition: firstPartition
      )
      let second = try await store.commit(
        data: data,
        digest: digest,
        partition: secondPartition
      )

      #expect(first.physicalID != second.physicalID)
      #expect(first.disposition == .created)
      #expect(second.disposition == .created)
      #expect(fileBlobStoreTestBlobFiles(in: root).count == 2)
    }
  }

  @Test("AKASHIC-CT-010 store recomputes digest")
  func storeRecomputesDigest() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let declared = BlobDigest.sha256(of: Data("declared".utf8))
      let actual = Data("actual".utf8)
      let partition = try fileBlobStoreTestPartition("integrity")

      await expectFileBlobStoreTestAkashicError(.integrityMismatch) {
        _ = try await store.commit(
          data: actual,
          digest: declared,
          partition: partition
        )
      }
      #expect(fileBlobStoreTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-011 logical publication switch recovery")
  func logicalPublicationSwitchRecovery() async throws {
    let points: [FileBlobStoreSwitchPoint] = [
      .afterBlobFilePublished,
      .beforeManifestPublished,
      .afterManifestPublished,
    ]
    for point in points {
      try await withFileBlobStoreTestTemporaryDirectory { root in
        let data = Data("switch-\(fileBlobStoreSwitchLabel(point))".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try fileBlobStoreTestPartition(fileBlobStoreSwitchLabel(point))

        try await executeFileBlobStoreInjectedCrash(
          root: root,
          point: point,
          data: data,
          digest: digest,
          partition: partition
        )

        let reopened = try await FileBlobStore.open(root: root)
        switch point {
        case .afterManifestPublished:
          #expect(
            try await reopened.read(
              digest: digest,
              partition: partition
            ) == data
          )
          #expect(fileBlobStoreTestBlobFiles(in: root).count == 1)
        case .afterBlobFilePublished, .beforeManifestPublished:
          await expectFileBlobStoreTestAkashicError(.notFound) {
            _ = try await reopened.read(
              digest: digest,
              partition: partition
            )
          }
          #expect(fileBlobStoreTestBlobFiles(in: root).isEmpty)
        default:
          Issue.record("Unexpected high-level switch point")
        }
      }
    }
  }

  @Test("AKASHIC-CT-012 future manifest schema fails closed")
  func futureManifestSchemaFailsClosed() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      let manifest = root.appendingPathComponent("manifest.json")
      try Data(#"{"schemaVersion":999,"entries":{}}"#.utf8).write(to: manifest)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: manifest.path
      )

      await expectFileBlobStoreTestAkashicError(.unsupportedSchema) {
        _ = try await FileBlobStore.open(root: root)
      }
      let unchanged = try Data(contentsOf: manifest)
      #expect(String(decoding: unchanged, as: UTF8.self).contains("999"))
    }
  }

  @Test("AKASHIC-CT-015 external truncation is quarantined")
  func externalTruncationIsQuarantined() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("truncate-me".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("truncate")
      let publication = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let blob = fileBlobStoreTestBlobURL(root: root, id: publication.physicalID)
      try Data(data.prefix(2)).write(to: blob)

      await expectFileBlobStoreTestAkashicError(.integrityMismatch) {
        _ = try await store.read(digest: digest, partition: partition)
      }
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: digest, partition: partition)
      }
      #expect(!FileManager.default.fileExists(atPath: blob.path))
    }
  }

  @Test("AKASHIC-CT-015 external deletion and same-length corruption are quarantined")
  func externalDeletionAndCorruption() async throws {
    for mode in ["delete", "corrupt"] {
      try await withFileBlobStoreTestTemporaryDirectory { root in
        let store = try await FileBlobStore.open(root: root)
        let data = Data("mutation-\(mode)".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try fileBlobStoreTestPartition(mode)
        let publication = try await store.commit(
          data: data,
          digest: digest,
          partition: partition
        )
        let blob = fileBlobStoreTestBlobURL(root: root, id: publication.physicalID)
        if mode == "delete" {
          try FileManager.default.removeItem(at: blob)
        } else {
          try Data(repeating: 0x5a, count: data.count).write(to: blob)
        }

        await expectFileBlobStoreTestAkashicError(.integrityMismatch) {
          _ = try await store.read(digest: digest, partition: partition)
        }
        await expectFileBlobStoreTestAkashicError(.notFound) {
          _ = try await store.read(digest: digest, partition: partition)
        }
      }
    }
  }

  @Test("AKASHIC-CT-017 physical locator is UUID constrained")
  func physicalLocatorUUIDConstrained() throws {
    let uuid = UUID()
    let identifier = PhysicalBlobID(rawValue: uuid)
    let encoded = try JSONEncoder().encode(identifier)
    let decoded = try JSONDecoder().decode(PhysicalBlobID.self, from: encoded)

    #expect(decoded == identifier)
    #expect(decoded.rawValue == uuid)
    #expect(!decoded.rawValue.uuidString.contains("/"))
    #expect(!decoded.rawValue.uuidString.contains(".."))
  }

  @Test("AKASHIC-CT-021 in-process concurrent readers remain consistent")
  func concurrentReaders() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data(repeating: 0x42, count: 4_096)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("concurrent-readers")
      _ = try await store.commit(data: data, digest: digest, partition: partition)

      let results = try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<32 {
          group.addTask {
            for _ in 0..<25 {
              guard
                try await store.read(
                  digest: digest,
                  partition: partition
                ) == data
              else { return false }
            }
            return true
          }
        }
        var values: [Bool] = []
        for try await value in group { values.append(value) }
        return values
      }
      #expect(results.count == 32)
      #expect(results.allSatisfy { $0 })
    }
  }

  @Test("AKASHIC-CT-016 links, unsafe permissions and wrong file types are rejected")
  func filesystemDefenses() async throws {
    try await assertMutationRejected(kind: "symlink") { blob, root in
      let target = root.appendingPathComponent("outside-target")
      try Data("outside".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: target)
    }
    try await assertMutationRejected(kind: "hardlink") { blob, root in
      let target = root.appendingPathComponent("outside-hardlink-target")
      try Data("outside".utf8).write(to: target)
      try FileManager.default.linkItem(at: target, to: blob)
    }
    try await assertMutationRejected(kind: "permissions") { blob, _ in
      try Data("replacement".utf8).write(to: blob)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))],
        ofItemAtPath: blob.path
      )
    }
    try await assertMutationRejected(kind: "directory") { blob, _ in
      try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: false)
    }
  }

  @Test("AKASHIC-CT-018 maintenance limits fail before mutation")
  func maintenanceLimitsFailBeforeMutation() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("maintenance".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("maintenance")
      _ = try await store.commit(data: data, digest: digest, partition: partition)
      let references: Set<LiveBlobReference> = [
        LiveBlobReference(partition: partition, digest: digest)
      ]
      let limits = try BlobMaintenanceLimits(
        maximumReferenceCount: 1,
        maximumReferencedBytes: data.count - 1
      )

      await expectFileBlobStoreTestAkashicError(.limitExceeded) {
        _ = try await store.garbageCollect(
          retaining: references,
          limits: limits
        )
      }
      #expect(try await store.read(digest: digest, partition: partition) == data)
    }
  }

  @Test("AKASHIC-CT-018 directory entry limit fails before unbounded collection")
  func directoryEntryLimit() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
      for name in ["extra-a", "extra-b"] {
        let url = root.appendingPathComponent(name)
        try Data([0x01]).write(to: url)
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: Int16(0o600))],
          ofItemAtPath: url.path
        )
      }
      let limits = FileBlobStoreLimits(maximumDirectoryEntryCount: 3)
      await expectFileBlobStoreTestAkashicError(.limitExceeded) {
        _ = try await FileBlobStore.open(root: root, limits: limits)
      }
    }
  }

  @Test("AKASHIC-CT-020 one active writer per store root")
  func oneActiveWriter() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      var first: FileBlobStore? = try await FileBlobStore.open(root: root)
      #expect(first != nil)
      await expectFileBlobStoreTestAkashicError(.transactionConflict) {
        _ = try await FileBlobStore.open(root: root)
      }
      #expect(runFileBlobStoreExternalLockProbe(root: root) != 0)

      first = nil
      for _ in 0..<20 { await Task.yield() }
      #expect(runFileBlobStoreExternalLockProbe(root: root) == 0)
      let reopened = try await FileBlobStore.open(root: root)
      let emptyDigest = BlobDigest.sha256(of: Data())
      let emptyPartition = try fileBlobStoreTestPartition("reopened")
      #expect(
        await reopened.physicalID(
          digest: emptyDigest,
          partition: emptyPartition
        ) == nil
      )
    }
  }

  @Test("AKASHIC-CT-110 schema3 cached live bytes keeps the default fast path trim bounded")
  func schema3CachedLiveBytesKeepsTrimBounded() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(
        root: root,
        limits: FileBlobStoreLimits(
          softTotalBytes: 64,
          maximumBlobBytes: 64
        )
      )
      let partition = try fileBlobStoreTestPartition("schema3-live-byte-cache")
      var fixtures: [(BlobDigest, Data)] = []
      for index in 0..<3 {
        var data = Data(repeating: UInt8(0x50 + index), count: 40)
        data[0] = UInt8(index)
        let digest = BlobDigest.sha256(of: data)
        fixtures.append((digest, data))
        _ = try await store.commit(data: data, digest: digest, partition: partition)
        let cached = try #require(await store.manifestLiveByteCount)
        let full = await store.manifest.entries.values.reduce(0) { $0 + $1.byteCount }
        #expect(cached == full)
        #expect(cached <= 64)
      }
      #expect(await store.manifest.entries.count == 1)
      #expect(try await store.read(digest: fixtures[2].0, partition: partition) == fixtures[2].1)
    }
  }

  @Test("AKASHIC-CT-126 missing root manifest on an established store fails closed")
  func missingRootManifestOnEstablishedStoreFailsClosed() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let data = Data("root-manifest-loss".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition("root-manifest-loss")
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let blob = fileBlobStoreTestBlobURL(root: root, id: publication.physicalID)
      #expect(FileManager.default.fileExists(atPath: blob.path))
      store = nil
      for _ in 0..<20 { await Task.yield() }

      try FileManager.default.removeItem(
        at: root.appendingPathComponent("manifest.json", isDirectory: false)
      )
      await expectFileBlobStoreTestAkashicError(.invalidManifest) {
        _ = try await FileBlobStore.open(root: root)
      }
      #expect(FileManager.default.fileExists(atPath: blob.path))
    }
  }

  private func assertMutationRejected(
    kind: String,
    mutation: (URL, URL) throws -> Void
  ) async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let store = try await FileBlobStore.open(root: root)
      let data = Data("filesystem-\(kind)".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try fileBlobStoreTestPartition(kind)
      let publication = try await store.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let blob = fileBlobStoreTestBlobURL(root: root, id: publication.physicalID)
      try FileManager.default.removeItem(at: blob)
      try mutation(blob, root)

      await expectFileBlobStoreTestAkashicError(.integrityMismatch) {
        _ = try await store.read(digest: digest, partition: partition)
      }
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store.read(digest: digest, partition: partition)
      }
    }
  }
}
