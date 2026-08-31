import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk segmented cleanup diagnostics")
struct SegmentedManifestSegmentCleanupDiagnosticsTests {
  @Test("cleanup retains bounded EPERM cause after owned immutable unlink failure")
  func immutableFailureRetainsCauseAndClearsAfterRecovery() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments-immutable", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let fileName = "run-g1-\(UUID().uuidString.lowercased()).seg"
      let segment = segments.appendingPathComponent(fileName, isDirectory: false)
      try writePrivateCleanupDiagnosticSegment(segment)
      defer { _ = segment.path.withCString { Darwin.chflags($0, 0) } }

      #expect(segment.path.withCString { Darwin.chflags($0, UInt32(UF_IMMUTABLE)) } == 0)
      let blocked = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: nil,
        directory: segments
      )
      #expect(blocked.deletedCount == 0)
      #expect(blocked.remainingDebtCount == 1)
      #expect(blocked.totalEntryCount == 1)
      #expect(blocked.failures.count == 1)
      #expect(blocked.failures.first?.fileName == fileName)
      #expect(blocked.failures.first?.posixCode == EPERM)
      #expect(FileManager.default.fileExists(atPath: segment.path))

      #expect(segment.path.withCString { Darwin.chflags($0, 0) } == 0)
      let recovered = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: nil,
        directory: segments
      )
      #expect(recovered.deletedCount == 1)
      #expect(recovered.remainingDebtCount == 0)
      #expect(recovered.failures.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: segment.path))
    }
  }

  @Test("cleanup distinguishes EACCES directory blocker from EPERM file blocker")
  func directoryWriteFailureRetainsDistinctCauseAndClearsAfterRecovery() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)
      let segments = root.appendingPathComponent("segments-read-only", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(segments)
      let fileName = "run-g1-\(UUID().uuidString.lowercased()).seg"
      let segment = segments.appendingPathComponent(fileName, isDirectory: false)
      try writePrivateCleanupDiagnosticSegment(segment)
      defer { _ = Darwin.chmod(segments.path, mode_t(0o700)) }

      #expect(Darwin.chmod(segments.path, mode_t(0o500)) == 0)
      let blocked = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: nil,
        directory: segments
      )
      #expect(blocked.deletedCount == 0)
      #expect(blocked.remainingDebtCount == 1)
      #expect(blocked.totalEntryCount == 1)
      #expect(blocked.failures.count == 1)
      #expect(blocked.failures.first?.fileName == fileName)
      #expect(blocked.failures.first?.posixCode == EACCES)

      #expect(Darwin.chmod(segments.path, mode_t(0o700)) == 0)
      let recovered = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
        root: nil,
        directory: segments
      )
      #expect(recovered.deletedCount == 1)
      #expect(recovered.remainingDebtCount == 0)
      #expect(recovered.failures.isEmpty)
    }
  }

  @Test("cleanup diagnostics do not weaken physical ownership rejection")
  func unsafeCanonicalLookalikesStillFailClosedBeforeDebtDiagnostics() async throws {
    try await withManifestTestTemporaryDirectory { root in
      try StorageDirectorySecurity.prepareDirectory(root)

      let symlinkDirectory = root.appendingPathComponent("segments-symlink", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(symlinkDirectory)
      let symlinkTarget = symlinkDirectory.appendingPathComponent("target.bin", isDirectory: false)
      try writePrivateCleanupDiagnosticSegment(symlinkTarget)
      let symlink = symlinkDirectory.appendingPathComponent(
        "run-g1-\(UUID().uuidString.lowercased()).seg",
        isDirectory: false
      )
      let symlinkResult = symlinkTarget.path.withCString { targetPath in
        symlink.path.withCString { linkPath in
          Darwin.symlink(targetPath, linkPath)
        }
      }
      #expect(symlinkResult == 0)
      #expect(throws: AkashicError.storageUnavailable) {
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
          root: nil,
          directory: symlinkDirectory
        )
      }
      #expect(FileManager.default.fileExists(atPath: symlinkTarget.path))

      let hardlinkDirectory = root.appendingPathComponent("segments-hardlink", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(hardlinkDirectory)
      let hardlinkSource = hardlinkDirectory.appendingPathComponent("source.bin", isDirectory: false)
      try writePrivateCleanupDiagnosticSegment(hardlinkSource)
      let hardlink = hardlinkDirectory.appendingPathComponent(
        "run-g1-\(UUID().uuidString.lowercased()).seg",
        isDirectory: false
      )
      let hardlinkResult = hardlinkSource.path.withCString { sourcePath in
        hardlink.path.withCString { linkPath in
          Darwin.link(sourcePath, linkPath)
        }
      }
      #expect(hardlinkResult == 0)
      #expect(throws: AkashicError.storageUnavailable) {
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
          root: nil,
          directory: hardlinkDirectory
        )
      }
      #expect(FileManager.default.fileExists(atPath: hardlinkSource.path))
      #expect(FileManager.default.fileExists(atPath: hardlink.path))

      let publicDirectory = root.appendingPathComponent("segments-public-mode", isDirectory: true)
      try StorageDirectorySecurity.prepareDirectory(publicDirectory)
      let publicFile = publicDirectory.appendingPathComponent(
        "run-g1-\(UUID().uuidString.lowercased()).seg",
        isDirectory: false
      )
      try writePrivateCleanupDiagnosticSegment(publicFile)
      #expect(Darwin.chmod(publicFile.path, mode_t(0o644)) == 0)
      #expect(throws: AkashicError.storageUnavailable) {
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
          root: nil,
          directory: publicDirectory
        )
      }
      #expect(FileManager.default.fileExists(atPath: publicFile.path))
    }
  }
}

private func writePrivateCleanupDiagnosticSegment(_ url: URL) throws {
  try Data("owned-cleanup-debt".utf8).write(to: url, options: .atomic)
  guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
