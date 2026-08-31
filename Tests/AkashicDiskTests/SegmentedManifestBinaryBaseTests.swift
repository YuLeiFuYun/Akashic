import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk segmented binary base V2")
struct SegmentedManifestBinaryBaseTests {
  @Test("AKASHIC-CT-142 binary base round-trips exact semantic and physical state")
  func binaryBaseRoundTripIsExact() throws {
    let state = try binaryBaseTestState(count: 8)
    let encoded = try SegmentedManifestBinaryBaseV1.encode(state)
    #expect(
      encoded.count
        == SegmentedManifestBinaryBaseV1.headerBytes
          + SegmentedManifestBinaryBaseV1.recordBytes * state.count
    )
    #expect(try SegmentedManifestBinaryBaseV1.decode(encoded) == state)

    var corrupted = encoded
    corrupted[SegmentedManifestBinaryBaseV1.headerBytes] ^= 0x01
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestBinaryBaseV1.decode(corrupted)
    }
  }

  @Test("AKASHIC-CT-143 V1 and V2 roots reject mixed base profiles")
  func rootProfilesRejectMixedBaseKinds() throws {
    let binaryName = "base-binary-\(UUID().uuidString.lowercased()).akb"
    let binary = SegmentedManifestDescriptorV1(
      kind: .baseBinaryV1,
      fileName: binaryName,
      byteCount: try #require(SegmentedManifestBinaryBaseV1.expectedByteCount(recordCount: 0)),
      recordCount: 0,
      sha256: String(repeating: "0", count: 64)
    )
    let json = SegmentedManifestDescriptorV1(
      kind: .baseJSON,
      fileName: "base-test.json",
      byteCount: 1,
      recordCount: 0,
      sha256: String(repeating: "0", count: 64)
    )

    #expect(try SegmentedManifestPrototypeV1.makeRoot(generation: 1, base: json, runs: []).profile
      == SegmentedManifestPrototypeV1.profileV1)
    #expect(try SegmentedManifestPrototypeV1.makeRootV2(generation: 1, base: binary, runs: []).profile
      == SegmentedManifestPrototypeV1.profileV2)
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestPrototypeV1.makeRoot(generation: 1, base: binary, runs: [])
    }
    #expect(throws: AkashicError.invalidManifest) {
      _ = try SegmentedManifestPrototypeV1.makeRootV2(generation: 1, base: json, runs: [])
    }
  }

  @Test("AKASHIC-CT-144 binary base namespace is exact and independently reclaimable")
  func binaryBaseNamespaceAndDebtAreBounded() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let state = try binaryBaseTestState(count: 3)
      let validName = "base-binary-\(UUID().uuidString.lowercased()).akb"
      #expect(
        SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
          validName,
          kind: .baseBinaryV1
        )
      )
      #expect(!SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
        validName.uppercased(),
        kind: .baseBinaryV1
      ))
      #expect(!SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
        "base-binary-not-a-uuid.akb",
        kind: .baseBinaryV1
      ))
      #expect(SegmentedManifestSegmentCleanupV1.isProductionCanonical(validName))

      _ = try SegmentedManifestPrototypeV1.writeBaseBinary(
        state,
        fileName: validName,
        directory: segments
      )
      #expect(FileManager.default.fileExists(atPath: segments.appendingPathComponent(validName).path))
      let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: nil,
        directory: segments
      )
      #expect(cleanup.deletedCount == 1)
      #expect(cleanup.remainingDebtCount == 0)
      #expect(!FileManager.default.fileExists(atPath: segments.appendingPathComponent(validName).path))
    }
  }

  @Test("AKASHIC-CT-145 V2 root recovers binary base without changing PhysicalBlobID")
  func v2RootRecoversBinaryBase() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let state = try binaryBaseTestState(count: 16)
      let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
        state,
        fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
        directory: segments
      )
      let segmentedRoot = try SegmentedManifestPrototypeV1.makeRootV2(
        generation: 1,
        base: base,
        runs: []
      )
      let rootURL = root.appendingPathComponent("manifest.json")
      try SegmentedManifestPrototypeV1.writeRoot(segmentedRoot, to: rootURL)
      let recovered = try SegmentedManifestPrototypeV1.recover(
        rootURL: rootURL,
        segmentDirectory: segments
      )
      #expect(recovered == state)
      #expect(
        Dictionary(uniqueKeysWithValues: recovered.map { ($0.key, $0.value.physicalID) })
          == Dictionary(uniqueKeysWithValues: state.map { ($0.key, $0.value.physicalID) })
      )
    }
  }

  @Test("AKASHIC-CT-146 public FileBlobStore remains V1-only while V2 is research-only")
  func publicStoreRejectsV2ResearchRoot() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      try StorageDirectorySecurity.prepareDirectory(
        root.appendingPathComponent("blobs", isDirectory: true)
      )
      let segments = root.appendingPathComponent(
        FileBlobStore.segmentedManifestPrototypeDirectoryName,
        isDirectory: true
      )
      try StorageDirectorySecurity.prepareDirectory(segments)
      let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
        [:],
        fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
        directory: segments
      )
      let researchRoot = try SegmentedManifestPrototypeV1.makeRootV2(
        generation: 1,
        base: base,
        runs: []
      )
      try SegmentedManifestPrototypeV1.writeRoot(
        researchRoot,
        to: root.appendingPathComponent("manifest.json")
      )
      await expectFileBlobStoreOpenError(.invalidManifest, root: root)
    }
  }

  @Test("AKASHIC-CT-147 V2 binary base replays existing runV1 suffix exactly")
  func v2RootReplaysRunSuffix() async throws {
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
        lastAccess: first.lastAccess.addingTimeInterval(1)
      )
      let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
        state,
        fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
        directory: segments
      )
      let run = try SegmentedManifestPrototypeV1.writeRun(
        [.upsert(replacement)],
        fileName: "run-g2-\(UUID().uuidString.lowercased()).seg",
        directory: segments
      )
      let researchRoot = try SegmentedManifestPrototypeV1.makeRootV2(
        generation: 2,
        base: base,
        runs: [run]
      )
      let rootURL = root.appendingPathComponent("manifest.json")
      try SegmentedManifestPrototypeV1.writeRoot(researchRoot, to: rootURL)
      let recovered = try SegmentedManifestPrototypeV1.recover(
        rootURL: rootURL,
        segmentDirectory: segments
      )
      var expected = state
      expected[first.key] = replacement
      #expect(recovered == expected)
    }
  }

  @Test("AKASHIC-CT-148 V1 to V2 prepare is non-authoritative and preserves generation")
  func v1ToV2PrepareDoesNotPublishAuthority() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try makeBinaryTransitionV1Fixture(root: root)
      let beforeRoot = try Data(contentsOf: fixture.rootURL)
      let candidate = try SegmentedManifestBinaryBaseTransitionV2.prepare(
        frozenRoot: fixture.root,
        segmentDirectory: fixture.segments,
        candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
      )
      let afterPrepareRoot = try Data(contentsOf: fixture.rootURL)
      #expect(afterPrepareRoot == beforeRoot)
      #expect(candidate.frozenRoot == fixture.root)
      #expect(candidate.root.generation == fixture.root.generation)
      #expect(candidate.root.profile == SegmentedManifestPrototypeV1.profileV2)
      #expect(candidate.root.base.kind == .baseBinaryV1)
      #expect(candidate.root.runs.isEmpty)
      let recoveredCandidate = try SegmentedManifestPrototypeV1.recover(
        root: candidate.root,
        segmentDirectory: fixture.segments
      )
      #expect(recoveredCandidate == fixture.expected)
      let expectedCommitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(
        fixture.expected
      )
      #expect(candidate.semanticCommitment == expectedCommitment)
    }
  }

  @Test("AKASHIC-CT-149 V2 root publication retires V1 topology as physical debt only")
  func v2PublicationRetiresOnlyPhysicalTopology() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let fixture = try makeBinaryTransitionV1Fixture(root: root)
      let candidate = try SegmentedManifestBinaryBaseTransitionV2.prepare(
        frozenRoot: fixture.root,
        segmentDirectory: fixture.segments,
        candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
      )
      try SegmentedManifestPrototypeV1.writeRoot(candidate.root, to: fixture.rootURL)
      let published = try SegmentedManifestPrototypeV1.readRoot(from: fixture.rootURL)
      #expect(published == candidate.root)
      #expect(published.generation == fixture.root.generation)
      let recovered = try SegmentedManifestPrototypeV1.recover(
        root: published,
        segmentDirectory: fixture.segments
      )
      #expect(recovered == fixture.expected)
      let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: published,
        directory: fixture.segments
      )
      #expect(cleanup.deletedCount == 2)
      #expect(cleanup.remainingDebtCount == 0)
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.segments.appendingPathComponent(candidate.base.fileName).path
        )
      )
      #expect(
        try SegmentedManifestPrototypeV1.recover(
          rootURL: fixture.rootURL,
          segmentDirectory: fixture.segments
        ) == fixture.expected
      )
    }
  }

  @Test("AKASHIC-CT-150 V1 to V2 root faults converge on one complete topology")
  func v1ToV2RootFaultsNeverProduceMixedAuthority() async throws {
    for faultPoint in DurableFileWriteSwitchPoint.allCases {
      try await withManifestTestTemporaryDirectory { root in
        let fixture = try makeBinaryTransitionV1Fixture(root: root)
        let candidate = try SegmentedManifestBinaryBaseTransitionV2.prepare(
          frozenRoot: fixture.root,
          segmentDirectory: fixture.segments,
          candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
        )
        do {
          try SegmentedManifestPrototypeV1.writeRoot(
            candidate.root,
            to: fixture.rootURL,
            faultInjector: { observed in
              if observed == faultPoint { throw BinaryTransitionInjectedFault() }
            }
          )
          Issue.record("Expected injected root-write failure at \(faultPoint.rawValue)")
        } catch is BinaryTransitionInjectedFault {
          // Expected. Authority must now be inferred from the bytes on disk, not local intent.
        }

        let onDisk = try SegmentedManifestPrototypeV1.readRoot(from: fixture.rootURL)
        let recovered = try SegmentedManifestPrototypeV1.recover(
          root: onDisk,
          segmentDirectory: fixture.segments
        )
        #expect(recovered == fixture.expected)
        #expect(onDisk.generation == fixture.root.generation)

        switch faultPoint {
        case .afterDataWritten, .afterFileSynced:
          #expect(onDisk == fixture.root)
          #expect(onDisk.profile == SegmentedManifestPrototypeV1.profileV1)
          let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: onDisk,
            directory: fixture.segments
          )
          #expect(cleanup.deletedCount == 1)
          #expect(cleanup.remainingDebtCount == 0)
          #expect(
            !FileManager.default.fileExists(
              atPath: fixture.segments.appendingPathComponent(candidate.base.fileName).path
            )
          )
        case .afterRename, .afterDirectorySynced:
          #expect(onDisk == candidate.root)
          #expect(onDisk.profile == SegmentedManifestPrototypeV1.profileV2)
          let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: onDisk,
            directory: fixture.segments
          )
          #expect(cleanup.deletedCount == 2)
          #expect(cleanup.remainingDebtCount == 0)
          #expect(
            FileManager.default.fileExists(
              atPath: fixture.segments.appendingPathComponent(candidate.base.fileName).path
            )
          )
        }
      }
    }
  }
}


struct BinaryTransitionInjectedFault: Error {}

struct BinaryTransitionV1Fixture {
  let root: SegmentedManifestRootV1
  let rootURL: URL
  let segments: URL
  let expected: [String: SegmentedManifestEntry]
}

func makeBinaryTransitionV1Fixture(root: URL) throws -> BinaryTransitionV1Fixture {
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
    lastAccess: first.lastAccess.addingTimeInterval(2)
  )
  let json = try SegmentedManifestPrototypeV1.encodeCompactionBaseSnapshot(
    generation: 7,
    state: state
  )
  let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
    json,
    entryCount: state.count,
    fileName: "base-compaction-\(UUID().uuidString.lowercased()).json",
    directory: segments
  )
  let run = try SegmentedManifestPrototypeV1.writeRun(
    [.upsert(replacement)],
    fileName: "run-g7-\(UUID().uuidString.lowercased()).seg",
    directory: segments
  )
  let segmentedRoot = try SegmentedManifestPrototypeV1.makeRoot(
    generation: 7,
    base: base,
    runs: [run]
  )
  let rootURL = root.appendingPathComponent("manifest.json")
  try SegmentedManifestPrototypeV1.writeRoot(segmentedRoot, to: rootURL)
  var expected = state
  expected[first.key] = replacement
  return BinaryTransitionV1Fixture(
    root: segmentedRoot,
    rootURL: rootURL,
    segments: segments,
    expected: expected
  )
}

struct RealBinaryV2FileBlobStoreFixture {
  let seedData: Data
  let seedDigest: BlobDigest
  let partition: CachePartitionID
  let seedPhysicalID: PhysicalBlobID
}

func makeRealBinaryV2FileBlobStoreFixture(
  root: URL
) async throws -> RealBinaryV2FileBlobStoreFixture {
  var store: FileBlobStore? = try await FileBlobStore.open(root: root)
  let partition = try fileBlobStoreTestPartition("binary-v2-real")
  let seedData = Data("binary-v2-real-seed".utf8)
  let seedDigest = BlobDigest.sha256(of: seedData)
  let seedPublication = try await store!.commit(
    data: seedData,
    digest: seedDigest,
    partition: partition
  )
  #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
  let v1Migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
  store = nil
  try await waitForWriterLeaseRelease(root: root)

  let rootURL = root.appendingPathComponent("manifest.json")
  let v1Root = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
  #expect(v1Root == v1Migration.root)
  #expect(v1Root.profile == SegmentedManifestPrototypeV1.profileV1)
  let transition = try SegmentedManifestBinaryBaseTransitionV2.prepare(
    frozenRoot: v1Root,
    segmentDirectory: v1Migration.segmentDirectory,
    candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
  )
  try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
  _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
    root: transition.root,
    directory: v1Migration.segmentDirectory
  )
  return RealBinaryV2FileBlobStoreFixture(
    seedData: seedData,
    seedDigest: seedDigest,
    partition: partition,
    seedPhysicalID: seedPublication.physicalID
  )
}

func binaryBaseTestState(count: Int) throws -> [String: SegmentedManifestEntry] {
  var result: [String: SegmentedManifestEntry] = [:]
  result.reserveCapacity(count)
  for index in 0..<count {
    let payload = Data(repeating: UInt8(truncatingIfNeeded: index * 17 + 3), count: index * 7)
    let digest = BlobDigest.sha256(of: payload)
    let partition = try CachePartitionID.derive(
      domain: "segmented-binary-base-test",
      material: Data("partition-\(index)".utf8)
    )
    let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
    result[key] = SegmentedManifestEntry(
      key: key,
      physicalID: PhysicalBlobID(),
      partition: partition,
      digest: digest,
      byteCount: payload.count,
      lastAccess: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index))
    )
  }
  return result
}
