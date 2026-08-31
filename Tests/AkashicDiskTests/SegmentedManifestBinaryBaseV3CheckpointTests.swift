import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

extension SegmentedManifestBinaryBaseV3Tests {
  @Test("AKASHIC-CT-177 V3 checkpoint preseal preserves cross-key PhysicalBlobID transfer")
  func v3CheckpointPresealPhysicalTransfer() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let seeds = try await makeRealBinaryV3SeedSet(
        root: root,
        count: 512,
        domain: "checkpoint-preseal-transfer"
      )
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      let rootURL = root.appendingPathComponent("manifest.json")
      let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)

      for index in 0..<480 {
        let seed = seeds[index]
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 810_000_000 + Double(index))
        )
      }
      let preseal = try await store!.resourceProbePrepareSegmentedCheckpointPresealV3()
      #expect(preseal.sourceDistinctKeyCount == 480)
      #expect(preseal.candidateRecordCount == 480)

      let donor = seeds[0]
      _ = try await store!.persistSingleKeyManifestEntry(key: donor.key, entry: nil)
      let transferPartition = try fileBlobStoreTestPartition("checkpoint-preseal-transfer-target")
      let transferKey = FileBlobStoreIdentity.manifestKey(
        digest: donor.digest,
        partition: transferPartition
      )
      let transferEntry = FileBlobStore.Entry(
        physicalID: donor.physicalID,
        partition: transferPartition,
        digest: donor.digest,
        byteCount: donor.data.count,
        lastAccess: Date(timeIntervalSinceReferenceDate: 811_000_000)
      )
      _ = try await store!.persistSingleKeyManifestEntry(
        key: transferKey,
        entry: transferEntry
      )

      for index in 480..<510 {
        let seed = seeds[index]
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 812_000_000 + Double(index))
        )
      }
      let boundary = seeds[510]
      try await store!.resourceProbeRepublishEntry(
        digest: boundary.digest,
        partition: boundary.partition,
        lastAccess: Date(timeIntervalSinceReferenceDate: 813_000_000)
      )

      let checkpointed = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(checkpointed.base == initialRoot.base)
      #expect(checkpointed.generation == initialRoot.generation + 1)
      #expect(checkpointed.runs.map(\.recordCount) == [480, 33])
      #expect(checkpointed.runs.first?.fileName == preseal.candidateFileName)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: donor.digest, partition: donor.partition)
      }
      #expect(try await store!.read(digest: donor.digest, partition: transferPartition) == donor.data)
      #expect(await store!.physicalID(digest: donor.digest, partition: transferPartition) == donor.physicalID)

      let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(await store!.resourceProbeManifestShadowSnapshot() == beforeReopen)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: donor.digest, partition: donor.partition)
      }
      #expect(try await store!.read(digest: donor.digest, partition: transferPartition) == donor.data)
      #expect(await store!.physicalID(digest: donor.digest, partition: transferPartition) == donor.physicalID)
    }
  }

  @Test("AKASHIC-CT-165 V3 keeps partition authority separate from physical identity")
  func v3PartitionIsolation() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try await makeRealBinaryV3FileBlobStoreFixture(root: root)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      let second = try fileBlobStoreTestPartition("binary-v3-second")
      let publication = try await store!.commit(
        data: fixture.seedData,
        digest: fixture.seedDigest,
        partition: second
      )
      #expect(publication.physicalID != fixture.seedPhysicalID)
      try await store!.remove(digest: fixture.seedDigest, partition: fixture.partition)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
      }
      #expect(try await store!.read(digest: fixture.seedDigest, partition: second) == fixture.seedData)
      #expect(await store!.physicalID(digest: fixture.seedDigest, partition: second) == publication.physicalID)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(try await store!.read(digest: fixture.seedDigest, partition: second) == fixture.seedData)
    }
  }

  @Test("AKASHIC-CT-178 V4 compound run overlays tail and remains fail-closed to V3")
  func v4CompoundWireAndProfileSeparation() throws {
    let entries = try binaryBaseV3TestState(count: 3).values.sorted { $0.key < $1.key }
    let first = try #require(entries.first)
    let second = entries[1]
    let third = entries[2]
    let moved = SegmentedManifestEntry(
      key: third.key,
      physicalID: first.physicalID,
      partition: third.partition,
      digest: third.digest,
      byteCount: third.byteCount,
      lastAccess: third.lastAccess.addingTimeInterval(10)
    )
    let prefix = [
      SegmentedManifestMutation.upsert(first),
      .upsert(second),
    ].sorted { $0.key < $1.key }
    let tail = [
      SegmentedManifestMutation.tombstone(key: first.key),
      .upsert(moved),
    ].sorted { $0.key < $1.key }
    let data = try SegmentedManifestCompoundRunV1.encodeFinalized(prefix: prefix, tail: tail)
    let decoded = try SegmentedManifestCompoundRunV1.decode(data)
    let applied = try SegmentedManifestPrototypeV1.apply(decoded, to: [:])
    #expect(applied.count == 2)
    #expect(applied[first.key] == nil)
    #expect(applied[second.key] == second)
    #expect(applied[third.key] == moved)
    #expect(applied[third.key]?.physicalID == first.physicalID)

    let compound = try SegmentedManifestCompoundRunV1.finalizedDescriptor(
      fileName: "compound-g1-\(UUID().uuidString.lowercased()).cseg",
      data: data
    )
    let base = SegmentedManifestDescriptorV1(
      kind: .baseBinaryV2,
      fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
      byteCount: try #require(SegmentedManifestBinaryBaseV2.expectedByteCount(recordCount: 0)),
      recordCount: 0,
      sha256: String(repeating: "0", count: 64)
    )
    let v4 = try SegmentedManifestPrototypeV1.makeRootV4(
      generation: 1,
      base: base,
      runs: [compound]
    )
    #expect(v4.profile == SegmentedManifestPrototypeV1.profileV4)
    #expect(v4.runs == [compound])
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestPrototypeV1.makeRootV3(
        generation: 1,
        base: base,
        runs: [compound]
      )
    }

    var corrupted = data
    corrupted[corrupted.count - 1] ^= 0x01
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestCompoundRunV1.decode(corrupted)
    }
  }
}
