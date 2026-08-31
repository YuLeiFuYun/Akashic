import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk FileBlobStore security")
struct FileBlobStoreSecurityTests {
  @Test("AKASHIC-CT-055 reopen repairs unsafe blob mode but rejects link substitution")
  func reopenSecurityCalibration() async throws {
    try await withManifestTestTemporaryDirectory { root in
      let data = Data("reopen-security-calibration".utf8)
      let digest = BlobDigest.sha256(of: data)
      let manifestTestPartition = try manifestTestPartition("reopen-security-calibration")
      let blob: URL
      do {
        let store = try await FileBlobStore.open(root: root)
        let publication = try await store.commit(
          data: data,
          digest: digest,
          partition: manifestTestPartition
        )
        blob = manifestTestBlobURL(root: root, id: publication.physicalID)
      }

      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o644))],
        ofItemAtPath: blob.path
      )
      do {
        let reopened = try await FileBlobStore.open(root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: blob.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
        #expect(try await reopened.read(digest: digest, partition: manifestTestPartition) == data)
      }

      try FileManager.default.removeItem(at: blob)
      let target = root.appendingPathComponent("outside-reopen-symlink")
      try data.write(to: target)
      try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: target)
      await expectManifestTestAkashicError(.storageUnavailable) {
        _ = try await FileBlobStore.open(root: root)
      }
    }
  }

}
