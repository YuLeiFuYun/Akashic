import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk directory-head manifest protocol")
struct FileBlobStoreDirectoryHeadTests {
  @Test("AKASHIC-CT-088 directory-head Base32 record identity is canonical and bounded")
  func recordIdentityRoundTrip() throws {
    let identity = try makeIdentity(label: "record-name")
    let recordIdentity = try FileBlobStore.DirectoryHeadRecordIdentity.make(
      generation: 0x1234,
      sequence: 0x5678,
      key: identity.key
    )
    #expect(recordIdentity.name.utf8.count == 104)
    #expect(try FileBlobStore.DirectoryHeadRecordIdentity.parse(recordIdentity.name) == recordIdentity)

    let malformed = recordIdentity.name.dropLast() + "!"
    #expect(throws: AkashicError.invalidManifest) {
      _ = try FileBlobStore.DirectoryHeadRecordIdentity.parse(String(malformed))
    }
  }

  @Test("AKASHIC-CT-089 both checksummed directory heads are mandatory")
  func mandatoryDualHeadsRejectDeletionAndCorruption() throws {
    let memory = DirectoryHeadMemoryAttributes()
    try initializeHeads(memory: memory, generation: 7)

    let state = try FileBlobStore.loadDirectoryHeadState(
      directory: memory.url,
      generation: 7,
      operations: memory.operations
    )
    #expect(state.activeHead.s == 0)
    #expect(state.latest.isEmpty)

    let head1 = FileBlobStore.DirectoryHeadIdentity(generation: 7, slot: 1).name
    let saved = try memory.read(head1)
    memory.remove(head1)
    #expect(throws: AkashicError.invalidManifest) {
      _ = try FileBlobStore.loadDirectoryHeadState(
        directory: memory.url,
        generation: 7,
        operations: memory.operations
      )
    }
    memory.set(head1, saved)

    let head0 = FileBlobStore.DirectoryHeadIdentity(generation: 7, slot: 0).name
    let head0Data = try memory.read(head0)
    var object = try #require(
      JSONSerialization.jsonObject(with: head0Data) as? [String: Any]
    )
    object["c"] = 1
    memory.set(head0, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    #expect(throws: AkashicError.invalidManifest) {
      _ = try FileBlobStore.loadDirectoryHeadState(
        directory: memory.url,
        generation: 7,
        operations: memory.operations
      )
    }
  }

  @Test("AKASHIC-CT-090 recovery decodes only latest committed bodies")
  func staleAndUncommittedBodiesAreSkipped() throws {
    let memory = DirectoryHeadMemoryAttributes()
    let generation: UInt64 = 11
    try initializeHeads(memory: memory, generation: generation)
    let identityA = try makeIdentity(label: "latest-a")
    let identityB = try makeIdentity(label: "uncommitted-b")

    let first = try encodedRecord(
      generation: generation,
      sequence: 1,
      identity: identityA,
      physicalID: PhysicalBlobID()
    )
    let firstName = try FileBlobStore.DirectoryHeadRecordIdentity.make(
      generation: generation,
      sequence: 1,
      key: identityA.key
    )
    memory.set(firstName.name, first.data)
    let firstRoot = try FileBlobStore.directoryHeadLeaf(
      identity: firstName,
      recordData: first.data
    )
    try setHead(
      memory: memory,
      try FileBlobStore.makeDirectoryHead(
        generation: generation,
        slot: 1,
        sequence: 1,
        count: 1,
        root: firstRoot
      )
    )

    let second = try encodedRecord(
      generation: generation,
      sequence: 2,
      identity: identityA,
      physicalID: PhysicalBlobID()
    )
    let secondName = try FileBlobStore.DirectoryHeadRecordIdentity.make(
      generation: generation,
      sequence: 2,
      key: identityA.key
    )
    memory.set(secondName.name, second.data)
    let secondRoot = try FileBlobStore.directoryHeadLeaf(
      identity: secondName,
      recordData: second.data
    )
    try setHead(
      memory: memory,
      try FileBlobStore.makeDirectoryHead(
        generation: generation,
        slot: 0,
        sequence: 2,
        count: 1,
        root: secondRoot
      )
    )

    let uncommittedName = try FileBlobStore.DirectoryHeadRecordIdentity.make(
      generation: generation,
      sequence: 3,
      key: identityB.key
    )
    memory.set(uncommittedName.name, Data("corrupt-uncommitted".utf8))
    memory.set(firstName.name, Data("corrupt-stale".utf8))
    memory.clearReadLog()

    let state = try FileBlobStore.loadDirectoryHeadState(
      directory: memory.url,
      generation: generation,
      operations: memory.operations
    )
    #expect(state.activeHead.s == 2)
    #expect(state.latest[identityA.key]?.identity == secondName)
    #expect(state.uncommittedRecordNames == [uncommittedName.name])
    #expect(state.staleCommittedRecordNames == [firstName.name])
    #expect(memory.readLog().contains(secondName.name))
    #expect(!memory.readLog().contains(firstName.name))
    #expect(!memory.readLog().contains(uncommittedName.name))

    memory.remove(secondName.name)
    #expect(throws: AkashicError.invalidManifest) {
      _ = try FileBlobStore.loadDirectoryHeadState(
        directory: memory.url,
        generation: generation,
        operations: memory.operations
      )
    }
  }

  @Test("AKASHIC-CT-092 schema4 manifest persists the directory-head carrier profile")
  func schema4ManifestRoundTripPersistsProfile() throws {
    let identity = try makeIdentity(label: "schema4-round-trip")
    let entry = FileBlobStore.Entry(
      physicalID: PhysicalBlobID(),
      partition: identity.partition,
      digest: identity.digest,
      byteCount: identity.byteCount,
      lastAccess: Date(timeIntervalSinceReferenceDate: 42)
    )
    let manifest = FileBlobStore.Manifest(
      schemaVersion: FileBlobStore.directoryHeadManifestSchemaVersion,
      generation: 9,
      deltaCarrierProfile: .directoryHeadV2,
      entries: [identity.key: entry]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((object["schemaVersion"] as? NSNumber)?.uint16Value == 4)
    #expect(object["d"] as? String == FileBlobStore.DeltaCarrierProfile.directoryHeadV2.rawValue)
    #expect(object["entries"] == nil)
    #expect(object["e"] != nil)
    let sealText = try #require(object["x"] as? String)
    #expect(Data(base64Encoded: sealText)?.count == 32)

    let decoded = try JSONDecoder().decode(FileBlobStore.Manifest.self, from: data)
    #expect(decoded.schemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion)
    #expect(decoded.generation == 9)
    #expect(decoded.deltaCarrierProfile == .directoryHeadV2)
    #expect(decoded.entries == manifest.entries)
  }

  @Test("AKASHIC-CT-093 schema4 missing or future carrier profile fails closed")
  func schema4CarrierProfileIsMandatoryAndClosed() throws {
    let empty = FileBlobStore.Manifest(
      schemaVersion: FileBlobStore.directoryHeadManifestSchemaVersion,
      generation: 3,
      deltaCarrierProfile: .directoryHeadV2,
      entries: [:]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(empty)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    object.removeValue(forKey: "d")
    let missing = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    do {
      _ = try JSONDecoder().decode(FileBlobStore.Manifest.self, from: missing)
      Issue.record("schema4 manifest without a carrier profile was accepted")
    } catch {}

    object["d"] = "future-carrier-v99"
    let future = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    do {
      _ = try JSONDecoder().decode(FileBlobStore.Manifest.self, from: future)
      Issue.record("schema4 manifest with an unknown carrier profile was accepted")
    } catch {}

    object["d"] = "directory-head-v1"
    let v1Data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    do {
      _ = try JSONDecoder().decode(FileBlobStore.Manifest.self, from: v1Data)
      Issue.record("schema4 manifest with directory-head-v1 was accepted")
    } catch {}
  }

  @Test("AKASHIC-CT-132 schema4 snapshot checksum rejects a modified compact entry")
  func schema4SnapshotChecksumRejectsModifiedCompactEntry() throws {
    let identity = try makeIdentity(label: "schema4-snapshot-checksum")
    let entry = FileBlobStore.Entry(
      physicalID: PhysicalBlobID(),
      partition: identity.partition,
      digest: identity.digest,
      byteCount: identity.byteCount,
      lastAccess: Date(timeIntervalSinceReferenceDate: 84)
    )
    let manifest = FileBlobStore.Manifest(
      schemaVersion: FileBlobStore.directoryHeadManifestSchemaVersion,
      generation: 17,
      deltaCarrierProfile: .directoryHeadV2,
      entries: [identity.key: entry]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any]
    )
    var compact = try #require(object["e"] as? [[String: Any]])
    var first = try #require(compact.first)
    let originalCount = try #require(first["n"] as? NSNumber)
    first["n"] = NSNumber(value: originalCount.uint64Value + 1)
    compact[0] = first
    object["e"] = compact
    let modified = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    do {
      _ = try JSONDecoder().decode(FileBlobStore.Manifest.self, from: modified)
      Issue.record("schema4 manifest with a modified compact entry was accepted")
    } catch {}
  }

  @Test("AKASHIC-CT-094 schema3 final state migrates to schema4 with two empty heads")
  func legacyMigrationPublishesSchema4ThenInitializesHeads() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let data = Data("schema4-migration-success".utf8)
      let digest = BlobDigest.sha256(of: data)
      let partition = try manifestTestPartition("schema4-migration-success")
      _ = try await store.commit(data: data, digest: digest, partition: partition)

      #expect(try await store.migrateLegacyManifestToDirectoryHeadSchema4())
      let manifest = await store.manifest
      #expect(manifest.schemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion)
      #expect(manifest.deltaCarrierProfile == .directoryHeadV2)
      #expect(manifest.entries.count == 1)
      let state = try #require(await store.directoryHeadState)
      #expect(state.activeHead.s == 0)
      #expect(state.latest.isEmpty)
      #expect(memory.attributeNames().filter { $0.hasPrefix("dev.akashic.mh1.") }.count == 2)
      #expect(!memory.attributeNames().contains("dev.akashic.capability.directory-head-v2"))
    }
  }

  @Test("AKASHIC-CT-095 unsupported directory xattrs do not emit schema4")
  func unsupportedCarrierLeavesSchema3Unchanged() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      memory.failSet(
        name: "dev.akashic.capability.directory-head-v2",
        code: .ENOTSUP
      )
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let before = await store.manifest
      #expect(!(try await store.migrateLegacyManifestToDirectoryHeadSchema4()))
      let after = await store.manifest
      #expect(after.schemaVersion == before.schemaVersion)
      #expect(after.generation == before.generation)
      #expect(after.deltaCarrierProfile == nil)
      #expect(await store.directoryHeadState == nil)
    }
  }

  @Test("AKASHIC-CT-096 head initialization failure after schema4 snapshot poisons writer")
  func partialHeadInitializationRequiresReopen() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      let nextGeneration = (await store.manifest.generation) + 1
      let head1 = FileBlobStore.DirectoryHeadIdentity(
        generation: nextGeneration,
        slot: 1
      ).name
      memory.failSet(name: head1, code: .EIO)

      await expectManifestTestAkashicError(.storageUnavailable) {
        do {
          _ = try await store.migrateLegacyManifestToDirectoryHeadSchema4()
        } catch is POSIXError {
          throw AkashicError.storageUnavailable
        }
      }
      #expect(await store.requiresReopenBeforeFurtherAccess)
      #expect((await store.manifest).schemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion)
      await expectManifestTestAkashicError(.storageUnavailable) {
        try await store.read(
          digest: BlobDigest.sha256(of: Data("unreachable".utf8)),
          partition: try manifestTestPartition("schema4-migration-poison")
        )
      }
    }
  }

  @Test("AKASHIC-CT-091 duplicate committed global sequence fails closed")
  func duplicateCommittedSequenceIsRejectedBeforeBodyReplay() throws {
    let memory = DirectoryHeadMemoryAttributes()
    let generation: UInt64 = 13
    try initializeHeads(memory: memory, generation: generation)
    let identityA = try makeIdentity(label: "duplicate-a")
    let identityB = try makeIdentity(label: "duplicate-b")
    let recordA = try encodedRecord(
      generation: generation,
      sequence: 1,
      identity: identityA,
      physicalID: PhysicalBlobID()
    )
    let recordB = try encodedRecord(
      generation: generation,
      sequence: 1,
      identity: identityB,
      physicalID: PhysicalBlobID()
    )
    let nameA = try FileBlobStore.DirectoryHeadRecordIdentity.make(
      generation: generation,
      sequence: 1,
      key: identityA.key
    )
    let nameB = try FileBlobStore.DirectoryHeadRecordIdentity.make(
      generation: generation,
      sequence: 1,
      key: identityB.key
    )
    memory.set(nameA.name, recordA.data)
    memory.set(nameB.name, recordB.data)
    let rootA = try FileBlobStore.directoryHeadLeaf(identity: nameA, recordData: recordA.data)
    let rootB = try FileBlobStore.directoryHeadLeaf(identity: nameB, recordData: recordB.data)
    let root = try FileBlobStore.directoryHeadXor(rootA, rootB)
    try setHead(
      memory: memory,
      try FileBlobStore.makeDirectoryHead(
        generation: generation,
        slot: 1,
        sequence: 1,
        count: 2,
        root: root
      )
    )
    memory.clearReadLog()

    #expect(throws: AkashicError.invalidManifest) {
      _ = try FileBlobStore.loadDirectoryHeadState(
        directory: memory.url,
        generation: generation,
        operations: memory.operations
      )
    }
    #expect(!memory.readLog().contains(nameA.name))
    #expect(!memory.readLog().contains(nameB.name))
  }

  @Test("AKASHIC-CT-097 schema4 mutations use directory-head authority and survive reopen")
  func migratedSchema4MutationsReopenThroughDirectoryHead() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let memory = DirectoryHeadMemoryAttributes()
      let seedData = Data("schema4-reopen-seed".utf8)
      let seedDigest = BlobDigest.sha256(of: seedData)
      let seedPartition = try manifestTestPartition("schema4-reopen-seed")
      var store: FileBlobStore? = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      _ = try await store!.commit(
        data: seedData,
        digest: seedDigest,
        partition: seedPartition
      )
      #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
      let generation = await store!.manifest.generation

      let newData = Data("schema4-directory-head-create".utf8)
      let newDigest = BlobDigest.sha256(of: newData)
      let newPartition = try manifestTestPartition("schema4-directory-head-create")
      _ = try await store!.commit(
        data: newData,
        digest: newDigest,
        partition: newPartition
      )
      let currentSidecarsAfterCreate = manifestRecordFiles(in: root).filter {
        FileBlobStore.ManifestRecord.fileIdentity(from: $0.lastPathComponent)?.generation
          == generation
      }
      #expect(currentSidecarsAfterCreate.isEmpty)
      #expect(try manifestXattrRecordCount(in: root, generation: generation) == 0)
      #expect(memory.attributeNames().filter { $0.hasPrefix("dev.akashic.md1.") }.count == 1)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      store = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await store!.read(digest: seedDigest, partition: seedPartition) == seedData)
      #expect(try await store!.read(digest: newDigest, partition: newPartition) == newData)

      try await store!.remove(digest: newDigest, partition: newPartition)
      let currentSidecarsAfterRemove = manifestRecordFiles(in: root).filter {
        FileBlobStore.ManifestRecord.fileIdentity(from: $0.lastPathComponent)?.generation
          == generation
      }
      #expect(currentSidecarsAfterRemove.isEmpty)
      #expect(try manifestXattrRecordCount(in: root, generation: generation) == 0)

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(
        root: root,
        faultInjector: { _ in },
        directoryHeadOperations: memory.operations
      )
      #expect(try await reopened.read(digest: seedDigest, partition: seedPartition) == seedData)
      await expectManifestTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: newDigest, partition: newPartition)
      }
    }
  }
}
