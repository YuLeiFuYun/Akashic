import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum Schema5MigrationCrashPoint: String {
    case baseDurableRootOld = "base-durable-root-old"
    case rootPreRename = "root-pre-rename"
    case rootPostRename = "root-post-rename"
    case rootPostDirectorySync = "root-post-directory-sync"

    func matches(_ point: FileBlobStoreSegmentedMigrationSwitchPoint) -> Bool {
        switch (self, point) {
        case (.baseDurableRootOld, .afterBaseDurable):
            true
        case (.rootPreRename, .root(.afterFileSynced)):
            true
        case (.rootPostRename, .root(.afterRename)):
            true
        case (.rootPostDirectorySync, .root(.afterDirectorySynced)):
            true
        default:
            false
        }
    }
}

private struct Schema5MigrationCrashSeedReport: Codable {
    let schemaVersion: Int
    let schema4Generation: UInt64
    let activeDistinctKeys: Int
    let activeSequence: UInt64
    let diskSnapshotDiffersFromReplayedState: Bool
    let expectedEntryCount: Int
    let expectedStateCommitment: String
}

private struct Schema5MigrationCrashInspectReport: Codable {
    let schemaVersion: Int
    let authority: String
    let generation: UInt64
    let entryCount: Int
    let stateCommitment: String
    let activeSchema4DistinctKeys: Int
    let segmentedRunCount: Int
    let orphanSegmentCount: Int
    let oldReaderRejectedSchema5: Bool
}

extension SegmentedManifestShadowProbe {
    private static let schema5MigrationCrashExitCode: Int32 = 91

    static func schema5MigrationCrashSeed(arguments: [String]) async throws {
        let root = try schema5MigrationCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        let identities = try schema5MigrationIdentities(labels: ["a", "b", "c", "d"])
        let store = try await FileBlobStore.open(root: root)
        let publicationA = try await store.commit(
            data: identities[0].data,
            digest: identities[0].digest,
            partition: identities[0].partition
        )
        _ = try await store.commit(
            data: identities[1].data,
            digest: identities[1].digest,
            partition: identities[1].partition
        )
        _ = try await store.commit(
            data: identities[2].data,
            digest: identities[2].digest,
            partition: identities[2].partition
        )
        guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw Schema5MigrationProbeError.invalidFixture
        }
        _ = try await store.commit(
            data: identities[3].data,
            digest: identities[3].digest,
            partition: identities[3].partition
        )
        try await store.remove(
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
        let repairedA = try await store.commit(
            data: identities[0].data,
            digest: identities[0].digest,
            partition: identities[0].partition
        )
        guard repairedA.physicalID != publicationA.physicalID else {
            throw Schema5MigrationProbeError.invalidFixture
        }

        let current = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let diskData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let diskEntries = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(diskData)
        var replayed = diskEntries
        for mutation in active.mutations {
            if let entry = mutation.entry {
                replayed[mutation.key] = entry
            } else {
                replayed.removeValue(forKey: mutation.key)
            }
        }
        guard active.distinctKeyCount == 3,
            active.generation == current.generation,
            diskEntries != current.entries,
            replayed == current.entries
        else { throw Schema5MigrationProbeError.invalidFixture }
        let expected = schema5MigrationEntries(current.entries)
        try schema5MigrationCrashWriteJSON(
            Schema5MigrationCrashSeedReport(
                schemaVersion: 1,
                schema4Generation: current.generation,
                activeDistinctKeys: active.distinctKeyCount,
                activeSequence: active.activeSequence,
                diskSnapshotDiffersFromReplayedState: true,
                expectedEntryCount: expected.count,
                expectedStateCommitment:
                    try SegmentedManifestPrototypeV1.semanticStateCommitment(expected)
            )
        )
    }

    static func schema5MigrationCrash(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let crashPoint = Schema5MigrationCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let store = try await FileBlobStore.open(root: root)
        let current = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard active.distinctKeyCount == 3,
            active.generation == current.generation
        else { throw Schema5MigrationProbeError.invalidFixture }

        _ = try await store.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1(
            faultInjector: { switchPoint in
                if crashPoint.matches(switchPoint) {
                    Darwin._exit(schema5MigrationCrashExitCode)
                }
            }
        )
        Darwin._exit(92)
    }

    static func schema5MigrationCrashInspect(arguments: [String]) async throws {
        let root = try schema5MigrationCrashRoot(arguments)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["schemaVersion"] as? NSNumber
        else { throw SegmentedManifestShadowError.invalidFormat }
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let orphanCount = try schema5MigrationCrashSegmentCount(segmentDirectory)

        if version.intValue == 4 {
            let store = try await FileBlobStore.open(root: root)
            let current = await store.resourceProbeManifestShadowSnapshot()
            let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
            let state = schema5MigrationEntries(current.entries)
            try schema5MigrationCrashWriteJSON(
                Schema5MigrationCrashInspectReport(
                    schemaVersion: 1,
                    authority: "schema4",
                    generation: current.generation,
                    entryCount: state.count,
                    stateCommitment: try SegmentedManifestPrototypeV1.semanticStateCommitment(state),
                    activeSchema4DistinctKeys: active.distinctKeyCount,
                    segmentedRunCount: 0,
                    orphanSegmentCount: orphanCount,
                    oldReaderRejectedSchema5: false
                )
            )
            return
        }
        guard version.intValue == SegmentedManifestPrototypeV1.schemaVersion else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: manifestURL,
            segmentDirectory: segmentDirectory
        )
        let oldReaderRejected: Bool
        do {
            _ = try await FileBlobStore.open(root: root)
            oldReaderRejected = false
        } catch AkashicError.unsupportedSchema {
            oldReaderRejected = true
        }
        guard oldReaderRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try schema5MigrationCrashWriteJSON(
            Schema5MigrationCrashInspectReport(
                schemaVersion: 1,
                authority: "schema5",
                generation: segmentedRoot.generation,
                entryCount: recovered.count,
                stateCommitment: try SegmentedManifestPrototypeV1.semanticStateCommitment(recovered),
                activeSchema4DistinctKeys: 0,
                segmentedRunCount: segmentedRoot.runs.count,
                orphanSegmentCount: orphanCount,
                oldReaderRejectedSchema5: true
            )
        )
    }

    private static func schema5MigrationCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func schema5MigrationCrashSegmentCount(_ directory: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try BoundedDirectoryReader.names(in: directory, maximumCount: 256).count
    }

    private static func schema5MigrationCrashWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
