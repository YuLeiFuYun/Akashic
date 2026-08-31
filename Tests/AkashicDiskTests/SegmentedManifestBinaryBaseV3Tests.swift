import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk segmented binary base V3")
struct SegmentedManifestBinaryBaseV3Tests {
  @Test("AKASHIC-CT-158 V3 uses the 92-byte wire and round-trips exact state")
  func v3WireRoundTrip() throws {
    #expect(SegmentedManifestBinaryBaseV2.recordBytes == 92)
    let state = try binaryBaseV3TestState(count: 32)
    let encoded = try SegmentedManifestBinaryBaseV2.encode(state)
    #expect(
      encoded.count
        == SegmentedManifestBinaryBaseV2.headerBytes
          + SegmentedManifestBinaryBaseV2.recordBytes * state.count
    )
    #expect(try SegmentedManifestBinaryBaseV2.decode(encoded) == state)

    var corrupted = encoded
    corrupted[SegmentedManifestBinaryBaseV2.headerBytes + 80] ^= 0x01
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestBinaryBaseV2.decode(corrupted)
    }
  }

  @Test("AKASHIC-CT-159 V1 V2 and V3 roots reject mixed base kinds")
  func v3ProfileSeparation() throws {
    let json = SegmentedManifestDescriptorV1(
      kind: .baseJSON,
      fileName: "base-test.json",
      byteCount: 1,
      recordCount: 0,
      sha256: String(repeating: "0", count: 64)
    )
    let v2 = SegmentedManifestDescriptorV1(
      kind: .baseBinaryV1,
      fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
      byteCount: try #require(SegmentedManifestBinaryBaseV1.expectedByteCount(recordCount: 0)),
      recordCount: 0,
      sha256: String(repeating: "0", count: 64)
    )
    let v3 = SegmentedManifestDescriptorV1(
      kind: .baseBinaryV2,
      fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
      byteCount: try #require(SegmentedManifestBinaryBaseV2.expectedByteCount(recordCount: 0)),
      recordCount: 0,
      sha256: String(repeating: "0", count: 64)
    )
    #expect(try SegmentedManifestPrototypeV1.makeRoot(generation: 1, base: json, runs: []).profile
      == SegmentedManifestPrototypeV1.profileV1)
    #expect(try SegmentedManifestPrototypeV1.makeRootV2(generation: 1, base: v2, runs: []).profile
      == SegmentedManifestPrototypeV1.profileV2)
    #expect(try SegmentedManifestPrototypeV1.makeRootV3(generation: 1, base: v3, runs: []).profile
      == SegmentedManifestPrototypeV1.profileV3)
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestPrototypeV1.makeRootV3(generation: 1, base: v2, runs: [])
    }
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestPrototypeV1.makeRootV2(generation: 1, base: v3, runs: [])
    }
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestPrototypeV1.makeRoot(generation: 1, base: v3, runs: [])
    }
  }

  @Test("AKASHIC-CT-160 V3 namespace is exact and unreferenced candidates are debt")
  func v3NamespaceAndDebt() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let name = "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
      #expect(SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(name, kind: .baseBinaryV2))
      #expect(!SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(name.uppercased(), kind: .baseBinaryV2))
      #expect(!SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
        name.replacingOccurrences(of: ".akb2", with: ".akb"),
        kind: .baseBinaryV2
      ))
      #expect(SegmentedManifestSegmentCleanupV1.isProductionCanonical(name))
      _ = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
        try binaryBaseV3TestState(count: 3),
        fileName: name,
        directory: segments
      )
      let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: nil,
        directory: segments
      )
      #expect(cleanup.deletedCount == 1)
      #expect(cleanup.remainingDebtCount == 0)
    }
  }

  @Test("AKASHIC-CT-177 repeated deterministic run bytes remain valid under distinct physical names")
  func repeatedRunContentHashDoesNotRejectPeriodicEpochs() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let state = try binaryBaseV3TestState(count: 1)
      let key = try #require(state.keys.first)
      let base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
        state,
        fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
        directory: segments
      )
      let first = try SegmentedManifestPrototypeV1.writeRun(
        [.tombstone(key: key)],
        fileName: "run-g2-\(UUID().uuidString.lowercased()).seg",
        directory: segments
      )
      let second = try SegmentedManifestPrototypeV1.writeRun(
        [.tombstone(key: key)],
        fileName: "run-g3-\(UUID().uuidString.lowercased()).seg",
        directory: segments
      )
      #expect(first.fileName != second.fileName)
      #expect(first.sha256 == second.sha256)
      #expect(first.byteCount == second.byteCount)

      let manifest = try SegmentedManifestPrototypeV1.makeRootV3(
        generation: 3,
        base: base,
        runs: [first, second]
      )
      #expect(
        try SegmentedManifestPrototypeV1.recover(
          root: manifest,
          segmentDirectory: segments
        ).isEmpty
      )
    }
  }

  @Test("AKASHIC-CT-161 V1 to V3 transition preserves generation state and PhysicalBlobID")
  func v1ToV3TransitionIsPhysicalOnly() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try makeBinaryV3V1Fixture(root: root)
      let beforeRootBytes = try Data(contentsOf: fixture.rootURL)
      let candidate = try SegmentedManifestBinaryBaseTransitionV3.prepare(
        frozenRoot: fixture.root,
        segmentDirectory: fixture.segments,
        candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
      )
      #expect(try Data(contentsOf: fixture.rootURL) == beforeRootBytes)
      #expect(candidate.root.generation == fixture.root.generation)
      #expect(candidate.root.profile == SegmentedManifestPrototypeV1.profileV3)
      #expect(candidate.root.base.kind == .baseBinaryV2)
      #expect(candidate.root.runs.isEmpty)
      #expect(
        try SegmentedManifestPrototypeV1.recover(
          root: candidate.root,
          segmentDirectory: fixture.segments
        ) == fixture.expected
      )
      try SegmentedManifestPrototypeV1.writeRoot(candidate.root, to: fixture.rootURL)
      let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: candidate.root,
        directory: fixture.segments
      )
      #expect(cleanup.deletedCount == 2)
      #expect(cleanup.remainingDebtCount == 0)
      #expect(
        try SegmentedManifestPrototypeV1.recover(
          rootURL: fixture.rootURL,
          segmentDirectory: fixture.segments
        ) == fixture.expected
      )
    }
  }

  @Test("AKASHIC-CT-162 V3 run publication preserves profile")
  func v3RunPublicationPreservesProfile() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let state = try binaryBaseV3TestState(count: 4)
      let first = try #require(state.values.sorted(by: { $0.key < $1.key }).first)
      let replacement = SegmentedManifestEntry(
        key: first.key,
        physicalID: PhysicalBlobID(),
        partition: first.partition,
        digest: first.digest,
        byteCount: first.byteCount,
        lastAccess: first.lastAccess.addingTimeInterval(1)
      )
      let base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
        state,
        fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
        directory: segments
      )
      let current = try SegmentedManifestPrototypeV1.makeRootV3(
        generation: 40,
        base: base,
        runs: []
      )
      let rootURL = root.appendingPathComponent("manifest.json")
      try SegmentedManifestPrototypeV1.writeRoot(current, to: rootURL)
      let next = try SegmentedManifestPrototypeV1.publishEpochRun(
        mutations: [.upsert(replacement)],
        runFileName: "run-g41-\(UUID().uuidString.lowercased()).seg",
        currentRoot: current,
        rootURL: rootURL,
        segmentDirectory: segments
      )
      #expect(next.profile == SegmentedManifestPrototypeV1.profileV3)
      #expect(next.base == base)
      #expect(next.generation == 41)
      var expected = state
      expected[first.key] = replacement
      #expect(try SegmentedManifestPrototypeV1.recover(root: next, segmentDirectory: segments) == expected)
    }
  }

  @Test("AKASHIC-CT-163 public open remains V1-only while V3 qualification runs real mutations")
  func v3QualificationOpenIsNotPublicAdoption() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try await makeRealBinaryV3FileBlobStoreFixture(root: root)
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(try await store!.read(digest: fixture.seedDigest, partition: fixture.partition) == fixture.seedData)
      #expect(await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition) == fixture.seedPhysicalID)
      let data = Data("v3-real-mutation".utf8)
      let digest = BlobDigest.sha256(of: data)
      _ = try await store!.commit(data: data, digest: digest, partition: fixture.partition)
      #expect(try await store!.read(digest: digest, partition: fixture.partition) == data)
      let rootOnDisk = try SegmentedManifestPrototypeV1.readRoot(from: root.appendingPathComponent("manifest.json"))
      #expect(rootOnDisk.profile == SegmentedManifestPrototypeV1.profileV3)
      #expect(rootOnDisk.base.kind == .baseBinaryV2)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(try await store!.read(digest: digest, partition: fixture.partition) == data)
    }
  }

  @Test("AKASHIC-CT-164 V3 survives 512-key checkpoint and V3 compaction")
  func v3CheckpointAndCompaction() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try await makeRealBinaryV3FileBlobStoreFixture(root: root)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      let rootURL = root.appendingPathComponent("manifest.json")
      let initial = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      var lastData = Data()
      var lastDigest = BlobDigest.sha256(of: Data())
      for index in 0..<FileBlobStore.manifestCheckpointRecordLimit {
        let data = Data("v3-checkpoint-\(index)".utf8)
        let digest = BlobDigest.sha256(of: data)
        _ = try await store!.commit(data: data, digest: digest, partition: fixture.partition)
        lastData = data
        lastDigest = digest
      }
      let checkpointed = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(checkpointed.profile == SegmentedManifestPrototypeV1.profileV3)
      #expect(checkpointed.base.kind == .baseBinaryV2)
      #expect(checkpointed.base == initial.base)
      #expect(checkpointed.runs.count == 1)
      #expect(checkpointed.generation == initial.generation + 1)
      await expectFileBlobStoreTestAkashicError(.unsupportedSchema) {
        _ = try await store!.resourceProbeCompactSegmentedManifestV1()
      }
      await expectFileBlobStoreTestAkashicError(.unsupportedSchema) {
        _ = try await store!.resourceProbeCompactSegmentedManifestV2()
      }
      #expect(try await store!.resourceProbeCompactSegmentedManifestV3())
      let compacted = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(compacted.profile == SegmentedManifestPrototypeV1.profileV3)
      #expect(compacted.base.kind == .baseBinaryV2)
      #expect(compacted.runs.isEmpty)
      #expect(compacted.generation == checkpointed.generation)
      #expect(try await store!.read(digest: lastDigest, partition: fixture.partition) == lastData)
      #expect(await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition) == fixture.seedPhysicalID)
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(try await store!.read(digest: lastDigest, partition: fixture.partition) == lastData)
    }
  }

  @Test("AKASHIC-CT-175 V3 bounded checkpoint preserves a tombstone boundary")
  func v3BoundedCheckpointTombstoneBoundary() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let seeds = try await makeRealBinaryV3SeedSet(
        root: root,
        count: 2,
        domain: "bounded-checkpoint-tombstone"
      )
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      let rootURL = root.appendingPathComponent("manifest.json")
      let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)

      var lastData = Data()
      var lastDigest = BlobDigest.sha256(of: Data())
      var lastPartition = seeds[0].partition
      for index in 0..<511 {
        let partition = try fileBlobStoreTestPartition("bounded-tombstone-filler-\(index)")
        let data = Data("bounded-tombstone-filler-\(index)".utf8)
        let digest = BlobDigest.sha256(of: data)
        _ = try await store!.commit(data: data, digest: digest, partition: partition)
        lastData = data
        lastDigest = digest
        lastPartition = partition
      }

      try await store!.remove(digest: seeds[0].digest, partition: seeds[0].partition)
      let checkpointed = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(checkpointed.base == initialRoot.base)
      #expect(checkpointed.generation == initialRoot.generation + 1)
      #expect(checkpointed.runs.count == 1)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: seeds[0].digest, partition: seeds[0].partition)
      }
      #expect(try await store!.read(digest: seeds[1].digest, partition: seeds[1].partition) == seeds[1].data)
      #expect(try await store!.read(digest: lastDigest, partition: lastPartition) == lastData)

      let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(await store!.resourceProbeManifestShadowSnapshot() == beforeReopen)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: seeds[0].digest, partition: seeds[0].partition)
      }
      #expect(try await store!.read(digest: seeds[1].digest, partition: seeds[1].partition) == seeds[1].data)
    }
  }

  @Test("AKASHIC-CT-176 V3 bounded checkpoint replays cross-key PhysicalBlobID transfer safely")
  func v3BoundedCheckpointPhysicalTransfer() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let seeds = try await makeRealBinaryV3SeedSet(
        root: root,
        count: 1,
        domain: "bounded-checkpoint-transfer"
      )
      let seed = try #require(seeds.first)
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      let rootURL = root.appendingPathComponent("manifest.json")
      let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)

      for index in 0..<510 {
        let partition = try fileBlobStoreTestPartition("bounded-transfer-filler-\(index)")
        let data = Data("bounded-transfer-filler-\(index)".utf8)
        let digest = BlobDigest.sha256(of: data)
        _ = try await store!.commit(data: data, digest: digest, partition: partition)
      }

      _ = try await store!.persistSingleKeyManifestEntry(key: seed.key, entry: nil)
      let transferPartition = try fileBlobStoreTestPartition("bounded-transfer-target")
      let transferKey = FileBlobStoreIdentity.manifestKey(
        digest: seed.digest,
        partition: transferPartition
      )
      let transferEntry = FileBlobStore.Entry(
        physicalID: seed.physicalID,
        partition: transferPartition,
        digest: seed.digest,
        byteCount: seed.data.count,
        lastAccess: Date(timeIntervalSinceReferenceDate: 730_000_000)
      )
      _ = try await store!.persistSingleKeyManifestEntry(
        key: transferKey,
        entry: transferEntry
      )

      let checkpointed = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(checkpointed.base == initialRoot.base)
      #expect(checkpointed.generation == initialRoot.generation + 1)
      #expect(checkpointed.runs.count == 1)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: seed.digest, partition: seed.partition)
      }
      #expect(try await store!.read(digest: seed.digest, partition: transferPartition) == seed.data)
      #expect(await store!.physicalID(digest: seed.digest, partition: transferPartition) == seed.physicalID)

      let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      #expect(await store!.resourceProbeManifestShadowSnapshot() == beforeReopen)
      #expect(try await store!.read(digest: seed.digest, partition: transferPartition) == seed.data)
      #expect(await store!.physicalID(digest: seed.digest, partition: transferPartition) == seed.physicalID)
    }
  }
}


struct BinaryV3V1Fixture {
  let root: SegmentedManifestRootV1
  let rootURL: URL
  let segments: URL
  let expected: [String: SegmentedManifestEntry]
}

func makeBinaryV3V1Fixture(root: URL) throws -> BinaryV3V1Fixture {
  try StorageDirectorySecurity.prepareDirectory(root)
  let segments = root.appendingPathComponent("segments", isDirectory: true)
  try StorageDirectorySecurity.prepareDirectory(segments)
  let state = try binaryBaseV3TestState(count: 4)
  let first = try #require(state.values.sorted(by: { $0.key < $1.key }).first)
  let replacement = SegmentedManifestEntry(
    key: first.key,
    physicalID: PhysicalBlobID(),
    partition: first.partition,
    digest: first.digest,
    byteCount: first.byteCount,
    lastAccess: first.lastAccess.addingTimeInterval(2)
  )
  let json = try SegmentedManifestPrototypeV1.encodeCompactionBaseSnapshot(generation: 9, state: state)
  let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
    json,
    entryCount: state.count,
    fileName: "base-compaction-\(UUID().uuidString.lowercased()).json",
    directory: segments
  )
  let run = try SegmentedManifestPrototypeV1.writeRun(
    [.upsert(replacement)],
    fileName: "run-g9-\(UUID().uuidString.lowercased()).seg",
    directory: segments
  )
  let segmentedRoot = try SegmentedManifestPrototypeV1.makeRoot(generation: 9, base: base, runs: [run])
  let rootURL = root.appendingPathComponent("manifest.json")
  try SegmentedManifestPrototypeV1.writeRoot(segmentedRoot, to: rootURL)
  var expected = state
  expected[first.key] = replacement
  return BinaryV3V1Fixture(root: segmentedRoot, rootURL: rootURL, segments: segments, expected: expected)
}

struct RealBinaryV3SeedItem {
  let data: Data
  let digest: BlobDigest
  let partition: CachePartitionID
  let physicalID: PhysicalBlobID
  let key: String
}

func makeRealBinaryV3SeedSet(
  root: URL,
  count: Int,
  domain: String
) async throws -> [RealBinaryV3SeedItem] {
  var store: FileBlobStore? = try await FileBlobStore.open(root: root)
  var items: [RealBinaryV3SeedItem] = []
  items.reserveCapacity(count)
  for index in 0..<count {
    let partition = try fileBlobStoreTestPartition("\(domain)-partition-\(index)")
    let data = Data("\(domain)-payload-\(index)".utf8)
    let digest = BlobDigest.sha256(of: data)
    let publication = try await store!.commit(data: data, digest: digest, partition: partition)
    items.append(
      .init(
        data: data,
        digest: digest,
        partition: partition,
        physicalID: publication.physicalID,
        key: FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
      )
    )
  }
  #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
  let v1Migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
  store = nil
  try await waitForWriterLeaseRelease(root: root)

  let rootURL = root.appendingPathComponent("manifest.json")
  let v1Root = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
  #expect(v1Root == v1Migration.root)
  let transition = try SegmentedManifestBinaryBaseTransitionV3.prepare(
    frozenRoot: v1Root,
    segmentDirectory: v1Migration.segmentDirectory,
    candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
  )
  try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
  _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
    root: transition.root,
    directory: v1Migration.segmentDirectory
  )
  return items
}

struct RealBinaryV3FileBlobStoreFixture {
  let seedData: Data
  let seedDigest: BlobDigest
  let partition: CachePartitionID
  let seedPhysicalID: PhysicalBlobID
}

func makeRealBinaryV3FileBlobStoreFixture(root: URL) async throws -> RealBinaryV3FileBlobStoreFixture {
  var store: FileBlobStore? = try await FileBlobStore.open(root: root)
  let partition = try fileBlobStoreTestPartition("binary-v3-real")
  let seedData = Data("binary-v3-real-seed".utf8)
  let seedDigest = BlobDigest.sha256(of: seedData)
  let seedPublication = try await store!.commit(data: seedData, digest: seedDigest, partition: partition)
  #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
  let v1Migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
  store = nil
  try await waitForWriterLeaseRelease(root: root)

  let rootURL = root.appendingPathComponent("manifest.json")
  let v1Root = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
  #expect(v1Root == v1Migration.root)
  let transition = try SegmentedManifestBinaryBaseTransitionV3.prepare(
    frozenRoot: v1Root,
    segmentDirectory: v1Migration.segmentDirectory,
    candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
  )
  try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
  _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
    root: transition.root,
    directory: v1Migration.segmentDirectory
  )
  return RealBinaryV3FileBlobStoreFixture(
    seedData: seedData,
    seedDigest: seedDigest,
    partition: partition,
    seedPhysicalID: seedPublication.physicalID
  )
}

func binaryBaseV3TestState(count: Int) throws -> [String: SegmentedManifestEntry] {
  var result: [String: SegmentedManifestEntry] = [:]
  result.reserveCapacity(count)
  for index in 0..<count {
    let payload = Data(repeating: UInt8(truncatingIfNeeded: index * 19 + 5), count: index * 11)
    let digest = BlobDigest.sha256(of: payload)
    let partition = try CachePartitionID.derive(
      domain: "segmented-binary-base-v3-test",
      material: Data("partition-\(index)".utf8)
    )
    let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
    result[key] = SegmentedManifestEntry(
      key: key,
      physicalID: PhysicalBlobID(),
      partition: partition,
      digest: digest,
      byteCount: payload.count,
      lastAccess: Date(timeIntervalSinceReferenceDate: 710_000_000 + Double(index))
    )
  }
  return result
}
