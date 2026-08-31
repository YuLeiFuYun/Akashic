import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk opportunistic trim cleanup-debt poison")
struct FileBlobStoreTrimDebtPoisonTests {
  @Test("T102 optional trim seal failure preserves successful publication but freezes instance")
  func trimSealFailurePreservesPublicationAndRequiresReopen() async throws {
    for (label, target) in [
      ("pre-rename", FileBlobStoreSwitchPoint.afterManifestDataWritten),
      ("post-rename", FileBlobStoreSwitchPoint.afterManifestRenamed),
    ] {
      try await withManifestTestTemporaryDirectory { parent in
        let root = parent.appendingPathComponent(label, isDirectory: true)
        let faultState = TrimDebtSealFaultState(target: target, failOccurrenceAfterArm: 3)
        var store: FileBlobStore? = try await FileBlobStore.open(
          root: root,
          limits: FileBlobStoreLimits(
            softTotalBytes: 64,
            maximumBlobBytes: 64
          ),
          faultInjector: { point in try faultState.inject(point) }
        )
        let partition = try manifestTestPartition("trim-debt-poison-\(label)")
        var first = Data(repeating: 0x31, count: 40)
        first[0] = 0x01
        var second = Data(repeating: 0x32, count: 40)
        second[0] = 0x02
        let firstDigest = BlobDigest.sha256(of: first)
        let secondDigest = BlobDigest.sha256(of: second)

        let firstPublication = try await store!.commit(
          data: first,
          digest: firstDigest,
          partition: partition
        )
        let firstBlob = manifestTestBlobURL(root: root, id: firstPublication.physicalID)
        try setTrimDebtImmutable(firstBlob, enabled: true)
        defer { try? setTrimDebtImmutable(firstBlob, enabled: false) }

        // The three target occurrences after arming are:
        // 1. the second commit's own authority publication,
        // 2. opportunistic trim's logical tombstone,
        // 3. the protective full-snapshot seal after the immutable victim cannot be unlinked.
        faultState.arm()
        let secondPublication = try await store!.commit(
          data: second,
          digest: secondDigest,
          partition: partition
        )
        #expect(secondPublication.disposition == .created)
        #expect(faultState.armedOccurrences == 3)
        #expect(await store!.requiresReopenBeforeFurtherAccess)
        #expect(FileManager.default.fileExists(atPath: firstBlob.path))

        // Successful primary publication does not imply the actor remains usable after optional
        // maintenance poisons it. The frozen actor must reject further stateful reads.
        await expectManifestTestAkashicError(.storageUnavailable) {
          _ = try await store!.read(digest: secondDigest, partition: partition)
        }

        store = nil
        try await waitForWriterLeaseRelease(root: root)
        let reopened = try await reopenFileBlobStore(root: root)

        // Reopen owns convergence. The new primary publication survives and the logical trim of
        // the old entry must not roll back merely because its physical payload remains debt.
        #expect(try await reopened.read(digest: secondDigest, partition: partition) == second)
        await expectManifestTestAkashicError(.notFound) {
          _ = try await reopened.read(digest: firstDigest, partition: partition)
        }
        #expect(FileManager.default.fileExists(atPath: firstBlob.path))
      }
    }
  }
}

private final class TrimDebtSealFaultState: @unchecked Sendable {
  private let lock = NSLock()
  private let target: FileBlobStoreSwitchPoint
  private let failOccurrenceAfterArm: Int
  private var armed = false
  private var count = 0

  init(target: FileBlobStoreSwitchPoint, failOccurrenceAfterArm: Int) {
    self.target = target
    self.failOccurrenceAfterArm = failOccurrenceAfterArm
  }

  func arm() {
    lock.lock()
    armed = true
    count = 0
    lock.unlock()
  }

  var armedOccurrences: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func inject(_ point: FileBlobStoreSwitchPoint) throws {
    guard point.rawValue == target.rawValue else { return }
    lock.lock()
    guard armed else {
      lock.unlock()
      return
    }
    count += 1
    let shouldFail = count == failOccurrenceAfterArm
    lock.unlock()
    if shouldFail { throw POSIXError(.EIO) }
  }
}

private func setTrimDebtImmutable(_ url: URL, enabled: Bool) throws {
  let flags: UInt32 = enabled ? UInt32(UF_IMMUTABLE) : 0
  let result = url.path.withCString { Darwin.chflags($0, flags) }
  guard result == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
