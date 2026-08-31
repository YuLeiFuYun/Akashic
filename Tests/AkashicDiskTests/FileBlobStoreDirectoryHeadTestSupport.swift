import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

func setDirectoryHeadTestUserImmutable(_ url: URL, enabled: Bool) throws {
  let flags: UInt32 = enabled ? UInt32(UF_IMMUTABLE) : 0
  let result = url.path.withCString { Darwin.chflags($0, flags) }
  guard result == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}

func expectOwnershipIndexMatchesFullProof(
  _ store: FileBlobStore
) async throws {
  let manifest = await store.manifest
  let cached = try #require(await store.manifestOwnershipIndex)
  let rebuilt = try #require(await store.validatedManifestOwnershipIndex(manifest))
  #expect(cached.totalBytes == rebuilt.totalBytes)
  #expect(cached.keyByPhysicalID == rebuilt.keyByPhysicalID)
}

struct TestIdentity {
  let key: String
  let partition: CachePartitionID
  let digest: BlobDigest
  let byteCount: Int
}

func makeIdentity(label: String) throws -> TestIdentity {
  let data = Data("directory-head-test-\(label)".utf8)
  let partition = try CachePartitionID.derive(
    domain: "akashic-directory-head-tests-v1",
    material: Data(label.utf8)
  )
  let digest = BlobDigest.sha256(of: data)
  return TestIdentity(
    key: FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition),
    partition: partition,
    digest: digest,
    byteCount: data.count
  )
}

func encodedRecord(
  generation: UInt64,
  sequence: UInt64,
  identity: TestIdentity,
  physicalID: PhysicalBlobID
) throws -> (record: FileBlobStore.ManifestRecord, data: Data) {
  let entry = FileBlobStore.Entry(
    physicalID: physicalID,
    partition: identity.partition,
    digest: identity.digest,
    byteCount: identity.byteCount,
    lastAccess: Date(timeIntervalSinceReferenceDate: Double(sequence))
  )
  let record = FileBlobStore.ManifestRecord(
    generation: generation,
    sequence: sequence,
    key: identity.key,
    entry: entry
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return (record, try encoder.encode(record))
}

func initializeHeads(
  memory: DirectoryHeadMemoryAttributes,
  generation: UInt64
) throws {
  let heads = try FileBlobStore.initialDirectoryHeads(generation: generation)
  memory.set(
    FileBlobStore.DirectoryHeadIdentity(generation: generation, slot: 0).name,
    try FileBlobStore.encodeDirectoryHead(heads.0)
  )
  memory.set(
    FileBlobStore.DirectoryHeadIdentity(generation: generation, slot: 1).name,
    try FileBlobStore.encodeDirectoryHead(heads.1)
  )
}

func setHead(
  memory: DirectoryHeadMemoryAttributes,
  _ head: FileBlobStore.DirectoryHeadValue
) throws {
  memory.set(
    FileBlobStore.DirectoryHeadIdentity(generation: head.g, slot: head.p).name,
    try FileBlobStore.encodeDirectoryHead(head)
  )
}

func posixPermissions(of url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  guard let permissions = attributes[.posixPermissions] as? NSNumber else {
    throw AkashicError.storageUnavailable
  }
  return permissions.intValue & 0o777
}

final class DirectoryHeadMemoryAttributes: @unchecked Sendable {
  let url = URL(fileURLWithPath: "/directory-head-memory", isDirectory: true)
  private let lock = NSLock()
  private var attributes: [String: Data] = [:]
  private var reads: [String] = []
  private var setFailures: [String: POSIXErrorCode] = [:]
  private var removeFailures: [String: POSIXErrorCode] = [:]
  private var synchronizeFailuresRemaining = 0
  private var synchronizeCalls = 0

  var operations: FileBlobStoreDirectoryHeadOperations {
    FileBlobStoreDirectoryHeadOperations(
      listAttributes: { [self] _, _ in
        lock.lock()
        defer { lock.unlock() }
        return attributes.keys.sorted()
      },
      readAttribute: { [self] name, _, maximumBytes in
        lock.lock()
        defer { lock.unlock() }
        reads.append(name)
        guard let data = attributes[name], data.count <= maximumBytes else {
          throw AkashicError.invalidManifest
        }
        return data
      },
      setAttribute: { [self] name, data, _, flags in
        lock.lock()
        defer { lock.unlock() }
        if let code = setFailures[name] {
          throw POSIXError(code)
        }
        if flags == XATTR_CREATE, attributes[name] != nil {
          throw POSIXError(.EEXIST)
        }
        if flags == XATTR_REPLACE, attributes[name] == nil {
          throw POSIXError(.ENOATTR)
        }
        attributes[name] = data
      },
      removeAttribute: { [self] name, _ in
        lock.lock()
        defer { lock.unlock() }
        if let code = removeFailures[name] {
          throw POSIXError(code)
        }
        attributes.removeValue(forKey: name)
      },
      synchronizeDirectory: { [self] _ in
        lock.lock()
        defer { lock.unlock() }
        synchronizeCalls += 1
        if synchronizeFailuresRemaining > 0 {
          synchronizeFailuresRemaining -= 1
          throw POSIXError(.EIO)
        }
      }
    )
  }

  func set(_ name: String, _ data: Data) {
    lock.lock()
    attributes[name] = data
    lock.unlock()
  }

  func read(_ name: String) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = attributes[name] else { throw AkashicError.invalidManifest }
    return data
  }

  func remove(_ name: String) {
    lock.lock()
    attributes.removeValue(forKey: name)
    lock.unlock()
  }

  func failSet(name: String, code: POSIXErrorCode) {
    lock.lock()
    setFailures[name] = code
    lock.unlock()
  }

  func clearSetFailures() {
    lock.lock()
    setFailures.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  func failNextSynchronize() {
    lock.lock()
    synchronizeFailuresRemaining += 1
    lock.unlock()
  }

  func resetSynchronizeCallCount() {
    lock.lock()
    synchronizeCalls = 0
    lock.unlock()
  }

  func synchronizeCallCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return synchronizeCalls
  }

  func failRemove(name: String, code: POSIXErrorCode) {
    lock.lock()
    removeFailures[name] = code
    lock.unlock()
  }

  func clearRemoveFailures() {
    lock.lock()
    removeFailures.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  func attributeNames() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return attributes.keys.sorted()
  }

  func clearReadLog() {
    lock.lock()
    reads.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  func readLog() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }
}

final class BlobDirectorySyncFaultGate: @unchecked Sendable {
  private let lock = NSLock()
  private var failureEnabled = false
  private var observedCount = 0

  func setFailureEnabled(_ enabled: Bool) {
    lock.lock()
    failureEnabled = enabled
    lock.unlock()
  }

  func inject(_ point: FileBlobStoreSwitchPoint) throws {
    guard point == .afterBlobDirectorySynced else { return }
    lock.lock()
    observedCount += 1
    let shouldFail = failureEnabled
    lock.unlock()
    if shouldFail { throw POSIXError(.EIO) }
  }

  func observedBlobDirectorySyncCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return observedCount
  }
}
