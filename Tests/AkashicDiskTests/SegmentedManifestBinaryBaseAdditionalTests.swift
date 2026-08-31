import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

extension SegmentedManifestBinaryBaseTests {
  @Test("AKASHIC-CT-151 V2 epoch-run publication preserves the V2 profile")
  func v2EpochRunPublicationPreservesProfile() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let state = try binaryBaseTestState(count: 4)
      let first = try #require(state.values.sorted(by: { $0.key < $1.key }).first)
      let replacement = SegmentedManifestEntry(
        key: first.key,
        physicalID: PhysicalBlobID(),
        partition: first.partition,
        digest: first.digest,
        byteCount: first.byteCount,
        lastAccess: first.lastAccess.addingTimeInterval(3)
      )
      let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
        state,
        fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
        directory: segments
      )
      let currentRoot = try SegmentedManifestPrototypeV1.makeRootV2(
        generation: 20,
        base: base,
        runs: []
      )
      let rootURL = root.appendingPathComponent("manifest.json")
      try SegmentedManifestPrototypeV1.writeRoot(currentRoot, to: rootURL)
      let nextRoot = try SegmentedManifestPrototypeV1.publishEpochRun(
        mutations: [.upsert(replacement)],
        runFileName: "run-g21-\(UUID().uuidString.lowercased()).seg",
        currentRoot: currentRoot,
        rootURL: rootURL,
        segmentDirectory: segments
      )
      #expect(nextRoot.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(nextRoot.base == base)
      #expect(nextRoot.runs.count == 1)
      #expect(nextRoot.generation == 21)
      let onDisk = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(onDisk == nextRoot)
      var expected = state
      expected[first.key] = replacement
      #expect(
        try SegmentedManifestPrototypeV1.recover(
          root: onDisk,
          segmentDirectory: segments
        ) == expected
      )
    }
  }

  @Test("AKASHIC-CT-152 V2 binary compaction candidate folds runs without changing authority")
  func v2BinaryCompactionCandidateIsNonAuthoritative() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let state = try binaryBaseTestState(count: 8)
      let first = try #require(state.values.sorted(by: { $0.key < $1.key }).first)
      let replacement = SegmentedManifestEntry(
        key: first.key,
        physicalID: PhysicalBlobID(),
        partition: first.partition,
        digest: first.digest,
        byteCount: first.byteCount,
        lastAccess: first.lastAccess.addingTimeInterval(4)
      )
      let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
        state,
        fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
        directory: segments
      )
      let run = try SegmentedManifestPrototypeV1.writeRun(
        [.upsert(replacement)],
        fileName: "run-g30-\(UUID().uuidString.lowercased()).seg",
        directory: segments
      )
      let frozenRoot = try SegmentedManifestPrototypeV1.makeRootV2(
        generation: 30,
        base: base,
        runs: [run]
      )
      let rootURL = root.appendingPathComponent("manifest.json")
      try SegmentedManifestPrototypeV1.writeRoot(frozenRoot, to: rootURL)
      let rootBytesBefore = try Data(contentsOf: rootURL)
      let candidate = try SegmentedManifestBinaryBaseCompactionV2.prepare(
        frozenRoot: frozenRoot,
        segmentDirectory: segments,
        candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
      )
      #expect(try Data(contentsOf: rootURL) == rootBytesBefore)
      #expect(candidate.base.kind == .baseBinaryV1)
      #expect(candidate.frozenRoot == frozenRoot)
      var expected = state
      expected[first.key] = replacement
      #expect(
        try SegmentedManifestPrototypeV1.readBase(
          candidate.base,
          directory: segments
        ) == expected
      )
      let expectedCommitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(expected)
      #expect(candidate.semanticCommitment == expectedCommitment)
    }
  }

  @Test("AKASHIC-CT-153 qualification open runs real V2 FileBlobStore mutations without public adoption")
  func qualificationOpenRunsRealV2Mutations() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try await makeRealBinaryV2FileBlobStoreFixture(root: root)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV2Candidate(root: root)
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedData
      )
      #expect(
        await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedPhysicalID
      )
      var rootOnDisk = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      #expect(rootOnDisk.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(rootOnDisk.base.kind == .baseBinaryV1)

      let newData = Data("v2-real-mutation".utf8)
      let newDigest = BlobDigest.sha256(of: newData)
      let publication = try await store!.commit(
        data: newData,
        digest: newDigest,
        partition: fixture.partition
      )
      #expect(try await store!.read(digest: newDigest, partition: fixture.partition) == newData)
      try await store!.remove(digest: fixture.seedDigest, partition: fixture.partition)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
      }
      rootOnDisk = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      #expect(rootOnDisk.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(rootOnDisk.base.kind == .baseBinaryV1)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV2Candidate(root: root)
      #expect(try await store!.read(digest: newDigest, partition: fixture.partition) == newData)
      #expect(
        await store!.physicalID(digest: newDigest, partition: fixture.partition)
          == publication.physicalID
      )
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
      }
      rootOnDisk = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      #expect(rootOnDisk.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(rootOnDisk.base.kind == .baseBinaryV1)
    }
  }

  @Test("AKASHIC-CT-154 V2 survives the 512-key checkpoint and binary compaction boundary")
  func v2CheckpointAndCompactionStayBinary() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try await makeRealBinaryV2FileBlobStoreFixture(root: root)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV2Candidate(root: root)
      let rootURL = root.appendingPathComponent("manifest.json")
      let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(initialRoot.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(initialRoot.runs.isEmpty)

      var lastData = Data()
      var lastDigest = BlobDigest.sha256(of: Data())
      for index in 0..<FileBlobStore.manifestCheckpointRecordLimit {
        let data = Data("v2-checkpoint-\(index)".utf8)
        let digest = BlobDigest.sha256(of: data)
        _ = try await store!.commit(
          data: data,
          digest: digest,
          partition: fixture.partition
        )
        lastData = data
        lastDigest = digest
      }

      let checkpointedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(checkpointedRoot.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(checkpointedRoot.base.kind == .baseBinaryV1)
      #expect(checkpointedRoot.base == initialRoot.base)
      #expect(checkpointedRoot.runs.count == 1)
      #expect(checkpointedRoot.generation == initialRoot.generation + 1)
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedData
      )
      #expect(try await store!.read(digest: lastDigest, partition: fixture.partition) == lastData)
      #expect(
        await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedPhysicalID
      )

      await expectFileBlobStoreTestAkashicError(.unsupportedSchema) {
        _ = try await store!.resourceProbeCompactSegmentedManifestV1()
      }
      let beforeV2Compaction = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(beforeV2Compaction == checkpointedRoot)
      #expect(try await store!.resourceProbeCompactSegmentedManifestV2())
      let compactedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(compactedRoot.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(compactedRoot.base.kind == .baseBinaryV1)
      #expect(compactedRoot.base != checkpointedRoot.base)
      #expect(compactedRoot.runs.isEmpty)
      #expect(compactedRoot.generation == checkpointedRoot.generation)
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedData
      )
      #expect(try await store!.read(digest: lastDigest, partition: fixture.partition) == lastData)
      #expect(
        await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedPhysicalID
      )

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV2Candidate(root: root)
      #expect(try await store!.read(digest: lastDigest, partition: fixture.partition) == lastData)
      #expect(
        await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedPhysicalID
      )
      let reopenedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(reopenedRoot == compactedRoot)
    }
  }

  @Test("AKASHIC-CT-155 V2 keeps logical partition authority separate from physical identity")
  func v2PreservesPartitionIsolationAndPartitionScopedDedup() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try await makeRealBinaryV2FileBlobStoreFixture(root: root)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV2Candidate(root: root)
      let secondPartition = try fileBlobStoreTestPartition("binary-v2-real-second")
      let secondPublication = try await store!.commit(
        data: fixture.seedData,
        digest: fixture.seedDigest,
        partition: secondPartition
      )
      #expect(secondPublication.physicalID != fixture.seedPhysicalID)
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
          == fixture.seedData
      )
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: secondPartition)
          == fixture.seedData
      )
      try await store!.remove(digest: fixture.seedDigest, partition: fixture.partition)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
      }
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: secondPartition)
          == fixture.seedData
      )
      #expect(
        await store!.physicalID(digest: fixture.seedDigest, partition: secondPartition)
          == secondPublication.physicalID
      )
      let rootOnDisk = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      #expect(rootOnDisk.profile == SegmentedManifestPrototypeV1.profileV2)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV2Candidate(root: root)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
      }
      #expect(
        try await store!.read(digest: fixture.seedDigest, partition: secondPartition)
          == fixture.seedData
      )
      #expect(
        await store!.physicalID(digest: fixture.seedDigest, partition: secondPartition)
          == secondPublication.physicalID
      )
    }
  }
}
