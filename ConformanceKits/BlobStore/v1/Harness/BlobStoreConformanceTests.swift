import AkashicCore
import Foundation
import XCTest

final class BlobStoreConformanceTests: XCTestCase {
    func testPartitionVisibilityAndRemovalIsolation_BSC_001() async throws {
        let root = try temporaryRoot("partition-isolation")
        let store = try await BlobStoreUnderTest.open(
            root: root,
            softTotalBytes: 4 * 1_024 * 1_024,
            maximumBlobBytes: 1_024 * 1_024
        )
        let data = Data("akashic-conformance-partition-isolation".utf8)
        let digest = BlobDigest.sha256(of: data)
        let first = try partition("first")
        let second = try partition("second")

        _ = try await store.commit(data: data, digest: digest, partition: first)
        let firstRead = try await store.read(digest: digest, partition: first)
        XCTAssertEqual(firstRead, data)
        await assertAkashicError(.notFound) {
            _ = try await store.read(digest: digest, partition: second)
        }

        try await store.removeAll(partition: second)
        let retainedRead = try await store.read(digest: digest, partition: first)
        XCTAssertEqual(retainedRead, data)
    }

    func testStageIsInvisibleUntilPublish_BSC_002() async throws {
        let root = try temporaryRoot("stage-invisible")
        let store = try await openStore(root)
        let data = Data("akashic-conformance-stage-invisible".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try partition("stage")

        let stage = try await store.stage(data: data, digest: digest, partition: partition)
        await assertAkashicError(.notFound) {
            _ = try await store.read(digest: digest, partition: partition)
        }
        let stagedPhysicalID = await store.physicalID(digest: digest, partition: partition)
        XCTAssertNil(stagedPhysicalID)

        let publication = try await store.publish(stage)
        XCTAssertEqual(publication.disposition, .created)
        XCTAssertEqual(publication.byteCount, data.count)
        let publishedRead = try await store.read(digest: digest, partition: partition)
        XCTAssertEqual(publishedRead, data)
    }

    func testPublishHasOneTerminalTransition_BSC_003() async throws {
        let root = try temporaryRoot("publish-terminal")
        let store = try await openStore(root)
        let data = Data("akashic-conformance-publish-terminal".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try partition("publish")
        let stage = try await store.stage(data: data, digest: digest, partition: partition)

        _ = try await store.publish(stage)
        await assertAkashicError(.transactionConflict) {
            _ = try await store.publish(stage)
        }
        let publishedRead = try await store.read(digest: digest, partition: partition)
        XCTAssertEqual(publishedRead, data)
    }

    func testDiscardIsIdempotentAndTerminal_BSC_004() async throws {
        let root = try temporaryRoot("discard-terminal")
        let store = try await openStore(root)
        let data = Data("akashic-conformance-discard-terminal".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try partition("discard")
        let stage = try await store.stage(data: data, digest: digest, partition: partition)

        await store.discard(stage)
        await store.discard(stage)
        await assertAkashicError(.transactionConflict) {
            _ = try await store.publish(stage)
        }
        await assertAkashicError(.notFound) {
            _ = try await store.read(digest: digest, partition: partition)
        }
    }

    func testSamePartitionDuplicateCommitReusesPhysicalBlob_BSC_005() async throws {
        let root = try temporaryRoot("same-partition-reuse")
        let store = try await openStore(root)
        let data = Data("akashic-conformance-same-partition-reuse".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try partition("reuse")

        let first = try await store.commit(data: data, digest: digest, partition: partition)
        let second = try await store.commit(data: data, digest: digest, partition: partition)

        XCTAssertEqual(first.disposition, .created)
        XCTAssertEqual(second.disposition, .reused)
        XCTAssertEqual(first.physicalID, second.physicalID)
        XCTAssertEqual(first.byteCount, data.count)
        XCTAssertEqual(second.byteCount, data.count)
    }

    func testCrossPartitionPhysicalDeduplicationIsForbidden_BSC_006() async throws {
        let root = try temporaryRoot("cross-partition-physical")
        let store = try await openStore(root)
        let data = Data("akashic-conformance-cross-partition".utf8)
        let digest = BlobDigest.sha256(of: data)
        let firstPartition = try partition("partition-a")
        let secondPartition = try partition("partition-b")

        let first = try await store.commit(
            data: data,
            digest: digest,
            partition: firstPartition
        )
        let second = try await store.commit(
            data: data,
            digest: digest,
            partition: secondPartition
        )

        XCTAssertEqual(first.disposition, .created)
        XCTAssertEqual(second.disposition, .created)
        XCTAssertNotEqual(first.physicalID, second.physicalID)
    }

    func testStoreRecomputesDigestBeforePublication_BSC_007() async throws {
        let root = try temporaryRoot("digest-recompute")
        let store = try await openStore(root)
        let declaredData = Data("akashic-conformance-declared".utf8)
        let actualData = Data("akashic-conformance-actual".utf8)
        let declared = BlobDigest.sha256(of: declaredData)
        let partition = try partition("integrity")

        await assertAkashicError(.integrityMismatch) {
            _ = try await store.commit(
                data: actualData,
                digest: declared,
                partition: partition
            )
        }
        let physicalID = await store.physicalID(digest: declared, partition: partition)
        XCTAssertNil(physicalID)
    }

    func testRemoveAndRemoveAllPreserveOtherAuthority_BSC_008() async throws {
        let root = try temporaryRoot("remove-authority")
        let store = try await openStore(root)
        let firstData = Data("akashic-conformance-remove-first".utf8)
        let secondData = Data("akashic-conformance-remove-second".utf8)
        let firstDigest = BlobDigest.sha256(of: firstData)
        let secondDigest = BlobDigest.sha256(of: secondData)
        let firstPartition = try partition("remove-first")
        let secondPartition = try partition("remove-second")

        _ = try await store.commit(data: firstData, digest: firstDigest, partition: firstPartition)
        _ = try await store.commit(data: secondData, digest: secondDigest, partition: firstPartition)
        _ = try await store.commit(data: firstData, digest: firstDigest, partition: secondPartition)

        try await store.remove(digest: firstDigest, partition: firstPartition)
        await assertAkashicError(.notFound) {
            _ = try await store.read(digest: firstDigest, partition: firstPartition)
        }
        let remainingFirstPartition = try await store.read(
            digest: secondDigest,
            partition: firstPartition
        )
        XCTAssertEqual(remainingFirstPartition, secondData)

        try await store.removeAll(partition: firstPartition)
        await assertAkashicError(.notFound) {
            _ = try await store.read(digest: secondDigest, partition: firstPartition)
        }
        let remainingSecondPartition = try await store.read(
            digest: firstDigest,
            partition: secondPartition
        )
        XCTAssertEqual(remainingSecondPartition, firstData)
    }

    func testGarbageCollectionRetainsOnlyDeclaredReferences_BSC_009() async throws {
        let root = try temporaryRoot("garbage-collect")
        let store = try await openStore(root)
        let retainedData = Data("akashic-conformance-retained".utf8)
        let removedData = Data("akashic-conformance-removed".utf8)
        let retainedDigest = BlobDigest.sha256(of: retainedData)
        let removedDigest = BlobDigest.sha256(of: removedData)
        let partition = try partition("gc")

        _ = try await store.commit(
            data: retainedData,
            digest: retainedDigest,
            partition: partition
        )
        _ = try await store.commit(
            data: removedData,
            digest: removedDigest,
            partition: partition
        )
        let references: Set<LiveBlobReference> = [
            LiveBlobReference(partition: partition, digest: retainedDigest)
        ]
        let result = try await store.garbageCollect(
            retaining: references,
            limits: try BlobMaintenanceLimits(
                maximumReferenceCount: 8,
                maximumReferencedBytes: 4 * 1_024 * 1_024
            )
        )

        XCTAssertEqual(result.removedBlobCount, 1)
        XCTAssertEqual(result.removedByteCount, removedData.count)
        let retainedRead = try await store.read(
            digest: retainedDigest,
            partition: partition
        )
        XCTAssertEqual(retainedRead, retainedData)
        await assertAkashicError(.notFound) {
            _ = try await store.read(digest: removedDigest, partition: partition)
        }
    }

    func testPublishedBytesSurviveStoreReopen_BSC_010() async throws {
        let root = try temporaryRoot("reopen")
        let data = Data("akashic-conformance-reopen".utf8)
        let digest = BlobDigest.sha256(of: data)
        let partition = try partition("reopen")
        var store: (any BlobStoreMaintaining & TransactionalBlobStoring)? = try await openStore(root)
        _ = try await store!.commit(data: data, digest: digest, partition: partition)

        store = nil
        for _ in 0..<20 { await Task.yield() }

        let reopened = try await openStore(root)
        let reopenedRead = try await reopened.read(digest: digest, partition: partition)
        XCTAssertEqual(reopenedRead, data)
    }

    func testGenerationIdentityIsStablePerCompatibilityFingerprint_BSC_011() async throws {
        let root = try temporaryRoot("generation")
        let firstFingerprint = "akashic-blob-store-conformance-v1:first"
        let secondFingerprint = "akashic-blob-store-conformance-v1:second"

        let first = try await BlobStoreUnderTest.openGeneration(
            root: root,
            compatibilityFingerprint: firstFingerprint
        )
        let reopened = try await BlobStoreUnderTest.openGeneration(
            root: root,
            compatibilityFingerprint: firstFingerprint
        )
        XCTAssertEqual(first, reopened)
        XCTAssertEqual(first.compatibilityFingerprint, firstFingerprint)

        let second = try await BlobStoreUnderTest.openGeneration(
            root: root,
            compatibilityFingerprint: secondFingerprint
        )
        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertEqual(second.compatibilityFingerprint, secondFingerprint)
    }

    func testOneActiveWriterPerStoreRoot_BSC_012() async throws {
        let root = try temporaryRoot("writer-exclusivity")
        var first: (any BlobStoreMaintaining & TransactionalBlobStoring)? = try await openStore(root)
        XCTAssertNotNil(first)
        await assertAkashicError(.transactionConflict) {
            _ = try await self.openStore(root)
        }

        first = nil
        for _ in 0..<20 { await Task.yield() }
        let reopened = try await openStore(root)
        let probe = BlobDigest.sha256(of: Data())
        let probePartition = try partition("writer-probe")
        let reopenedPhysicalID = await reopened.physicalID(
            digest: probe,
            partition: probePartition
        )
        XCTAssertNil(reopenedPhysicalID)
    }

    private func openStore(
        _ root: URL
    ) async throws -> any BlobStoreMaintaining & TransactionalBlobStoring {
        try await BlobStoreUnderTest.open(
            root: root,
            softTotalBytes: 4 * 1_024 * 1_024,
            maximumBlobBytes: 1 * 1_024 * 1_024
        )
    }

    private func partition(_ label: String) throws -> CachePartitionID {
        try CachePartitionID.derive(
            domain: "dev.akashic.conformance.blob-store.v1",
            material: Data(label.utf8)
        )
    }

    private func temporaryRoot(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-blob-store-conformance-\(suffix)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func assertAkashicError(
        _ expected: AkashicError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected AkashicError.\(expected)")
        } catch let error as AkashicError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected AkashicError.\(expected), observed \(error)")
        }
    }
}
