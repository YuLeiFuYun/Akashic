import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

extension SegmentedManifestBinaryBaseV3Tests {
  @Test("AKASHIC-CT-179 V4 480 plus 32 preseal checkpoints through one compound descriptor")
  func v4CompoundPresealRealCheckpoint() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let seeds = try await makeRealBinaryV3SeedSet(
        root: root,
        count: 512,
        domain: "compound-v4-real"
      )
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      let oldRoot = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      let migrated = try await store!.resourceProbeMigrateSegmentedV3ToCompoundV4()
      #expect(migrated.profile == SegmentedManifestPrototypeV1.profileV4)
      #expect(migrated.generation == oldRoot.generation)
      #expect(migrated.base == oldRoot.base)
      #expect(migrated.runs == oldRoot.runs)

      for (index, seed) in seeds.prefix(480).enumerated() {
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 900_000_000 + Double(index))
        )
      }
      let prepared = try await store!.resourceProbePrepareSegmentedCompoundPresealV4()
      #expect(prepared.sourceDistinctKeyCount == 480)
      let segments = root.appendingPathComponent(
        FileBlobStore.segmentedManifestPrototypeDirectoryName,
        isDirectory: true
      )
      let draftURL = segments.appendingPathComponent(prepared.candidateFileName)
      #expect(FileManager.default.fileExists(atPath: draftURL.path))

      for index in 480..<511 {
        let seed = seeds[index]
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 900_001_000 + Double(index))
        )
      }
      let boundary = seeds[511]
      try await store!.resourceProbeRepublishEntry(
        digest: boundary.digest,
        partition: boundary.partition,
        lastAccess: Date(timeIntervalSinceReferenceDate: 900_002_000)
      )

      let finalRoot = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      #expect(finalRoot.profile == SegmentedManifestPrototypeV1.profileV4)
      #expect(finalRoot.generation == oldRoot.generation + 1)
      #expect(finalRoot.runs.count == 1)
      #expect(finalRoot.runs[0].kind == .compoundRunV1)
      #expect(finalRoot.runs[0].recordCount == 512)
      #expect(finalRoot.runs[0].fileName == prepared.candidateFileName)
      #expect(finalRoot.runs[0].byteCount == 69_824)
      let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
      #expect(head.distinctKeyCount == 0)
      let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
      for seed in seeds {
        #expect(beforeReopen.entries[seed.key]?.physicalID == seed.physicalID)
      }
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      do {
        _ = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        Issue.record("V3 qualification open accepted a V4 compound root")
      } catch let error as AkashicError {
        #expect(error == .invalidManifest)
      }
      store = try await FileBlobStore.openSegmentedV4Candidate(root: root)
      #expect(await store!.resourceProbeManifestShadowSnapshot() == beforeReopen)
      #expect(try await store!.read(digest: seeds[0].digest, partition: seeds[0].partition) == seeds[0].data)
      #expect(try await store!.read(digest: boundary.digest, partition: boundary.partition) == boundary.data)

      let names = try BoundedDirectoryReader.names(
        in: segments,
        maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
      ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
      let referenced = Set([finalRoot.base.fileName] + finalRoot.runs.map(\.fileName))
      #expect(Set(names) == referenced)
    }
  }

  @Test("AKASHIC-CT-180 V4 compound tail gate falls back and reclaims high-churn draft")
  func v4CompoundPresealTailGateFallback() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let seeds = try await makeRealBinaryV3SeedSet(
        root: root,
        count: 512,
        domain: "compound-v4-tail-gate"
      )
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      _ = try await store!.resourceProbeMigrateSegmentedV3ToCompoundV4()
      for (index, seed) in seeds.prefix(480).enumerated() {
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 910_000_000 + Double(index))
        )
      }
      let prepared = try await store!.resourceProbePrepareSegmentedCompoundPresealV4()
      let segments = root.appendingPathComponent(
        FileBlobStore.segmentedManifestPrototypeDirectoryName,
        isDirectory: true
      )
      let draftURL = segments.appendingPathComponent(prepared.candidateFileName)

      // 97 changed prefix keys + 31 new keys are already in the post-prefix tail. The boundary
      // transition is the 129th tail key, just beyond the resource gate.
      for index in 0..<97 {
        let seed = seeds[index]
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 911_000_000 + Double(index))
        )
      }
      for index in 480..<511 {
        let seed = seeds[index]
        try await store!.resourceProbeRepublishEntry(
          digest: seed.digest,
          partition: seed.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 912_000_000 + Double(index))
        )
      }
      let boundary = seeds[511]
      try await store!.resourceProbeRepublishEntry(
        digest: boundary.digest,
        partition: boundary.partition,
        lastAccess: Date(timeIntervalSinceReferenceDate: 913_000_000)
      )

      let finalRoot = try SegmentedManifestPrototypeV1.readRoot(
        from: root.appendingPathComponent("manifest.json")
      )
      #expect(finalRoot.profile == SegmentedManifestPrototypeV1.profileV4)
      #expect(finalRoot.runs.count == 1)
      #expect(finalRoot.runs[0].kind == .runV1)
      #expect(finalRoot.runs[0].recordCount == 512)
      #expect(finalRoot.runs[0].byteCount == 69_696)
      #expect(!FileManager.default.fileExists(atPath: draftURL.path))
      let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV4Candidate(root: root)
      #expect(await store!.resourceProbeManifestShadowSnapshot() == beforeReopen)
      #expect(try await store!.read(digest: boundary.digest, partition: boundary.partition) == boundary.data)
    }
  }

  @Test("AKASHIC-CT-181 V4 mixed compound history collapses at 64-run hard cap and preserves progress")
  func v4MixedRunHardCapCollapseProgress() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let seeds = try await makeRealBinaryV3SeedSet(
        root: root,
        count: 512,
        domain: "compound-v4-hardcap"
      )
      var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
      _ = try await store!.resourceProbeMigrateSegmentedV3ToCompoundV4()
      let baseline = await store!.resourceProbeManifestShadowSnapshot()
      store = nil
      try await waitForWriterLeaseRelease(root: root)

      let rootURL = root.appendingPathComponent("manifest.json")
      let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(initialRoot.profile == SegmentedManifestPrototypeV1.profileV4)
      #expect(initialRoot.runs.isEmpty)
      let segments = root.appendingPathComponent(
        FileBlobStore.segmentedManifestPrototypeDirectoryName,
        isDirectory: true
      )
      let seed = seeds[0]
      var descriptors: [SegmentedManifestDescriptorV1] = []
      descriptors.reserveCapacity(SegmentedManifestPrototypeV1.maximumRunDescriptors)
      for index in 0..<SegmentedManifestPrototypeV1.maximumRunDescriptors {
        let finalEntry = SegmentedManifestEntry(
          key: seed.key,
          physicalID: seed.physicalID,
          partition: seed.partition,
          digest: seed.digest,
          byteCount: seed.data.count,
          lastAccess: Date(timeIntervalSinceReferenceDate: 930_000_000 + Double(index * 2 + 1))
        )
        if index.isMultiple(of: 2) {
          descriptors.append(
            try SegmentedManifestPrototypeV1.writeRun(
              [.upsert(finalEntry)],
              fileName: "run-g\(initialRoot.generation)-\(UUID().uuidString.lowercased()).seg",
              directory: segments
            )
          )
        } else {
          let prefixEntry = SegmentedManifestEntry(
            key: seed.key,
            physicalID: seed.physicalID,
            partition: seed.partition,
            digest: seed.digest,
            byteCount: seed.data.count,
            lastAccess: finalEntry.lastAccess.addingTimeInterval(-1)
          )
          let data = try SegmentedManifestCompoundRunV1.encodeFinalized(
            prefix: [.upsert(prefixEntry)],
            tail: [.upsert(finalEntry)]
          )
          let name = "compound-hardcap-\(UUID().uuidString.lowercased()).cseg"
          try DurableFileWriter.writeReplacing(
            data,
            to: segments.appendingPathComponent(name, isDirectory: false)
          )
          descriptors.append(
            try SegmentedManifestCompoundRunV1.finalizedDescriptor(
              fileName: name,
              data: data
            )
          )
        }
      }
      #expect(descriptors.count == 64)
      #expect(descriptors.filter { $0.kind == .compoundRunV1 }.count == 32)
      let hardRoot = try SegmentedManifestPrototypeV1.makeRootV4(
        generation: initialRoot.generation,
        base: initialRoot.base,
        runs: descriptors
      )
      do {
        let manualRecovered = try SegmentedManifestPrototypeV1.recover(
          root: hardRoot,
          segmentDirectory: segments
        )
        #expect(manualRecovered.count == 512)
        #expect(manualRecovered[seed.key]?.physicalID == seed.physicalID)
      } catch {
        Issue.record("V4 mixed 64-run manual replay failed before FileBlobStore bootstrap: \(error)")
        throw error
      }
      try SegmentedManifestPrototypeV1.writeRoot(hardRoot, to: rootURL)

      do {
        store = try await FileBlobStore.openSegmentedV4Candidate(
          root: root,
          runCapacityPolicy: .synchronousV4RunCollapseThenCompactionAtHardLimit
        )
      } catch {
        Issue.record("V4 mixed 64-run FileBlobStore bootstrap failed after manual replay: \(error)")
        throw error
      }
      let recovered = await store!.resourceProbeManifestShadowSnapshot()
      #expect(recovered.entries.count == baseline.entries.count)
      for seed in seeds {
        #expect(recovered.entries[seed.key]?.physicalID == seed.physicalID)
      }

      for index in 0..<511 {
        let item = seeds[index]
        try await store!.resourceProbeRepublishEntry(
          digest: item.digest,
          partition: item.partition,
          lastAccess: Date(timeIntervalSinceReferenceDate: 931_000_000 + Double(index))
        )
      }
      let boundary = seeds[511]
      try await store!.resourceProbeRepublishEntry(
        digest: boundary.digest,
        partition: boundary.partition,
        lastAccess: Date(timeIntervalSinceReferenceDate: 932_000_000)
      )

      let progressedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
      #expect(progressedRoot.profile == SegmentedManifestPrototypeV1.profileV4)
      #expect(progressedRoot.generation == initialRoot.generation + 1)
      #expect(progressedRoot.runs.count == 3)
      #expect(progressedRoot.runs.allSatisfy { $0.kind == .runV1 })
      let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
      #expect(head.distinctKeyCount == 0)
      let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
      #expect(beforeReopen.entries.count == 512)
      for seed in seeds {
        #expect(beforeReopen.entries[seed.key]?.physicalID == seed.physicalID)
      }
      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.openSegmentedV4Candidate(
        root: root,
        runCapacityPolicy: .synchronousV4RunCollapseThenCompactionAtHardLimit
      )
      #expect(await store!.resourceProbeManifestShadowSnapshot() == beforeReopen)
      #expect(try await store!.read(digest: boundary.digest, partition: boundary.partition) == boundary.data)

      let names = try BoundedDirectoryReader.names(
        in: segments,
        maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
      ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
      let referenced = Set([progressedRoot.base.fileName] + progressedRoot.runs.map(\.fileName))
      #expect(Set(names) == referenced)
    }
  }
}
