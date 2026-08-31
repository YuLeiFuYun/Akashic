import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk tolerated payload debt growth")
struct FileBlobStorePayloadDebtGrowthTests {
  @Test("AKASHIC-CT-169 unreclaimed payload debt consumes reopen headroom before the scan bound is exceeded")
  func unreclaimedPayloadDebtConsumesRecoveryHeadroom() async throws {
    try await withFileBlobStoreTestTemporaryDirectory { root in
      let limits = FileBlobStoreLimits(
        softTotalBytes: 64,
        maximumBlobBytes: 64,
        maximumDirectoryEntryCount: 3
      )
      var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
      let partition = try fileBlobStoreTestPartition("payload-debt-growth")
      let data = Data(repeating: 0x63, count: 16)
      let digest = BlobDigest.sha256(of: data)
      var immutablePayloads: [URL] = []
      defer {
        for url in immutablePayloads {
          try? setPayloadDebtGrowthImmutable(url, enabled: false)
        }
      }
      var successfulDebtCycles = 0
      var rejected = false

      for _ in 0..<8 {
        do {
          let publication = try await store!.commit(
            data: data,
            digest: digest,
            partition: partition
          )
          let payload = manifestTestBlobURL(root: root, id: publication.physicalID)
          #expect(FileManager.default.fileExists(atPath: payload.path))
          try setPayloadDebtGrowthImmutable(payload, enabled: true)
          immutablePayloads.append(payload)

          try await store!.remove(digest: digest, partition: partition)
          await expectFileBlobStoreTestAkashicError(.notFound) {
            _ = try await store!.read(digest: digest, partition: partition)
          }
          successfulDebtCycles += 1
          #expect(try payloadDebtDirectoryEntryCount(root: root) <= limits.maximumDirectoryEntryCount)
        } catch let error as AkashicError where error == .limitExceeded {
          rejected = true
          break
        }
      }

      #expect(successfulDebtCycles > 0)
      #expect(rejected)
      #expect(try payloadDebtDirectoryEntryCount(root: root) <= limits.maximumDirectoryEntryCount)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await store!.read(digest: digest, partition: partition)
      }

      store = nil
      try await waitForWriterLeaseRelease(root: root)
      let reopened = try await FileBlobStore.open(root: root, limits: limits)
      await expectFileBlobStoreTestAkashicError(.notFound) {
        _ = try await reopened.read(digest: digest, partition: partition)
      }
    }
  }
}

private func payloadDebtDirectoryEntryCount(root: URL) throws -> Int {
  try FileManager.default.contentsOfDirectory(
    at: root.appendingPathComponent("blobs", isDirectory: true),
    includingPropertiesForKeys: nil,
    options: []
  ).count
}

private func setPayloadDebtGrowthImmutable(_ url: URL, enabled: Bool) throws {
  let flags: UInt32 = enabled ? UInt32(UF_IMMUTABLE) : 0
  let result = url.path.withCString { Darwin.chflags($0, flags) }
  guard result == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
