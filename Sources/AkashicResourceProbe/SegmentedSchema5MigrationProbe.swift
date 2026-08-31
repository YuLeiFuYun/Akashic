import AkashicCore
import AkashicDisk
import Foundation

enum Schema5MigrationProbeError: Error {
    case invalidArguments
    case invalidFixture
    case writerLeaseDidNotRelease
}

private struct Schema5MigrationProbeReport: Codable {
    struct Claims: Codable {
        let automaticMigration: Bool
        let publicOpenSupportsSchema5: Bool
        let processCrash: Bool
        let powerLoss: Bool
        let productionFormat: Bool
    }

    let schemaVersion: Int
    let schema4Generation: UInt64
    let schema4DiskSnapshotEntries: Int
    let fullyReplayedEntries: Int
    let activeDistinctKeys: Int
    let activeSequence: UInt64
    let diskSnapshotDiffersFromReplayedState: Bool
    let activeEpochReplaysToCurrentState: Bool
    let physicalRepairObserved: Bool
    let removeObserved: Bool
    let createObserved: Bool
    let segmentedGeneration: UInt64
    let segmentedBaseRecords: Int
    let segmentedRuns: Int
    let exactSegmentedRecovery: Bool
    let oldReaderRejectedSchema5: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    struct MigrationIdentity {
        let key: String
        let partition: CachePartitionID
        let digest: BlobDigest
        let data: Data
    }

    static func schema5MigrationShadow(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw Schema5MigrationProbeError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let identities = try schema5MigrationIdentities(labels: ["a", "b", "c", "d"])

        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
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
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw Schema5MigrationProbeError.invalidFixture
        }
        let schema4Base = await store!.resourceProbeManifestShadowSnapshot()

        _ = try await store!.commit(
            data: identities[3].data,
            digest: identities[3].digest,
            partition: identities[3].partition
        )
        try await store!.remove(
            digest: identities[1].digest,
            partition: identities[1].partition
        )
        let oldAURL = root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(
                publicationA.physicalID.rawValue.uuidString.lowercased(),
                isDirectory: false
            )
        try Data(repeating: 0x6d, count: identities[0].data.count).write(to: oldAURL)
        let repairedA = try await store!.commit(
            data: identities[0].data,
            digest: identities[0].digest,
            partition: identities[0].partition
        )
        guard repairedA.physicalID != publicationA.physicalID else {
            throw Schema5MigrationProbeError.invalidFixture
        }

        let current = await store!.resourceProbeManifestShadowSnapshot()
        let active = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        guard active.distinctKeyCount > 0,
            active.generation == current.generation,
            active.generation == schema4Base.generation
        else { throw Schema5MigrationProbeError.invalidFixture }

        let diskManifestData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let diskEntries = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(diskManifestData)
        var replayedDisk = diskEntries
        for mutation in active.mutations {
            if let entry = mutation.entry {
                replayedDisk[mutation.key] = entry
            } else {
                replayedDisk.removeValue(forKey: mutation.key)
            }
        }
        let diskDiffers = diskEntries != current.entries
        let epochReplays = replayedDisk == current.entries
        guard diskDiffers, epochReplays else {
            throw Schema5MigrationProbeError.invalidFixture
        }

        let physicalRepairObserved = current.entries[identities[0].key]?.physicalID == repairedA.physicalID
            && repairedA.physicalID != publicationA.physicalID
        let removeObserved = diskEntries[identities[1].key] != nil
            && current.entries[identities[1].key] == nil
        let createObserved = diskEntries[identities[3].key] == nil
            && current.entries[identities[3].key] != nil
        guard physicalRepairObserved, removeObserved, createObserved else {
            throw Schema5MigrationProbeError.invalidFixture
        }

        let expected = schema5MigrationEntries(current.entries)
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        guard migration.activeSchema4DistinctKeys == active.distinctKeyCount,
            migration.root.generation == current.generation + 1,
            migration.root.base.recordCount == current.entries.count,
            migration.root.runs.isEmpty
        else { throw Schema5MigrationProbeError.invalidFixture }
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: root.appendingPathComponent("manifest.json", isDirectory: false),
            segmentDirectory: migration.segmentDirectory
        )
        let exactRecovery = recovered == expected
        guard exactRecovery else { throw Schema5MigrationProbeError.invalidFixture }

        store = nil
        let oldReaderRejected = try await schema5WaitForOldReaderRejection(root: root)
        guard oldReaderRejected else { throw Schema5MigrationProbeError.invalidFixture }

        let report = Schema5MigrationProbeReport(
            schemaVersion: 1,
            schema4Generation: current.generation,
            schema4DiskSnapshotEntries: diskEntries.count,
            fullyReplayedEntries: current.entries.count,
            activeDistinctKeys: active.distinctKeyCount,
            activeSequence: active.activeSequence,
            diskSnapshotDiffersFromReplayedState: diskDiffers,
            activeEpochReplaysToCurrentState: epochReplays,
            physicalRepairObserved: physicalRepairObserved,
            removeObserved: removeObserved,
            createObserved: createObserved,
            segmentedGeneration: migration.root.generation,
            segmentedBaseRecords: migration.root.base.recordCount,
            segmentedRuns: migration.root.runs.count,
            exactSegmentedRecovery: exactRecovery,
            oldReaderRejectedSchema5: oldReaderRejected,
            claims: .init(
                automaticMigration: false,
                publicOpenSupportsSchema5: false,
                processCrash: false,
                powerLoss: false,
                productionFormat: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func schema5MigrationEntries(
        _ source: [String: FileBlobStoreRecordShadowEntry]
    ) -> [String: SegmentedManifestEntry] {
        source.mapValues { entry in
            SegmentedManifestEntry(
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: entry.digest,
                    partition: entry.partition
                ),
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }

    static func schema5MigrationIdentities(
        labels: [String]
    ) throws -> [MigrationIdentity] {
        try labels.map { label in
            let partition = try CachePartitionID.derive(
                domain: "schema5-migration-shadow-v1",
                material: Data("partition-\(label)".utf8)
            )
            let data = Data(
                "schema5-migration-payload-\(label)-\(String(repeating: label, count: 13))".utf8
            )
            let digest = BlobDigest.sha256(of: data)
            return MigrationIdentity(
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

    private static func schema5WaitForOldReaderRejection(root: URL) async throws -> Bool {
        for _ in 0..<250 {
            do {
                _ = try await FileBlobStore.open(root: root)
                return false
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.unsupportedSchema {
                return true
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }
}
