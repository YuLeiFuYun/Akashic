import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk segmented manifest V1 compatibility")
struct SegmentedManifestV1CompatibilityTests {
    @Test("public open recovers retained V1 segmented state and preserves later writes")
    func publicOpenRecoversV1AndPreservesLaterWrites() async throws {
        try await withManifestTestTemporaryDirectory { root in
            var store: FileBlobStore? = try await FileBlobStore.open(root: root)
            let partition = try fileBlobStoreTestPartition("segmented-v1-public")
            let firstData = Data("segmented-v1-first".utf8)
            let firstDigest = BlobDigest.sha256(of: firstData)
            _ = try await store!.commit(
                data: firstData,
                digest: firstDigest,
                partition: partition
            )
            #expect(try await store!.migrateLegacyManifestToDirectoryHeadSchema4())
            let migration = try await store!
                .resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
            #expect(migration.root.profile == SegmentedManifestPrototypeV1.profileV1)

            store = nil
            try await waitForWriterLeaseRelease(root: root)

            let rootURL = root.appendingPathComponent("manifest.json")
            let onDisk = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
            #expect(onDisk.profile == SegmentedManifestPrototypeV1.profileV1)
            #expect(onDisk == migration.root)

            var reopened: FileBlobStore? = try await FileBlobStore.open(root: root)
            #expect(
                try await reopened!.read(digest: firstDigest, partition: partition)
                    == firstData
            )

            let secondData = Data("segmented-v1-second".utf8)
            let secondDigest = BlobDigest.sha256(of: secondData)
            _ = try await reopened!.commit(
                data: secondData,
                digest: secondDigest,
                partition: partition
            )
            #expect(
                try await reopened!.read(digest: secondDigest, partition: partition)
                    == secondData
            )

            reopened = nil
            try await waitForWriterLeaseRelease(root: root)

            let reopenedAgain = try await FileBlobStore.open(root: root)
            #expect(
                try await reopenedAgain.read(digest: firstDigest, partition: partition)
                    == firstData
            )
            #expect(
                try await reopenedAgain.read(digest: secondDigest, partition: partition)
                    == secondData
            )
        }
    }
}
