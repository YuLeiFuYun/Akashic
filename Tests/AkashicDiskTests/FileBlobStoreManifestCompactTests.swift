import AkashicCore
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk compact manifest")
struct FileBlobStoreManifestCompactTests {
  @Test("AKASHIC-CT-058 verbose manifest v2 opens and checkpoints into compact v3")
  func verboseManifestV2MigratesToV3() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("manifest-v2-migration")
      try StorageDirectorySecurity.prepareDirectory(root)
      try StorageDirectorySecurity.prepareDirectory(
        root.appendingPathComponent("blobs", isDirectory: true)
      )
      let values = [Data("manifest-v2-a".utf8), Data("manifest-v2-b".utf8)]
      let digests = values.map(BlobDigest.sha256(of:))
      let physicalIDs = [PhysicalBlobID(), PhysicalBlobID()]
      var entries: [String: FileBlobStore.Entry] = [:]
      for index in values.indices {
        let blob = manifestTestBlobURL(root: root, id: physicalIDs[index])
        try writePrivateFile(values[index], to: blob)
        let entry = FileBlobStore.Entry(
          physicalID: physicalIDs[index],
          partition: manifestTestPartition,
          digest: digests[index],
          byteCount: values[index].count,
          lastAccess: Date()
        )
        entries[FileBlobStoreIdentity.manifestKey(digest: digests[index], partition: manifestTestPartition)] = entry
      }
      let legacy = FileBlobStore.Manifest(schemaVersion: 2, generation: 1, entries: entries)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try writePrivateFile(
        try encoder.encode(legacy),
        to: root.appendingPathComponent("manifest.json")
      )

      let store = try await FileBlobStore.open(root: root)
      for index in values.indices {
        #expect(try await store.read(digest: digests[index], partition: manifestTestPartition) == values[index])
      }
      try await store.removeAll(partition: manifestTestPartition)

      let raw = try #require(
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        ) as? [String: Any]
      )
      #expect((raw["schemaVersion"] as? NSNumber)?.uint16Value == 3)
      #expect(raw["e"] != nil)
      #expect(raw["entries"] == nil)
      for digest in digests {
        await expectManifestTestAkashicError(.notFound) {
          _ = try await store.read(digest: digest, partition: manifestTestPartition)
        }
      }
    }
  }

  @Test("AKASHIC-CT-059 compact v3 rejects duplicate physical ownership")
  func compactV3DuplicatePhysicalIDFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let manifestTestPartition = try manifestTestPartition("compact-v3-duplicate-physical")
      let sharedPhysicalID = PhysicalBlobID()
      let first = Data("compact-v3-physical-a".utf8)
      let second = Data("compact-v3-physical-b".utf8)
      let firstDigest = BlobDigest.sha256(of: first)
      let secondDigest = BlobDigest.sha256(of: second)
      let entries = [
        FileBlobStoreIdentity.manifestKey(digest: firstDigest, partition: manifestTestPartition):
          FileBlobStore.Entry(
            physicalID: sharedPhysicalID,
            partition: manifestTestPartition,
            digest: firstDigest,
            byteCount: first.count,
            lastAccess: Date()
          ),
        FileBlobStoreIdentity.manifestKey(digest: secondDigest, partition: manifestTestPartition):
          FileBlobStore.Entry(
            physicalID: sharedPhysicalID,
            partition: manifestTestPartition,
            digest: secondDigest,
            byteCount: second.count,
            lastAccess: Date()
          ),
      ]
      let manifest = FileBlobStore.Manifest(generation: 1, entries: entries)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try writePrivateFile(
        try encoder.encode(manifest),
        to: root.appendingPathComponent("manifest.json")
      )
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-060 compact v3 preserves zero-byte blob semantics")
  func compactV3ZeroByteBlobRoundTrip() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      try StorageDirectorySecurity.prepareDirectory(
        root.appendingPathComponent("blobs", isDirectory: true)
      )
      let manifestTestPartition = try manifestTestPartition("compact-v3-zero-byte")
      let data = Data()
      let digest = BlobDigest.sha256(of: data)
      let physicalID = PhysicalBlobID()
      try writePrivateFile(data, to: manifestTestBlobURL(root: root, id: physicalID))
      let entry = FileBlobStore.Entry(
        physicalID: physicalID,
        partition: manifestTestPartition,
        digest: digest,
        byteCount: 0,
        lastAccess: Date()
      )
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let manifest = FileBlobStore.Manifest(generation: 1, entries: [key: entry])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try writePrivateFile(
        try encoder.encode(manifest),
        to: root.appendingPathComponent("manifest.json")
      )

      let store = try await FileBlobStore.open(root: root)
      #expect(try await store.read(digest: digest, partition: manifestTestPartition) == data)
    }
  }

  @Test("AKASHIC-CT-061 replay rejects duplicate physical ownership across records")
  func replayDuplicatePhysicalIDFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      try StorageDirectorySecurity.prepareDirectory(
        root.appendingPathComponent("blobs", isDirectory: true)
      )
      let initial = FileBlobStore.Manifest()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try writePrivateFile(
        try encoder.encode(initial),
        to: root.appendingPathComponent("manifest.json")
      )

      let manifestTestPartition = try manifestTestPartition("replay-duplicate-physical")
      let sharedPhysicalID = PhysicalBlobID()
      for sequence in 1...2 {
        let data = Data("replay-duplicate-physical-\(sequence)".utf8)
        let digest = BlobDigest.sha256(of: data)
        let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
        let entry = FileBlobStore.Entry(
          physicalID: sharedPhysicalID,
          partition: manifestTestPartition,
          digest: digest,
          byteCount: data.count,
          lastAccess: Date()
        )
        let record = FileBlobStore.ManifestRecord(
          generation: 1,
          sequence: UInt64(sequence),
          key: key,
          entry: entry
        )
        let recordURL = scopedManifestRecordURL(root: root, generation: 1, key: key)
        try writePrivateFile(try encoder.encode(record), to: recordURL)
      }

      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-062 optimized manifest key is byte-identical to legacy protocol")
  func optimizedManifestKeyMatchesLegacyProtocol() throws {
    let manifestTestPartition = try manifestTestPartition("manifest-key-differential")
    let digestBytes = Data((0..<32).map(UInt8.init))
    for byteCount in [0, 1, 9, 10, 255, 256, 4_096, 1_048_576, Int.max] {
      let digest = try BlobDigest(
        algorithm: .sha256,
        bytes: digestBytes,
        byteCount: byteCount
      )
      #expect(
        FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
          == legacyManifestKey(digest: digest, partition: manifestTestPartition)
      )
    }
  }

  @Test("AKASHIC-CT-047 future compact record schema fails closed")
  func futureCompactRecordSchemaFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("future-compact-record")
      let data = Data("future-compact-record".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await publishThroughSidecar(
        store: store!,
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let record = try #require(manifestRecordFiles(in: root).first)
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
      )
      object["v"] = 999
      let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      try writePrivateFile(future, to: record)
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

}
