import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum Schema5CheckpointCrashPoint: String {
    case manifestDataWritten = "manifest-data-written"
    case manifestFileSynced = "manifest-file-synced"
    case manifestRenamed = "manifest-renamed"
    case manifestDirectorySynced = "manifest-directory-synced"

    var switchPoint: FileBlobStoreSwitchPoint {
        switch self {
        case .manifestDataWritten: .afterManifestDataWritten
        case .manifestFileSynced: .afterManifestFileSynced
        case .manifestRenamed: .afterManifestRenamed
        case .manifestDirectorySynced: .afterManifestDirectorySynced
        }
    }

    var expectsNewAuthority: Bool {
        self == .manifestRenamed || self == .manifestDirectorySynced
    }
}

private struct Schema5CheckpointCrashSeedReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let activeDistinctKeys: Int
    let oldEntryCount: Int
    let oldIdentityCommitment: String
}

private struct Schema5CheckpointCrashPlanReport: Codable {
    let schemaVersion: Int
    let newEntryCount: Int
    let newIdentityCommitment: String
    let stagedPhysicalID: String
}

private struct Schema5CheckpointCrashInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let runRecordCount: Int
    let activeDistinctKeys: Int
    let entryCount: Int
    let identityCommitment: String
    let segmentFileCount: Int
}

private struct Schema5PhaseAliasCheckpointCrashSeedReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let activeDistinctKeys: Int
    let entryCount: Int
    let oldIdentityCommitment: String
    let newIdentityCommitment: String
    let targetKey: String
    let targetPhysicalID: String
}

private struct Schema5PhaseAliasCheckpointCrashInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let runRecordCount: Int
    let activeDistinctKeys: Int
    let entryCount: Int
    let identityCommitment: String
    let segmentFileCount: Int
    let targetPresentInAuthority: Bool
    let oldTargetPhysicalFileExists: Bool
}

private struct Schema5PhaseAliasCheckpointCrashIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    var key: String {
        FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
    }
}

extension SegmentedManifestShadowProbe {
    static func schema5CheckpointCrashSeed(arguments: [String]) async throws {
        let root = try schema5CheckpointCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        let prepared = try await schema5PrepareCheckpointSeed(root: root)
        let snapshot = await prepared.store.resourceProbeManifestShadowSnapshot()
        let active = try await prepared.store.resourceProbeDirectoryHeadEpochSnapshot()
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        guard segmentedRoot.generation == snapshot.generation,
            segmentedRoot.runs.isEmpty,
            active.distinctKeyCount == 511
        else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5CheckpointCrashWriteJSON(
            Schema5CheckpointCrashSeedReport(
                schemaVersion: 1,
                generation: segmentedRoot.generation,
                runCount: segmentedRoot.runs.count,
                activeDistinctKeys: active.distinctKeyCount,
                oldEntryCount: snapshot.entries.count,
                oldIdentityCommitment: try schema5IdentityCommitment(snapshot.entries)
            ),
            to: FileHandle.standardOutput
        )
        _ = prepared.store
    }

    static func schema5CheckpointCrash(arguments: [String]) async throws {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--point",
            arguments[4] == "--plan",
            let point = Schema5CheckpointCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let planURL = URL(fileURLWithPath: arguments[5], isDirectory: false)
        let target = try schema5IntegrationIdentities(prefix: "hot", count: 512)[511]
        let store = try await FileBlobStore.open(
            root: root,
            faultInjector: { observed in
                if observed == point.switchPoint { Darwin._exit(91) }
            }
        )
        let before = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard active.distinctKeyCount == 511 else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let stage = try await store.stage(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        guard let pending = await store.resourceProbePendingStageEntry(stage) else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var planned = before.entries
        planned[target.key] = pending
        let plan = Schema5CheckpointCrashPlanReport(
            schemaVersion: 1,
            newEntryCount: planned.count,
            newIdentityCommitment: try schema5IdentityCommitment(planned),
            stagedPhysicalID: pending.physicalID.rawValue.uuidString.lowercased()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFileWriter.writeReplacing(try encoder.encode(plan), to: planURL)
        _ = try await store.publish(stage)
        Darwin._exit(92)
    }

    static func schema5CheckpointCrashInspect(arguments: [String]) async throws {
        let root = try schema5CheckpointCrashRoot(arguments)
        let store = try await schema5CheckpointOpen(root: root)
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let segmentCount = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: 256
        ).count
        try schema5CheckpointCrashWriteJSON(
            Schema5CheckpointCrashInspectReport(
                schemaVersion: 1,
                generation: segmentedRoot.generation,
                runCount: segmentedRoot.runs.count,
                runRecordCount: segmentedRoot.runs.first?.recordCount ?? 0,
                activeDistinctKeys: active.distinctKeyCount,
                entryCount: snapshot.entries.count,
                identityCommitment: try schema5IdentityCommitment(snapshot.entries),
                segmentFileCount: segmentCount
            ),
            to: FileHandle.standardOutput
        )
        _ = store
    }

    static func schema5PhaseAliasCheckpointCrashSeed(arguments: [String]) async throws {
        let root = try schema5CheckpointCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let identities = try schema5PhaseAliasCheckpointCrashIdentities(count: 1_022)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()

        // Reproduce the higher-phase precondition from the phase-aliasing witness: the same 512
        // logical keys are rewritten twice in two global rounds, leaving two post-checkpoint keys.
        for index in Array(0..<512) + Array(0..<512) {
            let identity = identities[index]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }

        // Advance the identical future trace by 509 unique keys. Starting from phase 2 this leaves
        // exactly 511 active distinct keys, so removing the 510th future key is the checkpoint edge.
        for index in 512..<1_021 {
            let identity = identities[index]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }

        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let active = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let target = identities[1_021]
        guard active.distinctKeyCount == 511,
            segmentedRoot.runs.count == 2,
            let targetEntry = snapshot.entries[target.key]
        else { throw SegmentedManifestShadowError.invariantViolation }
        var withoutTarget = snapshot.entries
        withoutTarget.removeValue(forKey: target.key)
        try schema5CheckpointCrashWriteJSON(
            Schema5PhaseAliasCheckpointCrashSeedReport(
                schemaVersion: 1,
                generation: segmentedRoot.generation,
                runCount: segmentedRoot.runs.count,
                activeDistinctKeys: active.distinctKeyCount,
                entryCount: snapshot.entries.count,
                oldIdentityCommitment: try schema5IdentityCommitment(snapshot.entries),
                newIdentityCommitment: try schema5IdentityCommitment(withoutTarget),
                targetKey: target.key,
                targetPhysicalID: targetEntry.physicalID.rawValue.uuidString.lowercased()
            ),
            to: FileHandle.standardOutput
        )
        store = nil
    }

    static func schema5PhaseAliasCheckpointCrash(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = Schema5CheckpointCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let target = try schema5PhaseAliasCheckpointCrashIdentities(count: 1_022)[1_021]
        let store = try await FileBlobStore.open(
            root: root,
            faultInjector: { observed in
                if observed == point.switchPoint { Darwin._exit(91) }
            }
        )
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        guard active.distinctKeyCount == 511,
            segmentedRoot.runs.count == 2,
            await store.physicalID(digest: target.digest, partition: target.partition) != nil
        else { throw SegmentedManifestShadowError.invariantViolation }
        try await store.remove(digest: target.digest, partition: target.partition)
        Darwin._exit(92)
    }

    static func schema5PhaseAliasCheckpointCrashInspect(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--old-physical-id",
            let oldPhysicalUUID = UUID(uuidString: arguments[3]),
            oldPhysicalUUID.uuidString.lowercased() == arguments[3]
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let target = try schema5PhaseAliasCheckpointCrashIdentities(count: 1_022)[1_021]
        let store = try await schema5CheckpointOpen(root: root)
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let segmentCount = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: 256
        ).count
        let oldPhysicalURL = root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(arguments[3], isDirectory: false)
        try schema5CheckpointCrashWriteJSON(
            Schema5PhaseAliasCheckpointCrashInspectReport(
                schemaVersion: 1,
                generation: segmentedRoot.generation,
                runCount: segmentedRoot.runs.count,
                runRecordCount: segmentedRoot.runs.last?.recordCount ?? 0,
                activeDistinctKeys: active.distinctKeyCount,
                entryCount: snapshot.entries.count,
                identityCommitment: try schema5IdentityCommitment(snapshot.entries),
                segmentFileCount: segmentCount,
                targetPresentInAuthority: snapshot.entries[target.key] != nil,
                oldTargetPhysicalFileExists: FileManager.default.fileExists(
                    atPath: oldPhysicalURL.path
                )
            ),
            to: FileHandle.standardOutput
        )
        _ = store
    }

    static func schema5PrepareCheckpointSeed(
        root: URL
    ) async throws -> (store: FileBlobStore, generation: UInt64) {
        let base = try schema5IntegrationIdentities(prefix: "base", count: 3)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        _ = try await store!.commit(
            data: base[0].data,
            digest: base[0].digest,
            partition: base[0].partition
        )
        _ = try await store!.commit(
            data: base[1].data,
            digest: base[1].digest,
            partition: base[1].partition
        )
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.commit(
            data: base[2].data,
            digest: base[2].digest,
            partition: base[2].partition
        )
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        let generation = migration.root.generation
        store = nil
        store = try await schema5CheckpointOpen(root: root)

        let hot = try schema5IntegrationIdentities(prefix: "hot", count: 512)
        for index in 0...510 {
            _ = try await store!.commit(
                data: hot[index].data,
                digest: hot[index].digest,
                partition: hot[index].partition
            )
        }
        return (store!, generation)
    }

    private static func schema5CheckpointOpen(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do { return try await FileBlobStore.open(root: root) }
            catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    static func schema5IdentityCommitment(
        _ entries: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> String {
        let canonical = Dictionary(uniqueKeysWithValues: entries.map { key, entry in
            (
                key,
                SegmentedManifestEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: 0)
                )
            )
        })
        return try SegmentedManifestPrototypeV1.semanticStateCommitment(canonical)
    }

    private static func schema5PhaseAliasCheckpointCrashIdentities(
        count: Int
    ) throws -> [Schema5PhaseAliasCheckpointCrashIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-epoch-operation-v1",
                material: Data("phase-partition-\(index)".utf8)
            )
            let data = Data("phase-payload-\(index)".utf8)
            return .init(
                partition: partition,
                digest: BlobDigest.sha256(of: data),
                data: data
            )
        }
    }

    private static func schema5CheckpointCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func schema5CheckpointCrashWriteJSON<T: Encodable>(
        _ value: T,
        to handle: FileHandle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        handle.write(try encoder.encode(value))
        handle.write(Data([0x0A]))
    }
}
