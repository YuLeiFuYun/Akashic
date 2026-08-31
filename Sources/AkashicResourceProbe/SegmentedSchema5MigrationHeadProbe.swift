import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum Schema5MigrationHeadCrashPoint: String {
    case noNewHead = "no-new-head"
    case oneNewHead = "one-new-head"
    case bothNewHeads = "both-new-heads"
}

private struct Schema5MigrationHeadInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let stateCommitment: String
    let headCountBeforeRepair: Int
    let headCountAfterRepair: Int
    let oldReaderRejectedSchema5: Bool
}

private struct Schema5FutureHeadControlReport: Codable {
    let schemaVersion: Int
    let schema4Generation: UInt64
    let futureGeneration: UInt64
    let futureHeadCount: Int
    let oldReaderRejectedFutureHead: Bool
}

extension SegmentedManifestShadowProbe {
    static func schema5MigrationComplete(arguments: [String]) async throws {
        let root = try schema5MigrationCrashRootForHead(arguments)
        let store = try await FileBlobStore.open(root: root)
        let current = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard active.distinctKeyCount == 3,
            active.generation == current.generation
        else { throw Schema5MigrationProbeError.invalidFixture }
        _ = try await store.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
    }

    static func schema5MigrationHeadCrash(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = Schema5MigrationHeadCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        switch point {
        case .noNewHead:
            Darwin._exit(91)
        case .oneNewHead:
            try SegmentedManifestDirectoryHeadPrototypeV1.writeEmptyHeadSlot(
                generation: segmentedRoot.generation,
                slot: 0,
                blobsDirectory: blobs
            )
            Darwin._exit(91)
        case .bothNewHeads:
            try SegmentedManifestDirectoryHeadPrototypeV1.writeEmptyHeadSlot(
                generation: segmentedRoot.generation,
                slot: 0,
                blobsDirectory: blobs
            )
            try SegmentedManifestDirectoryHeadPrototypeV1.writeEmptyHeadSlot(
                generation: segmentedRoot.generation,
                slot: 1,
                blobsDirectory: blobs
            )
            Darwin._exit(91)
        }
    }

    static func schema5MigrationHeadInspect(arguments: [String]) async throws {
        let root = try schema5MigrationCrashRootForHead(arguments)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let state = try SegmentedManifestPrototypeV1.recover(
            rootURL: manifestURL,
            segmentDirectory: segmentDirectory
        )
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let before = try SegmentedManifestDirectoryHeadPrototypeV1.currentHeadCount(
            generation: segmentedRoot.generation,
            blobsDirectory: blobs
        )
        let after = try SegmentedManifestDirectoryHeadPrototypeV1.repairEmptyGeneration(
            generation: segmentedRoot.generation,
            blobsDirectory: blobs
        )
        guard after == 2 else { throw SegmentedManifestShadowError.invariantViolation }
        let oldReaderRejected: Bool
        do {
            _ = try await FileBlobStore.open(root: root)
            oldReaderRejected = false
        } catch AkashicError.unsupportedSchema {
            oldReaderRejected = true
        }
        guard oldReaderRejected else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5MigrationHeadWriteJSON(
            Schema5MigrationHeadInspectReport(
                schemaVersion: 1,
                generation: segmentedRoot.generation,
                stateCommitment: try SegmentedManifestPrototypeV1.semanticStateCommitment(state),
                headCountBeforeRepair: before,
                headCountAfterRepair: after,
                oldReaderRejectedSchema5: true
            )
        )
    }

    static func schema5MigrationFutureHeadControl(arguments: [String]) async throws {
        let root = try schema5MigrationCrashRootForHead(arguments)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        let current = await store!.resourceProbeManifestShadowSnapshot()
        let futureGeneration = current.generation + 1
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        try SegmentedManifestDirectoryHeadPrototypeV1.writeEmptyHeadSlot(
            generation: futureGeneration,
            slot: 0,
            blobsDirectory: blobs
        )
        let futureCount = try SegmentedManifestDirectoryHeadPrototypeV1.currentHeadCount(
            generation: futureGeneration,
            blobsDirectory: blobs
        )
        store = nil
        for _ in 0..<250 {
            do {
                _ = try await FileBlobStore.open(root: root)
                try schema5MigrationHeadWriteJSON(
                    Schema5FutureHeadControlReport(
                        schemaVersion: 1,
                        schema4Generation: current.generation,
                        futureGeneration: futureGeneration,
                        futureHeadCount: futureCount,
                        oldReaderRejectedFutureHead: false
                    )
                )
                return
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.invalidManifest {
                try schema5MigrationHeadWriteJSON(
                    Schema5FutureHeadControlReport(
                        schemaVersion: 1,
                        schema4Generation: current.generation,
                        futureGeneration: futureGeneration,
                        futureHeadCount: futureCount,
                        oldReaderRejectedFutureHead: true
                    )
                )
                return
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    private static func schema5MigrationCrashRootForHead(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func schema5MigrationHeadWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
