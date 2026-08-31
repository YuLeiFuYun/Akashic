import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk bootstrap freshness")
struct FileBlobStoreBootstrapFreshnessTests {
  @Test("AKASHIC-CT-127 missing schema4 manifest fails closed even when no payload files remain")
  func missingSchema4ManifestWithOnlyDirectoryHeadsFailsClosed() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      #expect(await store!.manifest.entries.isEmpty)
      #expect(memory.attributeNames().filter { $0.hasPrefix("dev.akashic.mh1.") }.count == 2)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try FileManager.default.removeItem(
        at: root.appendingPathComponent("manifest.json", isDirectory: false)
      )

      await expectManifestTestAkashicError(.invalidManifest) {
        _ = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          directoryHeadOperations: memory.operations
        )
      }
      #expect(memory.attributeNames().filter { $0.hasPrefix("dev.akashic.mh1.") }.count == 2)
    }
  }

  @Test("AKASHIC-CT-128 malformed directory-head family metadata blocks fresh initialization")
  func malformedDirectoryHeadFamilyMetadataBlocksInitialization() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      memory.set("dev.akashic.mh1.gmalformed.0", Data("foreign".utf8))

      await expectManifestTestAkashicError(.invalidManifest) {
        _ = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          directoryHeadOperations: memory.operations
        )
      }
      #expect(
        !FileManager.default.fileExists(
          atPath: root.appendingPathComponent("manifest.json", isDirectory: false).path
        )
      )
    }
  }

  @Test("AKASHIC-CT-130 schema4 physical heads prevent rollback to a legacy manifest")
  func schema4PhysicalHeadsRejectLegacyManifestRollback() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-root-rollback".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-root-rollback")
      let publication = try await store!.commit(
        data: data,
        digest: digest,
        partition: partition
      )
      let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
      let legacySnapshot = try Data(contentsOf: manifestURL)
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      #expect(memory.attributeNames().contains { $0.hasPrefix("dev.akashic.mh1.") })
      let blob = manifestTestBlobURL(root: root, id: publication.physicalID)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      try FileManager.default.removeItem(at: manifestURL)
      try writePrivateFile(legacySnapshot, to: manifestURL)

      await expectManifestTestAkashicError(.invalidManifest) {
        _ = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          directoryHeadOperations: memory.operations
        )
      }
      #expect(FileManager.default.fileExists(atPath: blob.path))
    }
  }

  @Test("AKASHIC-CT-131 schema4 root generation mismatch fails closed before delta loss")
  func schema4RootGenerationMismatchRejectsOlderPhysicalHeads() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )

      let seedData = Data("schema4-generation-seed".utf8)
      let seedDigest = BlobDigest.sha256(of: seedData)
      let seedPartition = try manifestTestPartition("schema4-generation-seed")
      _ = try await store!.commit(
        data: seedData,
        digest: seedDigest,
        partition: seedPartition
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())

      let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
      let snapshotData = try Data(contentsOf: manifestURL)
      let snapshot = try JSONDecoder().decode(FileBlobStore.Manifest.self, from: snapshotData)
      let generation = snapshot.generation

      let deltaData = Data("schema4-generation-delta".utf8)
      let deltaDigest = BlobDigest.sha256(of: deltaData)
      let deltaPartition = try manifestTestPartition("schema4-generation-delta")
      let publication = try await store!.commit(
        data: deltaData,
        digest: deltaDigest,
        partition: deltaPartition
      )
      #expect((await store!.directoryHeadState)?.activeHead.s == 1)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let nextGeneration = generation.addingReportingOverflow(1)
      #expect(!nextGeneration.overflow)
      let source = String(decoding: snapshotData, as: UTF8.self)
      let oldGeneration = "\"generation\":\(generation)"
      let newGeneration = "\"generation\":\(nextGeneration.partialValue)"
      #expect(source.components(separatedBy: oldGeneration).count == 2)
      let advancedData = Data(
        source.replacingOccurrences(of: oldGeneration, with: newGeneration).utf8
      )
      try FileManager.default.removeItem(at: manifestURL)
      try writePrivateFile(advancedData, to: manifestURL)

      await expectManifestTestAkashicError(.invalidManifest) {
        _ = try await FileBlobStore.open(
          root: root,
          faultInjector: { _ in },
          directoryHeadOperations: memory.operations
        )
      }
      let deltaBlob = manifestTestBlobURL(root: root, id: publication.physicalID)
      #expect(FileManager.default.fileExists(atPath: deltaBlob.path))
    }
  }

  @Test("AKASHIC-CT-129 fresh schema3 initialization remains available when directory xattrs are unsupported")
  func freshInitializationSurvivesUnsupportedDirectoryXattrs() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let unsupported = FileBlobStoreDirectoryHeadOperations(
        listAttributes: { _, _ in throw POSIXError(.ENOTSUP) },
        readAttribute: { _, _, _ in throw POSIXError(.ENOTSUP) },
        setAttribute: { _, _, _, _ in throw POSIXError(.ENOTSUP) },
        removeAttribute: { _, _ in throw POSIXError(.ENOTSUP) },
        synchronizeDirectory: { _ in throw POSIXError(.ENOTSUP) }
      )
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: unsupported
      )
      #expect(await store.manifest.schemaVersion == FileBlobStore.currentSchemaVersion)
      #expect(await store.manifest.entries.isEmpty)
      #expect(
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("manifest.json", isDirectory: false).path
        )
      )
    }
  }
}
