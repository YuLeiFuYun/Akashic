import AkashicCore
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk manifest xattr")
struct FileBlobStoreManifestXattrTests {
  @Test("AKASHIC-CT-063 fast xattr authority binds manifest key to its carrier")
  func fastXattrKeyTamperFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("xattr-key-tamper")
      let data = Data("xattr-key-tamper".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let identity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(generation: 1, key: key)
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      let value = try readExtendedAttribute(identity.name, at: blob)
      let record = try JSONDecoder().decode(FileBlobStore.ManifestRecord.self, from: value)
      #expect(record.generation == 1)
      #expect(record.sequence == 1)
      #expect(record.entry?.physicalID == publication.physicalID)
      #expect(manifestRecordFiles(in: root).isEmpty)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let wrongKey = String(repeating: "0", count: 64)
      let wrongIdentity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(generation: 1, key: wrongKey)
      )
      try moveExtendedAttribute(
        from: identity.name,
        to: wrongIdentity.name,
        value: value,
        at: blob
      )
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-064 fast xattr authority binds record generation to its name")
  func fastXattrGenerationTamperFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("xattr-generation-tamper")
      let data = Data("xattr-generation-tamper".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let current = try #require(
        FileBlobStore.ManifestXattrIdentity.make(generation: 1, key: key)
      )
      let future = try #require(
        FileBlobStore.ManifestXattrIdentity.make(generation: 2, key: key)
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      let value = try readExtendedAttribute(current.name, at: blob)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try moveExtendedAttribute(
        from: current.name,
        to: future.name,
        value: value,
        at: blob
      )
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-065 fast xattr authority binds entry PhysicalBlobID to carrier UUID")
  func fastXattrPhysicalIdentityTamperFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("xattr-physical-tamper")
      let data = Data("xattr-physical-tamper".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let identity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(generation: 1, key: key)
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      let wrongEntry = FileBlobStore.Entry(
        physicalID: PhysicalBlobID(),
        partition: manifestTestPartition,
        digest: digest,
        byteCount: data.count,
        lastAccess: Date()
      )
      let wrongRecord = FileBlobStore.ManifestRecord(
        generation: 1,
        sequence: 1,
        key: key,
        entry: wrongEntry
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let value = try encoder.encode(wrongRecord)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try replaceExtendedAttribute(identity.name, value: value, at: blob)
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-066 same-key fast repair preserves distinct delta cardinality")
  func fastXattrSameKeyRepairDoesNotConsumeAnotherDeltaKey() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("xattr-same-key-repair")
      let data = Data("xattr-same-key-repair".utf8)
      let digest = BlobDigest.sha256(of: data)
      let store = try await FileBlobStore.open(root: root)
      let first = try await store.commit(data: data, digest: digest, partition: manifestTestPartition)
      #expect(await store.manifestRecordCount == 1)
      #expect(await store.manifestRecordSequence == 1)

      let firstBlob = manifestTestBlobURL(root: root, id: first.physicalID)
      try writePrivateFile(Data(repeating: 0xA7, count: data.count), to: firstBlob)
      let repaired = try await store.commit(data: data, digest: digest, partition: manifestTestPartition)
      #expect(repaired.disposition == .created)
      #expect(repaired.physicalID != first.physicalID)
      #expect(await store.manifestRecordCount == 1)
      #expect(await store.manifestRecordSequence == 2)
      #expect(manifestRecordFiles(in: root).isEmpty)
      #expect(try manifestXattrRecordCount(in: root, generation: 1) == 1)
      #expect(try await store.read(digest: digest, partition: manifestTestPartition) == data)
    }
  }

  @Test("AKASHIC-CT-067 corrupt fast xattr value fails closed")
  func corruptFastXattrValueFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("xattr-corrupt-value")
      let data = Data("xattr-corrupt-value".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: manifestTestPartition
      )
      let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: manifestTestPartition)
      let identity = try #require(
        FileBlobStore.ManifestXattrIdentity.make(generation: 1, key: key)
      )
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try replaceExtendedAttribute(
        identity.name,
        value: Data("not-a-manifest-record".utf8),
        at: blob
      )
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

}
