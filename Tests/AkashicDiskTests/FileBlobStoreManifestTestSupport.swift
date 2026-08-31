import AkashicCore
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

struct LegacyManifestRecordFixture: Encodable {
  let schemaVersion: UInt16
  let generation: UInt64
  let sequence: UInt64
  let key: String
  let entry: FileBlobStore.Entry?
}

func createPrivateDirectory(_ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
  )
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: Int16(0o700))],
    ofItemAtPath: url.path
  )
}

func writePrivateFile(_ data: Data, to url: URL) throws {
  try data.write(to: url)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: Int16(0o600))],
    ofItemAtPath: url.path
  )
}

func legacyManifestRecordURL(root: URL, key: String) -> URL {
  root.appendingPathComponent("blobs", isDirectory: true)
    .appendingPathComponent(".manifest-entry-\(key).json", isDirectory: false)
}

func scopedManifestRecordURL(root: URL, generation: UInt64, key: String) -> URL {
  let name = FileBlobStore.ManifestRecord.fileName(generation: generation, key: key)!
  return root.appendingPathComponent("blobs", isDirectory: true)
    .appendingPathComponent(name, isDirectory: false)
}

func manifestRecordFiles(in root: URL) -> [URL] {
  let blobs = root.appendingPathComponent("blobs", isDirectory: true)
  return
    ((try? FileManager.default.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: []
    )) ?? []).filter {
      $0.lastPathComponent.hasPrefix(".manifest-entry-")
        && $0.pathExtension == "json"
    }
}

func waitForWriterLeaseRelease(root: URL) async throws {
  for _ in 0..<200 {
    if runManifestTestExternalLockProbe(root: root) == 0 { return }
    await Task.yield()
  }
  throw AkashicError.transactionConflict
}

func reopenFileBlobStore(root: URL) async throws -> FileBlobStore {
  for _ in 0..<200 {
    do {
      return try await FileBlobStore.open(root: root)
    } catch AkashicError.transactionConflict {
      await Task.yield()
    }
  }
  throw AkashicError.transactionConflict
}

func expectFileBlobStoreOpenError(
  _ expected: AkashicError,
  root: URL
) async {
  for _ in 0..<200 {
    do {
      _ = try await FileBlobStore.open(root: root)
      Issue.record("Expected AkashicError.\(expected)")
      return
    } catch AkashicError.transactionConflict {
      await Task.yield()
    } catch let error as AkashicError {
      #expect(error == expected)
      return
    } catch {
      Issue.record("Expected AkashicError.\(expected), received \(error)")
      return
    }
  }
  Issue.record("Writer lease did not release before open-error assertion")
}

func publishThroughSidecar(
  store: FileBlobStore,
  data: Data,
  digest: BlobDigest,
  partition: CachePartitionID
) async throws -> BlobPublication {
  let stage = try await store.stage(data: data, digest: digest, partition: partition)
  return try await store.publish(stage)
}

func manifestTestPartition(_ label: String) throws -> CachePartitionID {
  try CachePartitionID.derive(
    domain: "akashic-disk-tests",
    material: Data(label.utf8)
  )
}

func legacyManifestKey(
  digest: BlobDigest,
  partition: CachePartitionID
) -> String {
  var input = Data("akashic-file-blob-key-v1\u{0}".utf8)
  input.append(partition.canonicalBytes)
  input.append(0)
  input.append(Data(digest.canonicalString.utf8))
  return SHA256.hash(data: input)
    .map { String(format: "%02x", $0) }
    .joined()
}

func manifestTestBlobURL(root: URL, id: PhysicalBlobID) -> URL {
  root.appendingPathComponent("blobs", isDirectory: true)
    .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
}

func manifestTestBlobFiles(in root: URL) -> [URL] {
  let blobs = root.appendingPathComponent("blobs", isDirectory: true)
  return
    (try? FileManager.default.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
}

func manifestXattrRecordCount(in root: URL, generation: UInt64) throws -> Int {
  var count = 0
  for url in manifestTestBlobFiles(in: root) {
    guard let uuid = UUID(uuidString: url.lastPathComponent),
      uuid.uuidString.lowercased() == url.lastPathComponent
    else { continue }
    count += try FileBlobStore.readCurrentManifestXattrRecords(
      at: url,
      physicalID: PhysicalBlobID(rawValue: uuid),
      generation: generation
    ).count
  }
  return count
}

func readExtendedAttribute(_ name: String, at url: URL) throws -> Data {
  let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer { _ = Darwin.close(descriptor) }
  let required = name.withCString { pointer in
    Darwin.fgetxattr(descriptor, pointer, nil, 0, 0, 0)
  }
  guard required >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  var data = Data(count: required)
  let actual = try data.withUnsafeMutableBytes { bytes -> Int in
    let result = name.withCString { pointer in
      Darwin.fgetxattr(
        descriptor,
        pointer,
        bytes.baseAddress,
        bytes.count,
        0,
        0
      )
    }
    guard result >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return result
  }
  guard actual == required else { throw AkashicError.invalidManifest }
  return data
}

func extendedAttributeExists(_ name: String, at url: URL) throws -> Bool {
  do {
    _ = try readExtendedAttribute(name, at: url)
    return true
  } catch let error as POSIXError where error.code.rawValue == ENOATTR {
    return false
  }
}

func replaceExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
  let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer { _ = Darwin.close(descriptor) }
  let result = name.withCString { pointer in
    value.withUnsafeBytes { bytes in
      Darwin.fsetxattr(
        descriptor,
        pointer,
        bytes.baseAddress,
        bytes.count,
        0,
        XATTR_REPLACE
      )
    }
  }
  guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  guard Darwin.fsync(descriptor) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}

func moveExtendedAttribute(
  from oldName: String,
  to newName: String,
  value: Data,
  at url: URL
) throws {
  let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer { _ = Darwin.close(descriptor) }
  let removeResult = oldName.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
  guard removeResult == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  let setResult = newName.withCString { pointer in
    value.withUnsafeBytes { bytes in
      Darwin.fsetxattr(
        descriptor,
        pointer,
        bytes.baseAddress,
        bytes.count,
        0,
        XATTR_CREATE
      )
    }
  }
  guard setResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  guard Darwin.fsync(descriptor) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}

func withManifestTestTemporaryDirectory<T>(
  _ operation: (URL) async throws -> T
) async throws -> T {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "akashic-tests-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  return try await operation(root)
}

func expectManifestTestAkashicError<T>(
  _ expected: AkashicError,
  operation: () async throws -> T
) async {
  do {
    _ = try await operation()
    Issue.record("Expected AkashicError.\(expected)")
  } catch let error as AkashicError {
    #expect(error == expected)
  } catch {
    Issue.record("Expected AkashicError.\(expected), received \(error)")
  }
}

func runManifestTestExternalLockProbe(root: URL) -> Int32 {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
  process.arguments = [
    "-t", "0",
    root.appendingPathComponent(".akashic-writer.lock").path,
    "/usr/bin/true",
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  } catch {
    return -1
  }
}
