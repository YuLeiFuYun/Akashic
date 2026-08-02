import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk manifest v2")
struct FileBlobStoreManifestV2Tests {
  @Test("AKASHIC-CT-031 legacy flat manifest migrates to generation snapshot")
  func legacyManifestMigration() async throws {
    try await withTemporaryDirectory { root in
      let blobs = root.appendingPathComponent("blobs", isDirectory: true)
      try createPrivateDirectory(root)
      try createPrivateDirectory(blobs)

      let data = Data("legacy-manifest-migration".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try partition("legacy-migration")
      let physicalID = PhysicalBlobID()
      let blob = blobURL(root: root, id: physicalID)
      try writePrivateFile(data, to: blob)
      let key = FileBlobStoreIdentity.manifestKey(
        digest: digest,
        partition: partition
      )
      let legacy = FileBlobStore.LegacyManifest(
        schemaVersion: FileBlobStore.legacyManifestSchemaVersion,
        entries: [
          key: FileBlobStore.Entry(
            physicalID: physicalID,
            partition: partition,
            digest: digest,
            byteCount: data.count,
            lastAccess: Date()
          )
        ]
      )
      try writePrivateFile(
        try JSONEncoder().encode(legacy),
        to: root.appendingPathComponent("manifest.json")
      )

      let store = try await FileBlobStore.open(root: root)
      #expect(try await store.read(digest: digest, partition: partition) == data)
      let migrated = try JSONDecoder().decode(
        FileBlobStore.Manifest.self,
        from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
      )
      #expect(migrated.schemaVersion == FileBlobStore.currentSchemaVersion)
      #expect(migrated.generation == 1)
      #expect(migrated.entries[key]?.physicalID == physicalID)
    }
  }

  @Test("AKASHIC-CT-032 incremental manifest records replay after reopen")
  func incrementalManifestReplay() async throws {
    try await withTemporaryDirectory { root in
      let partition = try partition("incremental-replay")
      let firstData = Data("incremental-first".utf8)
      let secondData = Data("incremental-second".utf8)
      let firstDigest = BlobDigest.sha256(of: firstData)
      let secondDigest = BlobDigest.sha256(of: secondData)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await store!.commit(
        data: firstData,
        digest: firstDigest,
        partition: partition
      )
      _ = try await store!.commit(
        data: secondData,
        digest: secondDigest,
        partition: partition
      )
      #expect(manifestRecordFiles(in: root).count == 2)

      store = nil
      let reopened = try await reopenFileBlobStore(root: root)
      #expect(
        try await reopened.read(digest: firstDigest, partition: partition) == firstData
      )
      #expect(
        try await reopened.read(digest: secondDigest, partition: partition) == secondData
      )
    }
  }

  @Test("AKASHIC-CT-033 incremental tombstone remains a miss after reopen")
  func incrementalTombstoneReplay() async throws {
    try await withTemporaryDirectory { root in
      let partition = try partition("incremental-tombstone")
      let data = Data("incremental-tombstone".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await store!.commit(data: data, digest: digest, partition: partition)
      try await store!.remove(digest: digest, partition: partition)
      #expect(manifestRecordFiles(in: root).count == 1)

      store = nil
      let reopened = try await reopenFileBlobStore(root: root)
      await expectAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: partition)
      }
      #expect(blobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-034 corrupt incremental record fails closed")
  func corruptIncrementalRecordFailsClosed() async throws {
    try await withTemporaryDirectory { root in
      let partition = try partition("corrupt-incremental-record")
      let data = Data("corrupt-incremental-record".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await store!.commit(data: data, digest: digest, partition: partition)
      let record = try #require(manifestRecordFiles(in: root).first)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try writePrivateFile(Data("not-json".utf8), to: record)

      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-035 multi-key maintenance checkpoints and removes records")
  func multiKeyMaintenanceCheckpoint() async throws {
    try await withTemporaryDirectory { root in
      let partition = try partition("multi-key-checkpoint")
      let values = [Data("checkpoint-a".utf8), Data("checkpoint-b".utf8)]
      let digests = values.map(BlobDigest.sha256(of:))
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      for (data, digest) in zip(values, digests) {
        _ = try await store!.commit(data: data, digest: digest, partition: partition)
      }
      #expect(manifestRecordFiles(in: root).count == 2)
      try await store!.removeAll(partition: partition)
      #expect(manifestRecordFiles(in: root).isEmpty)
      let snapshot = try JSONDecoder().decode(
        FileBlobStore.Manifest.self,
        from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
      )
      #expect(snapshot.generation == 2)
      #expect(snapshot.entries.isEmpty)

      store = nil
      let reopened = try await reopenFileBlobStore(root: root)
      for digest in digests {
        await expectAkashicError(.notFound) {
          _ = try await reopened.read(digest: digest, partition: partition)
        }
      }
    }
  }

  @Test("AKASHIC-CT-036 stale generation record cannot resurrect an entry")
  func staleGenerationRecordCannotResurrect() async throws {
    try await withTemporaryDirectory { root in
      let partition = try partition("stale-record")
      let values = [Data("stale-seed-a".utf8), Data("stale-seed-b".utf8)]
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      for data in values {
        _ = try await store!.commit(
          data: data,
          digest: BlobDigest.sha256(of: data),
          partition: partition
        )
      }
      try await store!.removeAll(partition: partition)
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      let staleData = Data("stale-generation-payload".utf8)
      let staleDigest = BlobDigest.sha256(of: staleData)
      let stalePhysicalID = PhysicalBlobID()
      let staleBlob = blobURL(root: root, id: stalePhysicalID)
      try writePrivateFile(staleData, to: staleBlob)
      let key = FileBlobStoreIdentity.manifestKey(
        digest: staleDigest,
        partition: partition
      )
      let staleRecord = FileBlobStore.ManifestRecord(
        generation: 1,
        sequence: 1,
        key: key,
        entry: FileBlobStore.Entry(
          physicalID: stalePhysicalID,
          partition: partition,
          digest: staleDigest,
          byteCount: staleData.count,
          lastAccess: Date()
        )
      )
      let recordURL = manifestRecordURL(root: root, key: key)
      try writePrivateFile(try JSONEncoder().encode(staleRecord), to: recordURL)

      let reopened = try await FileBlobStore.open(root: root)
      await expectAkashicError(.notFound) {
        _ = try await reopened.read(digest: staleDigest, partition: partition)
      }
      #expect(!FileManager.default.fileExists(atPath: staleBlob.path))
      #expect(!FileManager.default.fileExists(atPath: recordURL.path))
    }
  }

}

private func createPrivateDirectory(_ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: Int16(0o700))],
    ofItemAtPath: url.path
  )
}

private func writePrivateFile(_ data: Data, to url: URL) throws {
  try data.write(to: url)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: Int16(0o600))],
    ofItemAtPath: url.path
  )
}

private func manifestRecordURL(root: URL, key: String) -> URL {
  root.appendingPathComponent("blobs", isDirectory: true)
    .appendingPathComponent(".manifest-entry-\(key).json", isDirectory: false)
}

private func manifestRecordFiles(in root: URL) -> [URL] {
  let blobs = root.appendingPathComponent("blobs", isDirectory: true)
  return
    ((try? FileManager.default.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: []
    )) ?? []).filter {
      $0.lastPathComponent.hasPrefix(".manifest-entry-")
        && $0.pathExtension == "json"
    }
}

private func waitForWriterLeaseRelease(root: URL) async throws {
  for _ in 0..<200 {
    if runExternalLockProbe(root: root) == 0 { return }
    await Task.yield()
  }
  throw AkashicError.transactionConflict
}

private func reopenFileBlobStore(root: URL) async throws -> FileBlobStore {
  for _ in 0..<200 {
    do {
      return try await FileBlobStore.open(root: root)
    } catch AkashicError.transactionConflict {
      await Task.yield()
    }
  }
  throw AkashicError.transactionConflict
}

private func expectFileBlobStoreOpenError(
  _ expected: AkashicError,
  root: URL
) async {
  for _ in 0..<200 {
    do {
      _ = try await FileBlobStore.open(root: root)
      Issue.record("Expected AkashicError.\(expected)")
      return
    } catch AkashicError.transactionConflict {
      await Task.yield()
    } catch let error as AkashicError {
      #expect(error == expected)
      return
    } catch {
      Issue.record("Expected AkashicError.\(expected), received \(error)")
      return
    }
  }
  Issue.record("Writer lease did not release before open-error assertion")
}

private func partition(_ label: String) throws -> CachePartitionID {
  try CachePartitionID.derive(
    domain: "akashic-disk-tests",
    material: Data(label.utf8)
  )
}

private func blobURL(root: URL, id: PhysicalBlobID) -> URL {
  root.appendingPathComponent("blobs", isDirectory: true)
    .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
}

private func blobFiles(in root: URL) -> [URL] {
  let blobs = root.appendingPathComponent("blobs", isDirectory: true)
  return
    (try? FileManager.default.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
}

private func withTemporaryDirectory<T>(
  _ operation: (URL) async throws -> T
) async throws -> T {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "akashic-tests-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  return try await operation(root)
}

private func expectAkashicError<T>(
  _ expected: AkashicError,
  operation: () async throws -> T
) async {
  do {
    _ = try await operation()
    Issue.record("Expected AkashicError.\(expected)")
  } catch let error as AkashicError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected AkashicError.\(expected), received \(error)")
  }
}

private func runExternalLockProbe(root: URL) -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
  process.arguments = [
    "-t", "0",
    root.appendingPathComponent(".akashic-writer.lock").path,
    "/usr/bin/true",
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  } catch {
    return -1
  }
}
