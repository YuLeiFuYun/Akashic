import AkashicCore
@testable import AkashicDisk
import Darwin
import Foundation
import Testing

@Suite("AkashicDisk FileBlobStore")
struct FileBlobStoreTests {
    @Test("AKASHIC-CT-004 partition logical isolation")
    func partitionLogicalIsolation() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("partition-isolation".utf8)
            let digest = BlobDigest.sha256(of: data)
            let first = try partition("first")
            let second = try partition("second")

            _ = try await store.commit(data: data, digest: digest, partition: first)
            #expect(try await store.read(digest: digest, partition: first) == data)
            await expectAkashicError(.notFound) {
                _ = try await store.read(digest: digest, partition: second)
            }

            try await store.removeAll(partition: second)
            #expect(try await store.read(digest: digest, partition: first) == data)
        }
    }

    @Test("AKASHIC-CT-005 stage remains invisible")
    func stageRemainsInvisible() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("invisible-stage".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("stage")

            let stage = try await store.stage(
                data: data,
                digest: digest,
                partition: partition
            )
            await expectAkashicError(.notFound) {
                _ = try await store.read(digest: digest, partition: partition)
            }
            #expect(await store.physicalID(digest: digest, partition: partition) == nil)

            _ = try await store.publish(stage)
            #expect(try await store.read(digest: digest, partition: partition) == data)
        }
    }

    @Test("AKASHIC-CT-006 publish has one terminal transition")
    func publishSingleTerminalTransition() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("single-terminal".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("publish")
            let stage = try await store.stage(
                data: data,
                digest: digest,
                partition: partition
            )

            let publication = try await store.publish(stage)
            #expect(publication.disposition == .created)
            await expectAkashicError(.transactionConflict) {
                _ = try await store.publish(stage)
            }
            #expect(try await store.read(digest: digest, partition: partition) == data)
        }
    }

    @Test("AKASHIC-CT-007 discard is idempotent and terminal")
    func discardIdempotentAndTerminal() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("discard-terminal".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("discard")
            let stage = try await store.stage(
                data: data,
                digest: digest,
                partition: partition
            )

            await store.discard(stage)
            await store.discard(stage)
            await expectAkashicError(.transactionConflict) {
                _ = try await store.publish(stage)
            }
            await expectAkashicError(.notFound) {
                _ = try await store.read(digest: digest, partition: partition)
            }
        }
    }

    @Test("AKASHIC-CT-008 same-partition duplicate commit reuses physical blob")
    func samePartitionDuplicateCommit() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("same-partition-reuse".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("reuse")

            let first = try await store.commit(
                data: data,
                digest: digest,
                partition: partition
            )
            let second = try await store.commit(
                data: data,
                digest: digest,
                partition: partition
            )

            #expect(first.disposition == .created)
            #expect(second.disposition == .reused)
            #expect(first.physicalID == second.physicalID)
            #expect(blobFiles(in: root).count == 1)
        }
    }

    @Test("AKASHIC-CT-009 cross-partition physical deduplication is forbidden")
    func crossPartitionNoPhysicalDeduplication() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("cross-partition".utf8)
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

            #expect(first.physicalID != second.physicalID)
            #expect(first.disposition == .created)
            #expect(second.disposition == .created)
            #expect(blobFiles(in: root).count == 2)
        }
    }

    @Test("AKASHIC-CT-010 store recomputes digest")
    func storeRecomputesDigest() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let declared = BlobDigest.sha256(of: Data("declared".utf8))
            let actual = Data("actual".utf8)
            let partition = try partition("integrity")

            await expectAkashicError(.integrityMismatch) {
                _ = try await store.commit(
                    data: actual,
                    digest: declared,
                    partition: partition
                )
            }
            #expect(blobFiles(in: root).isEmpty)
        }
    }


    @Test("AKASHIC-CT-011 logical publication switch recovery")
    func logicalPublicationSwitchRecovery() async throws {
        let points: [FileBlobStoreSwitchPoint] = [
            .afterBlobFilePublished,
            .beforeManifestPublished,
            .afterManifestPublished,
        ]
        for point in points {
            try await withTemporaryDirectory { root in
                let data = Data("switch-\(blobSwitchLabel(point))".utf8)
                let digest = BlobDigest.sha256(of: data)
                let partition = try partition(blobSwitchLabel(point))

                try await executeInjectedStoreCrash(
                    root: root,
                    point: point,
                    data: data,
                    digest: digest,
                    partition: partition
                )

                let reopened = try await FileBlobStore.open(root: root)
                switch point {
                case .afterManifestPublished:
                    #expect(
                        try await reopened.read(
                            digest: digest,
                            partition: partition
                        ) == data
                    )
                    #expect(blobFiles(in: root).count == 1)
                case .afterBlobFilePublished, .beforeManifestPublished:
                    await expectAkashicError(.notFound) {
                        _ = try await reopened.read(
                            digest: digest,
                            partition: partition
                        )
                    }
                    #expect(blobFiles(in: root).isEmpty)
                default:
                    Issue.record("Unexpected high-level switch point")
                }
            }
        }
    }

    @Test("AKASHIC-CT-012 future manifest schema fails closed")
    func futureManifestSchemaFailsClosed() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            let manifest = root.appendingPathComponent("manifest.json")
            try Data(#"{"schemaVersion":999,"entries":{}}"#.utf8).write(to: manifest)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: manifest.path
            )

            await expectAkashicError(.unsupportedSchema) {
                _ = try await FileBlobStore.open(root: root)
            }
            let unchanged = try Data(contentsOf: manifest)
            #expect(String(decoding: unchanged, as: UTF8.self).contains("999"))
        }
    }

    @Test("AKASHIC-CT-015 external truncation is quarantined")
    func externalTruncationIsQuarantined() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("truncate-me".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("truncate")
            let publication = try await store.commit(
                data: data,
                digest: digest,
                partition: partition
            )
            let blob = blobURL(root: root, id: publication.physicalID)
            try Data(data.prefix(2)).write(to: blob)

            await expectAkashicError(.integrityMismatch) {
                _ = try await store.read(digest: digest, partition: partition)
            }
            await expectAkashicError(.notFound) {
                _ = try await store.read(digest: digest, partition: partition)
            }
            #expect(!FileManager.default.fileExists(atPath: blob.path))
        }
    }


    @Test("AKASHIC-CT-015 external deletion and same-length corruption are quarantined")
    func externalDeletionAndCorruption() async throws {
        for mode in ["delete", "corrupt"] {
            try await withTemporaryDirectory { root in
                let store = try await FileBlobStore.open(root: root)
                let data = Data("mutation-\(mode)".utf8)
                let digest = BlobDigest.sha256(of: data)
                let partition = try partition(mode)
                let publication = try await store.commit(
                    data: data,
                    digest: digest,
                    partition: partition
                )
                let blob = blobURL(root: root, id: publication.physicalID)
                if mode == "delete" {
                    try FileManager.default.removeItem(at: blob)
                } else {
                    try Data(repeating: 0x5a, count: data.count).write(to: blob)
                }

                await expectAkashicError(.integrityMismatch) {
                    _ = try await store.read(digest: digest, partition: partition)
                }
                await expectAkashicError(.notFound) {
                    _ = try await store.read(digest: digest, partition: partition)
                }
            }
        }
    }

    @Test("AKASHIC-CT-017 physical locator is UUID constrained")
    func physicalLocatorUUIDConstrained() throws {
        let uuid = UUID()
        let identifier = PhysicalBlobID(rawValue: uuid)
        let encoded = try JSONEncoder().encode(identifier)
        let decoded = try JSONDecoder().decode(PhysicalBlobID.self, from: encoded)

        #expect(decoded == identifier)
        #expect(decoded.rawValue == uuid)
        #expect(!decoded.rawValue.uuidString.contains("/"))
        #expect(!decoded.rawValue.uuidString.contains(".."))
    }

    @Test("AKASHIC-CT-021 in-process concurrent readers remain consistent")
    func concurrentReaders() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data(repeating: 0x42, count: 4_096)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("concurrent-readers")
            _ = try await store.commit(data: data, digest: digest, partition: partition)

            let results = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<32 {
                    group.addTask {
                        for _ in 0..<25 {
                            guard try await store.read(
                                digest: digest,
                                partition: partition
                            ) == data else { return false }
                        }
                        return true
                    }
                }
                var values: [Bool] = []
                for try await value in group { values.append(value) }
                return values
            }
            #expect(results.count == 32)
            #expect(results.allSatisfy { $0 })
        }
    }

    @Test("AKASHIC-CT-016 links, unsafe permissions and wrong file types are rejected")
    func filesystemDefenses() async throws {
        try await assertMutationRejected(kind: "symlink") { blob, root in
            let target = root.appendingPathComponent("outside-target")
            try Data("outside".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: target)
        }
        try await assertMutationRejected(kind: "hardlink") { blob, root in
            let target = root.appendingPathComponent("outside-hardlink-target")
            try Data("outside".utf8).write(to: target)
            try FileManager.default.linkItem(at: target, to: blob)
        }
        try await assertMutationRejected(kind: "permissions") { blob, _ in
            try Data("replacement".utf8).write(to: blob)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))],
                ofItemAtPath: blob.path
            )
        }
        try await assertMutationRejected(kind: "directory") { blob, _ in
            try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: false)
        }
    }

    @Test("AKASHIC-CT-018 maintenance limits fail before mutation")
    func maintenanceLimitsFailBeforeMutation() async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("maintenance".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition("maintenance")
            _ = try await store.commit(data: data, digest: digest, partition: partition)
            let references: Set<LiveBlobReference> = [
                LiveBlobReference(partition: partition, digest: digest)
            ]
            let limits = try BlobMaintenanceLimits(
                maximumReferenceCount: 1,
                maximumReferencedBytes: data.count - 1
            )

            await expectAkashicError(.limitExceeded) {
                _ = try await store.garbageCollect(
                    retaining: references,
                    limits: limits
                )
            }
            #expect(try await store.read(digest: digest, partition: partition) == data)
        }
    }

    @Test("AKASHIC-CT-018 directory entry limit fails before unbounded collection")
    func directoryEntryLimit() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            for name in ["extra-a", "extra-b"] {
                let url = root.appendingPathComponent(name)
                try Data([0x01]).write(to: url)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: url.path
                )
            }
            let limits = FileBlobStoreLimits(maximumDirectoryEntryCount: 3)
            await expectAkashicError(.limitExceeded) {
                _ = try await FileBlobStore.open(root: root, limits: limits)
            }
        }
    }

    @Test("AKASHIC-CT-020 one active writer per store root")
    func oneActiveWriter() async throws {
        try await withTemporaryDirectory { root in
            var first: FileBlobStore? = try await FileBlobStore.open(root: root)
            #expect(first != nil)
            await expectAkashicError(.transactionConflict) {
                _ = try await FileBlobStore.open(root: root)
            }
            #expect(runExternalLockProbe(root: root) != 0)

            first = nil
            for _ in 0..<20 { await Task.yield() }
            #expect(runExternalLockProbe(root: root) == 0)
            let reopened = try await FileBlobStore.open(root: root)
            let emptyDigest = BlobDigest.sha256(of: Data())
            let emptyPartition = try partition("reopened")
            #expect(
                await reopened.physicalID(
                    digest: emptyDigest,
                    partition: emptyPartition
                ) == nil
            )
        }
    }

    private func assertMutationRejected(
        kind: String,
        mutation: (URL, URL) throws -> Void
    ) async throws {
        try await withTemporaryDirectory { root in
            let store = try await FileBlobStore.open(root: root)
            let data = Data("filesystem-\(kind)".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try partition(kind)
            let publication = try await store.commit(
                data: data,
                digest: digest,
                partition: partition
            )
            let blob = blobURL(root: root, id: publication.physicalID)
            try FileManager.default.removeItem(at: blob)
            try mutation(blob, root)

            await expectAkashicError(.integrityMismatch) {
                _ = try await store.read(digest: digest, partition: partition)
            }
            await expectAkashicError(.notFound) {
                _ = try await store.read(digest: digest, partition: partition)
            }
        }
    }
}

private func partition(_ label: String) throws -> CachePartitionID {
    try CachePartitionID.derive(
        domain: "akashic-disk-tests",
        material: Data(label.utf8)
    )
}

private func blobURL(root: URL, id: PhysicalBlobID) -> URL {
    root.appendingPathComponent("blobs", isDirectory: true)
        .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
}

private func blobFiles(in root: URL) -> [URL] {
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    return (try? FileManager.default.contentsOfDirectory(
        at: blobs,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []
}

private func withTemporaryDirectory<T>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "akashic-tests-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    return try await operation(root)
}

private func expectAkashicError<T>(
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

private func runExternalLockProbe(root: URL) -> Int32 {
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

private enum BlobInjectedFailure: Error {
    case stop
}

private func executeInjectedStoreCrash(
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
                if observed == point { throw BlobInjectedFailure.stop }
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
    } catch BlobInjectedFailure.stop {
        // Simulated process boundary: leave physical state untouched and release the store.
    }
    for _ in 0..<20 { await Task.yield() }
}

private func blobSwitchLabel(_ point: FileBlobStoreSwitchPoint) -> String {
    point.rawValue
}
