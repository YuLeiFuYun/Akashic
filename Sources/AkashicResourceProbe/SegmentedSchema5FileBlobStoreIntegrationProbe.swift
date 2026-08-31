import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5FileBlobStoreIntegrationReport: Codable {
    struct Claims: Codable {
        let automaticMigration: Bool
        let backgroundCompaction: Bool
        let formalPerformance: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let migrationGeneration: UInt64
    let migrationEntryCount: Int
    let repairedHeadCountAfterFirstOpen: Int
    let hotDeltaDistinctKeys: Int
    let hotDeltaReopenExact: Bool
    let preCheckpointDistinctKeys: Int
    let preCheckpointRunCount: Int
    let checkpointGeneration: UInt64
    let checkpointRunCount: Int
    let checkpointRunRecords: Int
    let postCheckpointDistinctKeys: Int
    let postCheckpointReopenExact: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5FileBlobStoreIntegration(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        let base = try schema5IntegrationIdentities(prefix: "base", count: 3)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        _ = try await store!.commit(data: base[0].data, digest: base[0].digest, partition: base[0].partition)
        _ = try await store!.commit(data: base[1].data, digest: base[1].digest, partition: base[1].partition)
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.commit(data: base[2].data, digest: base[2].digest, partition: base[2].partition)
        let beforeMigration = await store!.resourceProbeManifestShadowSnapshot()
        let schema4Active = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        guard schema4Active.distinctKeyCount == 1 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        let migrationGeneration = migration.root.generation
        store = nil

        store = try await schema5IntegrationOpen(root: root)
        let reopenedAfterMigration = await store!.resourceProbeManifestShadowSnapshot()
        guard reopenedAfterMigration.entries == beforeMigration.entries,
            reopenedAfterMigration.generation == migrationGeneration
        else { throw SegmentedManifestShadowError.invariantViolation }
        let repairedHeads = try SegmentedManifestDirectoryHeadPrototypeV1.currentHeadCount(
            generation: migrationGeneration,
            blobsDirectory: root.appendingPathComponent("blobs", isDirectory: true)
        )
        guard repairedHeads == 2 else { throw SegmentedManifestShadowError.invariantViolation }

        let hot = try schema5IntegrationIdentities(prefix: "hot", count: 512)
        _ = try await store!.commit(data: hot[0].data, digest: hot[0].digest, partition: hot[0].partition)
        let hotActive = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let rootBeforeHotReopen = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        guard hotActive.distinctKeyCount == 1,
            rootBeforeHotReopen.generation == migrationGeneration,
            rootBeforeHotReopen.runs.isEmpty
        else { throw SegmentedManifestShadowError.invariantViolation }
        let hotExpected = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        store = try await schema5IntegrationOpen(root: root)
        let hotReopened = await store!.resourceProbeManifestShadowSnapshot()
        let hotDeltaReopenExact = hotReopened.entries == hotExpected.entries
            && hotReopened.generation == hotExpected.generation
        guard hotDeltaReopenExact else { throw SegmentedManifestShadowError.invariantViolation }

        for index in 1...510 {
            _ = try await store!.commit(
                data: hot[index].data,
                digest: hot[index].digest,
                partition: hot[index].partition
            )
        }
        let preCheckpoint = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let preCheckpointRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        guard preCheckpoint.distinctKeyCount == 511,
            preCheckpointRoot.generation == migrationGeneration,
            preCheckpointRoot.runs.isEmpty
        else { throw SegmentedManifestShadowError.invariantViolation }

        _ = try await store!.commit(
            data: hot[511].data,
            digest: hot[511].digest,
            partition: hot[511].partition
        )
        let expectedAfterCheckpoint = await store!.resourceProbeManifestShadowSnapshot()
        let postCheckpoint = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let checkpointRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        guard checkpointRoot.generation == migrationGeneration + 1,
            checkpointRoot.runs.count == 1,
            checkpointRoot.runs[0].recordCount == 512,
            postCheckpoint.distinctKeyCount == 0,
            postCheckpoint.generation == checkpointRoot.generation
        else { throw SegmentedManifestShadowError.invariantViolation }

        store = nil
        store = try await schema5IntegrationOpen(root: root)
        let postReopened = await store!.resourceProbeManifestShadowSnapshot()
        let postExact = postReopened.entries == expectedAfterCheckpoint.entries
            && postReopened.generation == expectedAfterCheckpoint.generation
        guard postExact else { throw SegmentedManifestShadowError.invariantViolation }

        let report = Schema5FileBlobStoreIntegrationReport(
            schemaVersion: 1,
            migrationGeneration: migrationGeneration,
            migrationEntryCount: beforeMigration.entries.count,
            repairedHeadCountAfterFirstOpen: repairedHeads,
            hotDeltaDistinctKeys: hotActive.distinctKeyCount,
            hotDeltaReopenExact: hotDeltaReopenExact,
            preCheckpointDistinctKeys: preCheckpoint.distinctKeyCount,
            preCheckpointRunCount: preCheckpointRoot.runs.count,
            checkpointGeneration: checkpointRoot.generation,
            checkpointRunCount: checkpointRoot.runs.count,
            checkpointRunRecords: checkpointRoot.runs[0].recordCount,
            postCheckpointDistinctKeys: postCheckpoint.distinctKeyCount,
            postCheckpointReopenExact: postExact,
            claims: .init(
                automaticMigration: false,
                backgroundCompaction: false,
                formalPerformance: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        _ = store
    }

    private static func schema5IntegrationOpen(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.open(root: root)
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    static func schema5IntegrationIdentities(
        prefix: String,
        count: Int
    ) throws -> [MigrationIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-fileblob-integration-v1",
                material: Data("\(prefix)-partition-\(index)".utf8)
            )
            let data = Data("\(prefix)-payload-\(index)".utf8)
            let digest = BlobDigest.sha256(of: data)
            return MigrationIdentity(
                key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
                partition: partition,
                digest: digest,
                data: data
            )
        }
    }
}
