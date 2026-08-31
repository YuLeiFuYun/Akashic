import AkashicCore
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk manifest compatibility")
struct FileBlobStoreManifestLegacyTests {
  @Test("AKASHIC-CT-045 legacy v1 incremental record replays after v2 writer upgrade")
  func legacyV1IncrementalRecordReplays() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("legacy-record-replay")
      let data = Data("legacy-record-replay-payload".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await publishThroughSidecar(
        store: store!,
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let blob = try #require(manifestTestBlobFiles(in: root).first)
      let uuid = try #require(UUID(uuidString: blob.lastPathComponent))
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let currentRecordURL = try #require(manifestRecordFiles(in: root).first)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try FileManager.default.removeItem(at: currentRecordURL)
      let recordURL = legacyManifestRecordURL(root: root, key: key)

      let legacy = LegacyManifestRecordFixture(
        schemaVersion: 1,
        generation: 1,
        sequence: 1,
        key: key,
        entry: FileBlobStore.Entry(
          physicalID: PhysicalBlobID(rawValue: uuid),
          partition: manifestTestPartition,
          digest: digest,
          byteCount: data.count,
          lastAccess: Date(timeIntervalSinceReferenceDate: 1)
        )
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try writePrivateFile(try encoder.encode(legacy), to: recordURL)

      let reopened = try await FileBlobStore.open(root: root)
      #expect(try await reopened.read(digest: digest, partition: manifestTestPartition) == data)
    }
  }

  @Test("AKASHIC-CT-048 legacy v1 tombstone removes snapshot entry after upgrade")
  func legacyV1TombstoneRemovesSnapshotEntry() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("legacy-tombstone-replay")
      let data = Data("legacy-tombstone-replay-payload".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await publishThroughSidecar(
        store: store!,
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let currentRecordURL = try #require(manifestRecordFiles(in: root).first)
      let entry = FileBlobStore.Entry(
        physicalID: publication.physicalID,
        partition: manifestTestPartition,
        digest: digest,
        byteCount: data.count,
        lastAccess: Date(timeIntervalSinceReferenceDate: 1)
      )
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      try FileManager.default.removeItem(at: currentRecordURL)
      let recordURL = legacyManifestRecordURL(root: root, key: key)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let snapshot = FileBlobStore.Manifest(generation: 1, entries: [key: entry])
      try writePrivateFile(
        try encoder.encode(snapshot),
        to: root.appendingPathComponent("manifest.json")
      )
      let tombstone = LegacyManifestRecordFixture(
        schemaVersion: 1,
        generation: 1,
        sequence: 1,
        key: key,
        entry: nil
      )
      try writePrivateFile(try encoder.encode(tombstone), to: recordURL)

      let reopened = try await FileBlobStore.open(root: root)
      await expectManifestTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: manifestTestPartition)
      }
      #expect(manifestTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-046 compact v2 record omits duplicate key and rejects filename tamper")
  func compactV2RecordRejectsFilenameTamper() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("compact-record-key")
      let data = Data(repeating: 0xA5, count: 4 * 1024)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await publishThroughSidecar(
        store: store!,
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let record = try #require(manifestRecordFiles(in: root).first)
      let encoded = try Data(contentsOf: record)
      #expect(encoded.count <= 224)
      let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      #expect((object["v"] as? NSNumber)?.uint16Value == 2)
      #expect(object["key"] == nil)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let wrongKey = String(repeating: "0", count: 64)
      #expect(!record.lastPathComponent.contains(wrongKey))
      let tampered = scopedManifestRecordURL(root: root, generation: 1, key: wrongKey)
      try FileManager.default.moveItem(at: record, to: tampered)
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-049 compact tombstone binds deletion to its filename key")
  func compactTombstoneRejectsFilenameTamper() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("compact-tombstone-key")
      let data = Data("compact-tombstone-key".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await store!.commit(data: data, digest: digest, partition: manifestTestPartition)
      try await store!.remove(digest: digest, partition: manifestTestPartition)
      let record = try #require(manifestRecordFiles(in: root).first)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
      )
      #expect(object["e"] == nil)
      #expect(object["k"] != nil)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let wrongKey = String(repeating: "0", count: 64)
      #expect(!record.lastPathComponent.contains(wrongKey))
      let tampered = scopedManifestRecordURL(root: root, generation: 1, key: wrongKey)
      try FileManager.default.moveItem(at: record, to: tampered)
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-056 scoped record filename generation must match record generation")
  func scopedRecordGenerationTamperFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("scoped-generation-tamper")
      let data = Data("scoped-generation-tamper".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await publishThroughSidecar(
        store: store!,
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let record = try #require(manifestRecordFiles(in: root).first)
      let identity = try #require(
        FileBlobStore.ManifestRecord.fileIdentity(from: record.lastPathComponent)
      )
      #expect(identity.generation == 1)
      let tampered = scopedManifestRecordURL(
        root: root,
        generation: 2,
        key: identity.key
      )
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try FileManager.default.moveItem(at: record, to: tampered)
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

}
