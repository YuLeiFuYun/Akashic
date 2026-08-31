import AkashicCore
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk manifest v2")
struct FileBlobStoreManifestV2Tests {
  @Test("AKASHIC-CT-030 incremental manifest records replay after reopen")
  func incrementalManifestReplay() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("incremental-replay")
      let firstData = Data("incremental-first".utf8)
      let secondData = Data("incremental-second".utf8)
      let firstDigest = BlobDigest.sha256(of: firstData)
      let secondDigest = BlobDigest.sha256(of: secondData)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await store!.commit(
        data: firstData,
        digest: firstDigest,
        partition: manifestTestPartition
      )
      _ = try await store!.commit(
        data: secondData,
        digest: secondDigest,
        partition: manifestTestPartition
      )
      #expect(manifestRecordFiles(in: root).isEmpty)
      #expect(try manifestXattrRecordCount(in: root, generation: 1) == 2)

      store = nil
      let reopened = try await reopenFileBlobStore(root: root)
      #expect(
        try await reopened.read(digest: firstDigest, partition: manifestTestPartition) == firstData
      )
      #expect(
        try await reopened.read(digest: secondDigest, partition: manifestTestPartition) == secondData
      )
    }
  }

  @Test("AKASHIC-CT-031 incremental tombstone remains a miss after reopen")
  func incrementalTombstoneReplay() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("incremental-tombstone")
      let data = Data("incremental-tombstone".utf8)
      let digest = BlobDigest.sha256(of: data)
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      _ = try await store!.commit(data: data, digest: digest, partition: manifestTestPartition)
      try await store!.remove(digest: digest, partition: manifestTestPartition)
      #expect(manifestRecordFiles(in: root).count == 1)

      store = nil
      let reopened = try await reopenFileBlobStore(root: root)
      await expectManifestTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: manifestTestPartition)
      }
      #expect(manifestTestBlobFiles(in: root).isEmpty)
    }
  }

  @Test("AKASHIC-CT-032 corrupt incremental record fails closed")
  func corruptIncrementalRecordFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("corrupt-incremental-record")
      let data = Data("corrupt-incremental-record".utf8)
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
      try writePrivateFile(Data("not-json".utf8), to: record)

      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-033 checkpoint retires record authority and amortizes physical cleanup")
  func multiKeyMaintenanceCheckpoint() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("multi-key-checkpoint")
      let values = [Data("checkpoint-a".utf8), Data("checkpoint-b".utf8)]
      let digests = values.map(BlobDigest.sha256(of:))
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      for (data, digest) in zip(values, digests) {
        _ = try await publishThroughSidecar(
          store: store!,
          data: data,
          digest: digest,
          partition: manifestTestPartition
        )
      }
      #expect(manifestRecordFiles(in: root).count == 2)
      try await store!.removeAll(partition: manifestTestPartition)
      let retired = manifestRecordFiles(in: root)
      #expect(retired.count == 2)
      #expect(
        retired.allSatisfy {
          FileBlobStore.ManifestRecord.fileIdentity(from: $0.lastPathComponent)?.generation == 1
        }
      )
      let snapshot = try JSONDecoder().decode(
        FileBlobStore.Manifest.self,
        from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
      )
      #expect(snapshot.generation == 2)
      #expect(snapshot.entries.isEmpty)

      store = nil
      let reopened = try await reopenFileBlobStore(root: root)
      for digest in digests {
        await expectManifestTestAkashicError(.notFound) {
          _ = try await reopened.read(digest: digest, partition: manifestTestPartition)
        }
      }

      for index in 0..<2 {
        let cleanupData = Data("cleanup-debt-\(index)".utf8)
        _ = try await publishThroughSidecar(
          store: reopened,
          data: cleanupData,
          digest: BlobDigest.sha256(of: cleanupData),
          partition: manifestTestPartition
        )
      }
      let afterRepayment = manifestRecordFiles(in: root).compactMap {
        FileBlobStore.ManifestRecord.fileIdentity(from: $0.lastPathComponent)
      }
      #expect(afterRepayment.filter { $0.generation == 1 }.isEmpty)
      #expect(afterRepayment.filter { $0.generation == 2 }.count == 2)
    }
  }

  @Test("AKASHIC-CT-034 stale generation record cannot resurrect an entry")
  func staleGenerationRecordCannotResurrect() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("stale-record")
      let values = [Data("stale-seed-a".utf8), Data("stale-seed-b".utf8)]
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      for data in values {
        _ = try await store!.commit(
          data: data,
          digest: BlobDigest.sha256(of: data),
          partition: manifestTestPartition
        )
      }
      try await store!.removeAll(partition: manifestTestPartition)
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      let staleData = Data("stale-generation-payload".utf8)
      let staleDigest = BlobDigest.sha256(of: staleData)
      let stalePhysicalID = PhysicalBlobID()
      let staleBlob = manifestTestBlobURL(root: root, id: stalePhysicalID)
      try writePrivateFile(staleData, to: staleBlob)
      let key = FileBlobStoreIdentity.manifestKey(
        digest: staleDigest,
        partition: manifestTestPartition
      )
      let staleRecord = FileBlobStore.ManifestRecord(
        generation: 1,
        sequence: 1,
        key: key,
        entry: FileBlobStore.Entry(
          physicalID: stalePhysicalID,
          partition: manifestTestPartition,
          digest: staleDigest,
          byteCount: staleData.count,
          lastAccess: Date()
        )
      )
      let recordURL = legacyManifestRecordURL(root: root, key: key)
      try writePrivateFile(try JSONEncoder().encode(staleRecord), to: recordURL)

      let reopened = try await FileBlobStore.open(root: root)
      await expectManifestTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: staleDigest, partition: manifestTestPartition)
      }
      #expect(!FileManager.default.fileExists(atPath: staleBlob.path))
      // record 已失去 logical authority，但作为 bounded physical cleanup debt 可以继续存在。
      #expect(FileManager.default.fileExists(atPath: recordURL.path))
    }
  }

  @Test("AKASHIC-CT-057 stale scoped record content is not part of current authority")
  func staleScopedRecordContentIsIgnored() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let manifestTestPartition = try manifestTestPartition("stale-scoped-content")
      let values = [Data("stale-scoped-a".utf8), Data("stale-scoped-b".utf8)]
      let digests = values.map(BlobDigest.sha256(of:))
      var store: FileBlobStore? = try await FileBlobStore.open(root: root)
      for (data, digest) in zip(values, digests) {
        _ = try await publishThroughSidecar(
          store: store!,
          data: data,
          digest: digest,
          partition: manifestTestPartition
        )
      }
      try await store!.removeAll(partition: manifestTestPartition)
      let staleRecord = try #require(
        manifestRecordFiles(in: root).first {
          FileBlobStore.ManifestRecord.fileIdentity(from: $0.lastPathComponent)?.generation == 1
        }
      )
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try writePrivateFile(Data("corrupt-stale-content".utf8), to: staleRecord)

      let reopened = try await FileBlobStore.open(root: root)
      for digest in digests {
        await expectManifestTestAkashicError(.notFound) {
          _ = try await reopened.read(digest: digest, partition: manifestTestPartition)
        }
      }
      #expect(FileManager.default.fileExists(atPath: staleRecord.path))
    }
  }

}
