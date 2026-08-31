import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk segmented binary base V2 faults")
struct SegmentedManifestBinaryBaseFaultTests {
  @Test("AKASHIC-CT-156 V2 FileBlobStore checkpoint faults converge at root rename")
  func v2CheckpointFaultsConvergeOnFreshOpen() async throws {
    let points: [FileBlobStoreSwitchPoint] = [
      .afterManifestDataWritten,
      .afterManifestFileSynced,
      .afterManifestRenamed,
      .afterManifestDirectorySynced,
    ]
    for point in points {
      try await withManifestTestTemporaryDirectory { root in
        let fixture = try await makeBinaryV2FaultFixture(root: root)
        let gate = BinaryV2CheckpointFaultGate(target: point)
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV2Candidate(
          root: root,
          faultInjector: { observed in try gate.inject(observed) }
        )

        var firstData = Data()
        var firstDigest = BlobDigest.sha256(of: Data())
        var lastPreData = Data()
        var lastPreDigest = BlobDigest.sha256(of: Data())
        for index in 0..<(FileBlobStore.manifestCheckpointRecordLimit - 1) {
          let data = Data("v2-fault-\(point.rawValue)-pre-\(index)".utf8)
          let digest = BlobDigest.sha256(of: data)
          _ = try await store!.commit(
            data: data,
            digest: digest,
            partition: fixture.partition
          )
          if index == 0 {
            firstData = data
            firstDigest = digest
          }
          lastPreData = data
          lastPreDigest = digest
        }
        let rootURL = root.appendingPathComponent("manifest.json")
        let beforeRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        #expect(beforeRoot.profile == SegmentedManifestPrototypeV1.profileV2)
        #expect(beforeRoot.runs.isEmpty)

        let targetData = Data("v2-fault-\(point.rawValue)-target".utf8)
        let targetDigest = BlobDigest.sha256(of: targetData)
        gate.arm()
        do {
          _ = try await store!.commit(
            data: targetData,
            digest: targetDigest,
            partition: fixture.partition
          )
          Issue.record("Expected checkpoint fault at \(point.rawValue)")
        } catch is BinaryV2CheckpointInjectedFault {
          // Expected. Fresh bootstrap below is the authority oracle.
        }

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        store = try await FileBlobStore.openSegmentedV2Candidate(root: root)
        let afterRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        #expect(afterRoot.profile == SegmentedManifestPrototypeV1.profileV2)
        #expect(afterRoot.base.kind == .baseBinaryV1)
        #expect(try await store!.read(digest: firstDigest, partition: fixture.partition) == firstData)
        #expect(
          try await store!.read(digest: lastPreDigest, partition: fixture.partition)
            == lastPreData
        )

        switch point {
        case .afterManifestDataWritten, .afterManifestFileSynced:
          #expect(afterRoot == beforeRoot)
          await expectFileBlobStoreTestAkashicError(.notFound) {
            _ = try await store!.read(digest: targetDigest, partition: fixture.partition)
          }
        case .afterManifestRenamed, .afterManifestDirectorySynced:
          #expect(afterRoot.generation == beforeRoot.generation + 1)
          #expect(afterRoot.runs.count == 1)
          #expect(
            try await store!.read(digest: targetDigest, partition: fixture.partition)
              == targetData
          )
        default:
          Issue.record("Unexpected checkpoint test point")
        }

        let segmentDirectory = root.appendingPathComponent(
          FileBlobStore.segmentedManifestPrototypeDirectoryName,
          isDirectory: true
        )
        let productionNames = Set(
          try FileManager.default.contentsOfDirectory(atPath: segmentDirectory.path)
            .filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        )
        let referencedNames = Set([afterRoot.base.fileName] + afterRoot.runs.map(\.fileName))
        #expect(productionNames == referencedNames)
      }
    }
  }

  @Test("AKASHIC-CT-157 V2 compaction faults preserve logical authority across root rename")
  func v2CompactionFaultsPreserveAuthority() async throws {
    let points: [FileBlobStoreSwitchPoint] = [
      .afterManifestDataWritten,
      .afterManifestFileSynced,
      .afterManifestRenamed,
      .afterManifestDirectorySynced,
    ]
    for point in points {
      try await withManifestTestTemporaryDirectory { root in
        let fixture = try await makeBinaryV2FaultFixture(root: root)
        let gate = BinaryV2CheckpointFaultGate(target: point)
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV2Candidate(
          root: root,
          faultInjector: { observed in try gate.inject(observed) }
        )
        var lastData = Data()
        var lastDigest = BlobDigest.sha256(of: Data())
        for index in 0..<FileBlobStore.manifestCheckpointRecordLimit {
          let data = Data("v2-compaction-fault-\(point.rawValue)-\(index)".utf8)
          let digest = BlobDigest.sha256(of: data)
          _ = try await store!.commit(
            data: data,
            digest: digest,
            partition: fixture.partition
          )
          lastData = data
          lastDigest = digest
        }
        let rootURL = root.appendingPathComponent("manifest.json")
        let beforeRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        #expect(beforeRoot.profile == SegmentedManifestPrototypeV1.profileV2)
        #expect(beforeRoot.runs.count == 1)

        gate.arm()
        do {
          _ = try await store!.resourceProbeCompactSegmentedManifestV2()
          Issue.record("Expected V2 compaction root fault at \(point.rawValue)")
        } catch is BinaryV2CheckpointInjectedFault {
          // Expected. Root bytes decide whether old or compacted physical topology won.
        }

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        store = try await FileBlobStore.openSegmentedV2Candidate(root: root)
        let afterRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        #expect(afterRoot.profile == SegmentedManifestPrototypeV1.profileV2)
        #expect(afterRoot.base.kind == .baseBinaryV1)
        #expect(afterRoot.generation == beforeRoot.generation)
        #expect(
          try await store!.read(digest: fixture.seedDigest, partition: fixture.partition)
            == fixture.seedData
        )
        #expect(
          await store!.physicalID(digest: fixture.seedDigest, partition: fixture.partition)
            == fixture.seedPhysicalID
        )
        #expect(try await store!.read(digest: lastDigest, partition: fixture.partition) == lastData)

        switch point {
        case .afterManifestDataWritten, .afterManifestFileSynced:
          #expect(afterRoot == beforeRoot)
        case .afterManifestRenamed, .afterManifestDirectorySynced:
          #expect(afterRoot.base != beforeRoot.base)
          #expect(afterRoot.runs.isEmpty)
        default:
          Issue.record("Unexpected compaction test point")
        }

        let segmentDirectory = root.appendingPathComponent(
          FileBlobStore.segmentedManifestPrototypeDirectoryName,
          isDirectory: true
        )
        let productionNames = Set(
          try FileManager.default.contentsOfDirectory(atPath: segmentDirectory.path)
            .filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        )
        let referencedNames = Set([afterRoot.base.fileName] + afterRoot.runs.map(\.fileName))
        #expect(productionNames == referencedNames)
      }
    }
  }
}

private struct BinaryV2CheckpointInjectedFault: Error {}

private final class BinaryV2CheckpointFaultGate: @unchecked Sendable {
  private let lock = NSLock()
  private let target: FileBlobStoreSwitchPoint
  private var isArmed = false

  init(target: FileBlobStoreSwitchPoint) {
    self.target = target
  }

  func arm() {
    lock.lock()
    isArmed = true
    lock.unlock()
  }

  func inject(_ point: FileBlobStoreSwitchPoint) throws {
    lock.lock()
    let shouldThrow = isArmed && point == target
    if shouldThrow { isArmed = false }
    lock.unlock()
    if shouldThrow { throw BinaryV2CheckpointInjectedFault() }
  }
}

private struct BinaryV2FaultFixture {
  let partition: CachePartitionID
  let seedData: Data
  let seedDigest: BlobDigest
  let seedPhysicalID: PhysicalBlobID
}

private func makeBinaryV2FaultFixture(root: URL) async throws -> BinaryV2FaultFixture {
  var store: FileBlobStore? = try await FileBlobStore.open(root: root)
  let partition = try fileBlobStoreTestPartition("binary-v2-fault")
  let seedData = Data("binary-v2-fault-seed".utf8)
  let seedDigest = BlobDigest.sha256(of: seedData)
  let seedPublication = try await store!.commit(
    data: seedData,
    digest: seedDigest,
    partition: partition
  )
  guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
    throw AkashicError.invalidManifest
  }
  let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
  store = nil
  try await waitForWriterLeaseRelease(root: root)

  let rootURL = root.appendingPathComponent("manifest.json")
  let v1Root = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
  guard v1Root == migration.root,
    v1Root.profile == SegmentedManifestPrototypeV1.profileV1
  else { throw AkashicError.invalidManifest }
  let transition = try SegmentedManifestBinaryBaseTransitionV2.prepare(
    frozenRoot: v1Root,
    segmentDirectory: migration.segmentDirectory,
    candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
  )
  try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
  _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
    root: transition.root,
    directory: migration.segmentDirectory
  )
  return BinaryV2FaultFixture(
    partition: partition,
    seedData: seedData,
    seedDigest: seedDigest,
    seedPhysicalID: seedPublication.physicalID
  )
}
