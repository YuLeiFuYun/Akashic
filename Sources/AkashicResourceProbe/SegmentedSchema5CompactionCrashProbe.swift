import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum Schema5CompactionCrashPoint: String {
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
}

private struct Schema5CompactionCrashSeedReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let baseFileName: String
    let runFileName: String
    let activeGeneration: UInt64
    let activeSequence: UInt64
    let activeDistinctKeys: Int
    let entryCount: Int
    let identityCommitment: String
    let segmentNames: [String]
}

private struct Schema5CompactionCrashInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let baseFileName: String
    let runNames: [String]
    let activeGeneration: UInt64
    let activeSequence: UInt64
    let activeDistinctKeys: Int
    let entryCount: Int
    let identityCommitment: String
    let segmentNames: [String]
}

extension SegmentedManifestShadowProbe {
    static func schema5CompactionCrashSeed(arguments: [String]) async throws {
        let root = try schema5CompactionCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        let store = try await schema5CompactionCrashOneRunStore(root: root)
        let activeIdentity = try schema5IntegrationIdentities(prefix: "compaction-crash-active", count: 1)[0]
        _ = try await store.commit(
            data: activeIdentity.data,
            digest: activeIdentity.digest,
            partition: activeIdentity.partition
        )
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let rootValue = try schema5CompactionCrashReadRoot(root)
        let names = try schema5CompactionCrashSegmentNames(root)
        guard rootValue.runs.count == 1,
            active.generation == rootValue.generation,
            active.activeSequence == 1,
            active.distinctKeyCount == 1
        else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5CompactionCrashWriteJSON(
            Schema5CompactionCrashSeedReport(
                schemaVersion: 1,
                generation: rootValue.generation,
                baseFileName: rootValue.base.fileName,
                runFileName: rootValue.runs[0].fileName,
                activeGeneration: active.generation,
                activeSequence: active.activeSequence,
                activeDistinctKeys: active.distinctKeyCount,
                entryCount: snapshot.entries.count,
                identityCommitment: try schema5IdentityCommitment(snapshot.entries),
                segmentNames: names
            )
        )
        _ = store
    }

    static func schema5CompactionCrash(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = Schema5CompactionCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let store = try await FileBlobStore.open(
            root: root,
            faultInjector: { observed in
                if observed == point.switchPoint { Darwin._exit(91) }
            }
        )
        _ = try await store.resourceProbeCompactSegmentedManifestV1()
        Darwin._exit(92)
    }

    static func schema5CompactionCrashInspect(arguments: [String]) async throws {
        let root = try schema5CompactionCrashRoot(arguments)
        let store = try await schema5CompactionCrashOpen(root: root)
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let rootValue = try schema5CompactionCrashReadRoot(root)
        try schema5CompactionCrashWriteJSON(
            Schema5CompactionCrashInspectReport(
                schemaVersion: 1,
                generation: rootValue.generation,
                baseFileName: rootValue.base.fileName,
                runNames: rootValue.runs.map(\.fileName),
                activeGeneration: active.generation,
                activeSequence: active.activeSequence,
                activeDistinctKeys: active.distinctKeyCount,
                entryCount: snapshot.entries.count,
                identityCommitment: try schema5IdentityCommitment(snapshot.entries),
                segmentNames: try schema5CompactionCrashSegmentNames(root)
            )
        )
        _ = store
    }

    private static func schema5CompactionCrashOneRunStore(root: URL) async throws -> FileBlobStore {
        let store = try await schema5PrepareCheckpointSeed(root: root).store
        let target = try schema5IntegrationIdentities(prefix: "hot", count: 512)[511]
        _ = try await store.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        let rootValue = try schema5CompactionCrashReadRoot(root)
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard rootValue.runs.count == 1,
            rootValue.runs[0].recordCount == 512,
            active.distinctKeyCount == 0
        else { throw SegmentedManifestShadowError.invariantViolation }
        return store
    }

    private static func schema5CompactionCrashOpen(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do { return try await FileBlobStore.open(root: root) }
            catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.transactionConflict {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    private static func schema5CompactionCrashReadRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func schema5CompactionCrashSegmentNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        return try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).sorted()
    }

    private static func schema5CompactionCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func schema5CompactionCrashWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
