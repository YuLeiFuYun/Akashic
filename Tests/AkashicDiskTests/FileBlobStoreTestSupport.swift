import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

func fileBlobStoreTestPartition(_ label: String) throws -> CachePartitionID {
  try CachePartitionID.derive(
    domain: "akashic-disk-tests",
    material: Data(label.utf8)
  )
}

func fileBlobStoreTestBlobURL(root: URL, id: PhysicalBlobID) -> URL {
  root.appendingPathComponent("blobs", isDirectory: true)
    .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
}

func fileBlobStoreTestBlobFiles(in root: URL) -> [URL] {
  let blobs = root.appendingPathComponent("blobs", isDirectory: true)
  return
    (try? FileManager.default.contentsOfDirectory(
      at: blobs,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []
}

func withFileBlobStoreTestTemporaryDirectory<T>(
  _ operation: (URL) async throws -> T
) async throws -> T {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "akashic-tests-\(UUID().uuidString.lowercased())",
    isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  return try await operation(root)
}

func expectFileBlobStoreTestAkashicError<T>(
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

func runFileBlobStoreExternalLockProbe(root: URL) -> Int32 {
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

enum FileBlobStoreInjectedFailure: Error {
  case stop
}

func executeFileBlobStoreInjectedCrash(
  root: URL,
  point: FileBlobStoreSwitchPoint,
  data: Data,
  digest: BlobDigest,
  partition: CachePartitionID
) async throws {
  do {
    let store = try await FileBlobStore.open(
      root: root,
      faultInjector: { observed in
        if observed == point { throw FileBlobStoreInjectedFailure.stop }
      }
    )
    switch point {
    case .afterBlobDataWritten,
      .afterBlobFileSynced,
      .afterBlobRenamed,
      .afterBlobDirectorySynced,
      .afterBlobFilePublished:
      _ = try await store.stage(
        data: data,
        digest: digest,
        partition: partition
      )
    case .beforeManifestPublished,
      .afterManifestDataWritten,
      .afterManifestFileSynced,
      .afterManifestRenamed,
      .afterManifestDirectorySynced,
      .afterManifestPublished:
      let stage = try await store.stage(
        data: data,
        digest: digest,
        partition: partition
      )
      _ = try await store.publish(stage)
    }
    Issue.record("Expected injected FileBlobStore failure")
  } catch FileBlobStoreInjectedFailure.stop {
    // Simulated process boundary: leave physical state untouched and release the store.
  }
  for _ in 0..<20 { await Task.yield() }
}

func fileBlobStoreSwitchLabel(_ point: FileBlobStoreSwitchPoint) -> String {
  point.rawValue
}
