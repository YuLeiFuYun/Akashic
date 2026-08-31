import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum DirectoryHeadMigrationError: Error {
    case invalidArguments
    case invalidFixture
    case writerLeaseDidNotRelease
    case schema3ReplayMismatch
    case shadowMigrationMismatch
    case futureSchemaWasAccepted
    case posix(Int32)
}

private struct DirectoryHeadMigrationReport: Codable {
    let schemaVersion: Int
    let status: String
    let legacyGeneration: UInt64
    let legacyEntryCount: Int
    let legacyCurrentPayloadXattrCount: Int
    let legacyCurrentSidecarCount: Int
    let mixedSchema3CarriersObserved: Bool
    let schema3ReopenReplayMatched: Bool
    let shadowGeneration: UInt64
    let shadowBaseEntryCount: Int
    let shadowPostMutationEntryCount: Int
    let shadowPostMutationMatched: Bool
    let currentSchema3ReaderRejectedSchema4Envelope: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionAuthorityChanged: Bool
        let productionSchemaChanged: Bool
        let historicalBinaryExecuted: Bool
        let processCrash: Bool
        let powerLoss: Bool
        let physicalDevice: Bool
    }
}

enum DirectoryHeadMigrationProbe {
    private struct Identity {
        let key: String
        let partition: CachePartitionID
        let digest: BlobDigest
        let data: Data
    }

    static func run(arguments: [String]) async throws {
        guard arguments.isEmpty else { throw DirectoryHeadMigrationError.invalidArguments }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-directory-head-migration-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let legacyRoot = parent.appendingPathComponent("schema3", isDirectory: true)
        let identities = try makeIdentities(labels: ["a", "b", "c", "d", "e", "f"])
        var store: FileBlobStore? = try await FileBlobStore.open(root: legacyRoot)

        let publicationA = try await store!.commit(
            data: identities[0].data,
            digest: identities[0].digest,
            partition: identities[0].partition
        )
        _ = try await store!.commit(
            data: identities[1].data,
            digest: identities[1].digest,
            partition: identities[1].partition
        )
        _ = try await store!.commit(
            data: identities[2].data,
            digest: identities[2].digest,
            partition: identities[2].partition
        )

        // Force a real same-key repair/replacement so the schema3 fixture contains a current
        // payload-xattr replacement rather than only first-insert records.
        let oldA = legacyRoot
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(
                publicationA.physicalID.rawValue.uuidString.lowercased(),
                isDirectory: false
            )
        try Data(repeating: 0x6D, count: identities[0].data.count).write(to: oldA)
        let repairedA = try await store!.commit(
            data: identities[0].data,
            digest: identities[0].digest,
            partition: identities[0].partition
        )
        guard repairedA.physicalID != publicationA.physicalID else {
            throw DirectoryHeadMigrationError.invalidFixture
        }

        // Produce a sidecar tombstone beside xattr create/replacement authority.
        try await store!.remove(
            digest: identities[1].digest,
            partition: identities[1].partition
        )
        _ = try await store!.commit(
            data: identities[3].data,
            digest: identities[3].digest,
            partition: identities[3].partition
        )

        // Explicit stage/publish intentionally remains sidecar-based in schema3.
        let stageE = try await store!.stage(
            data: identities[4].data,
            digest: identities[4].digest,
            partition: identities[4].partition
        )
        _ = try await store!.publish(stageE)

        let expectedSchema3 = await store!.resourceProbeManifestShadowSnapshot()
        let fullSchema3SnapshotData = try await store!.resourceProbeEncodedManifestSnapshot()
        let carrierCounts = try countLegacyCarriers(root: legacyRoot)
        guard carrierCounts.xattrs > 0, carrierCounts.sidecars > 0 else {
            throw DirectoryHeadMigrationError.invalidFixture
        }

        store = nil
        let reopened = try await reopenAfterLeaseRelease(root: legacyRoot)
        let replayedSchema3 = await reopened.resourceProbeManifestShadowSnapshot()
        guard replayedSchema3 == expectedSchema3 else {
            throw DirectoryHeadMigrationError.schema3ReplayMismatch
        }

        let shadowGenerationResult = replayedSchema3.generation.addingReportingOverflow(1)
        guard !shadowGenerationResult.overflow else {
            throw DirectoryHeadMigrationError.invalidFixture
        }
        let shadowGeneration = shadowGenerationResult.partialValue
        let shadowRoot = parent.appendingPathComponent("schema4-shadow", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shadowRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try DirectoryHeadShadowProbe.initializeMigrationShadow(
            root: shadowRoot,
            generation: shadowGeneration
        )

        var expectedShadow = replayedSchema3.entries
        guard let priorA = expectedShadow[identities[0].key] else {
            throw DirectoryHeadMigrationError.invalidFixture
        }
        let replacementA = FileBlobStoreRecordShadowEntry(
            physicalID: PhysicalBlobID(),
            partition: priorA.partition,
            digest: priorA.digest,
            byteCount: priorA.byteCount,
            lastAccess: Date(timeIntervalSinceReferenceDate: priorA.lastAccess.timeIntervalSinceReferenceDate + 1)
        )
        try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
            root: shadowRoot,
            generation: shadowGeneration,
            key: identities[0].key,
            entry: replacementA
        )
        expectedShadow[identities[0].key] = replacementA

        try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
            root: shadowRoot,
            generation: shadowGeneration,
            key: identities[2].key,
            entry: nil
        )
        expectedShadow.removeValue(forKey: identities[2].key)

        let newF = FileBlobStoreRecordShadowEntry(
            physicalID: PhysicalBlobID(),
            partition: identities[5].partition,
            digest: identities[5].digest,
            byteCount: identities[5].data.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 10_000)
        )
        try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
            root: shadowRoot,
            generation: shadowGeneration,
            key: identities[5].key,
            entry: newF
        )
        expectedShadow[identities[5].key] = newF

        let shadowRecovered = try DirectoryHeadShadowProbe.recoverMigrationShadow(
            root: shadowRoot,
            generation: shadowGeneration,
            base: replayedSchema3.entries
        )
        guard shadowRecovered == expectedShadow else {
            throw DirectoryHeadMigrationError.shadowMigrationMismatch
        }

        let futureSchemaRejected = try await verifySchema4EnvelopeRejected(
            parent: parent,
            schema3SnapshotData: fullSchema3SnapshotData
        )
        guard futureSchemaRejected else {
            throw DirectoryHeadMigrationError.futureSchemaWasAccepted
        }

        let report = DirectoryHeadMigrationReport(
            schemaVersion: 1,
            status: "passed",
            legacyGeneration: replayedSchema3.generation,
            legacyEntryCount: replayedSchema3.entries.count,
            legacyCurrentPayloadXattrCount: carrierCounts.xattrs,
            legacyCurrentSidecarCount: carrierCounts.sidecars,
            mixedSchema3CarriersObserved: true,
            schema3ReopenReplayMatched: true,
            shadowGeneration: shadowGeneration,
            shadowBaseEntryCount: replayedSchema3.entries.count,
            shadowPostMutationEntryCount: shadowRecovered.count,
            shadowPostMutationMatched: true,
            currentSchema3ReaderRejectedSchema4Envelope: true,
            claims: .init(
                productionAuthorityChanged: false,
                productionSchemaChanged: false,
                historicalBinaryExecuted: false,
                processCrash: false,
                powerLoss: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func makeIdentities(labels: [String]) throws -> [Identity] {
        try labels.map { label in
            let partition = try CachePartitionID.derive(
                domain: "akashic-directory-head-migration-shadow-v1",
                material: Data("partition-\(label)".utf8)
            )
            let data = Data("migration-shadow-payload-\(label)-\(String(repeating: label, count: 9))".utf8)
            let digest = BlobDigest.sha256(of: data)
            return Identity(
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: digest,
                    partition: partition
                ),
                partition: partition,
                digest: digest,
                data: data
            )
        }
    }

    private static func countLegacyCarriers(root: URL) throws -> (xattrs: Int, sidecars: Int) {
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: nil,
            options: []
        )
        var xattrs = 0
        var sidecars = 0
        for url in children {
            let name = url.lastPathComponent
            if name.hasPrefix(".manifest-entry-") && name.hasSuffix(".json") {
                sidecars += 1
                continue
            }
            guard UUID(uuidString: name) != nil else { continue }
            for attribute in try XattrShadowProbeIO.listAttributes(url) {
                if attribute.hasPrefix(ManifestXattrIdentity.prefix) {
                    xattrs += 1
                }
            }
        }
        return (xattrs, sidecars)
    }

    private static func reopenAfterLeaseRelease(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.open(root: root)
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw DirectoryHeadMigrationError.writerLeaseDidNotRelease
    }

    private static func verifySchema4EnvelopeRejected(
        parent: URL,
        schema3SnapshotData: Data
    ) async throws -> Bool {
        guard var object = try JSONSerialization.jsonObject(with: schema3SnapshotData)
            as? [String: Any]
        else { throw DirectoryHeadMigrationError.invalidFixture }
        object["schemaVersion"] = 4
        let schema4Data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let root = parent.appendingPathComponent("schema4-downgrade-control", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try writePrivateFile(
            root.appendingPathComponent("manifest.json", isDirectory: false),
            data: schema4Data
        )
        do {
            _ = try await FileBlobStore.open(root: root)
            return false
        } catch AkashicError.unsupportedSchema {
            return true
        }
    }

    private static func writePrivateFile(_ url: URL, data: Data) throws {
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw DirectoryHeadMigrationError.posix(errno) }
        var isOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw DirectoryHeadMigrationError.posix(errno)
                    }
                    guard written > 0 else { throw DirectoryHeadMigrationError.posix(EIO) }
                    offset += written
                }
            }
            while true {
                if Darwin.fsync(descriptor) == 0 { break }
                if errno == EINTR { continue }
                throw DirectoryHeadMigrationError.posix(errno)
            }
            guard Darwin.close(descriptor) == 0 else {
                throw DirectoryHeadMigrationError.posix(errno)
            }
            isOpen = false
        } catch {
            if isOpen { _ = Darwin.close(descriptor) }
            throw error
        }
    }
}
