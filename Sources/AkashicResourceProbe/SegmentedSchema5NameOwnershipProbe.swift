import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5NameOwnershipReport: Codable {
    let schemaVersion: Int
    let genericBaseAcceptedByPackageCodec: Bool
    let genericRunAcceptedByPackageCodec: Bool
    let genericBaseRejectedByPublicOpen: Bool
    let genericRunRejectedByPublicOpen: Bool
    let productionNamesAcceptedByPublicOpen: Bool
    let foreignUnreferencedPreserved: Bool
    let claims: Claims

    struct Claims: Codable {
        let sameUserRaceProtection: Bool
        let productionFormatAdopted: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func schema5NameOwnershipControl(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        let genericBase = try await schema5NameGenericBaseCase(
            root: root.appendingPathComponent("generic-base", isDirectory: true)
        )
        let genericRun = try await schema5NameGenericRunCase(
            root: root.appendingPathComponent("generic-run", isDirectory: true)
        )
        let production = try await schema5NameProductionControl(
            root: root.appendingPathComponent("production", isDirectory: true)
        )

        let report = Schema5NameOwnershipReport(
            schemaVersion: 1,
            genericBaseAcceptedByPackageCodec: genericBase.codecAccepted,
            genericRunAcceptedByPackageCodec: genericRun.codecAccepted,
            genericBaseRejectedByPublicOpen: genericBase.publicRejected,
            genericRunRejectedByPublicOpen: genericRun.publicRejected,
            productionNamesAcceptedByPublicOpen: production.accepted,
            foreignUnreferencedPreserved: production.foreignPreserved,
            claims: .init(
                sameUserRaceProtection: false,
                productionFormatAdopted: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5NameGenericBaseCase(
        root: URL
    ) async throws -> (codecAccepted: Bool, publicRejected: Bool) {
        let fixture = try schema5NamePrepareDirectories(root: root)
        let data = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 3,
            entries: [:]
        )
        let genericName = "base-foreign.json"
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            data,
            entryCount: 0,
            fileName: genericName,
            directory: fixture.segments
        )
        let rootValue = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 3,
            base: base,
            runs: []
        )
        try SegmentedManifestPrototypeV1.writeRoot(rootValue, to: fixture.manifest)
        return (
            codecAccepted: base.fileName == genericName,
            publicRejected: await schema5NamePublicOpenRejectsInvalidManifest(root: root)
        )
    }

    private static func schema5NameGenericRunCase(
        root: URL
    ) async throws -> (codecAccepted: Bool, publicRejected: Bool) {
        let fixture = try schema5NamePrepareDirectories(root: root)
        let data = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 3,
            entries: [:]
        )
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            data,
            entryCount: 0,
            fileName: "base-migration-\(UUID().uuidString.lowercased()).json",
            directory: fixture.segments
        )
        let key = try schema5IntegrationIdentities(prefix: "name-run", count: 1)[0].key
        let runName = "run-foreign.seg"
        let run = try SegmentedManifestPrototypeV1.writeRun(
            [.tombstone(key: key)],
            fileName: runName,
            directory: fixture.segments
        )
        let rootValue = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 3,
            base: base,
            runs: [run]
        )
        try SegmentedManifestPrototypeV1.writeRoot(rootValue, to: fixture.manifest)
        return (
            codecAccepted: run.fileName == runName,
            publicRejected: await schema5NamePublicOpenRejectsInvalidManifest(root: root)
        )
    }

    private static func schema5NameProductionControl(
        root: URL
    ) async throws -> (accepted: Bool, foreignPreserved: Bool) {
        let fixture = try schema5NamePrepareDirectories(root: root)
        let data = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 3,
            entries: [:]
        )
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            data,
            entryCount: 0,
            fileName: "base-migration-\(UUID().uuidString.lowercased()).json",
            directory: fixture.segments
        )
        let key = try schema5IntegrationIdentities(prefix: "name-production", count: 1)[0].key
        let run = try SegmentedManifestPrototypeV1.writeRun(
            [.tombstone(key: key)],
            fileName: "run-g3-\(UUID().uuidString.lowercased()).seg",
            directory: fixture.segments
        )
        let rootValue = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 3,
            base: base,
            runs: [run]
        )
        try SegmentedManifestPrototypeV1.writeRoot(rootValue, to: fixture.manifest)
        let foreign = fixture.segments.appendingPathComponent("foreign.keep", isDirectory: false)
        try DurableFileWriter.writeReplacing(Data("foreign".utf8), to: foreign)

        var store: FileBlobStore?
        do {
            store = try await FileBlobStore.open(root: root)
            let snapshot = await store!.resourceProbeManifestShadowSnapshot()
            let accepted = snapshot.entries.isEmpty
            store = nil
            return (
                accepted: accepted,
                foreignPreserved: FileManager.default.fileExists(atPath: foreign.path)
            )
        } catch {
            store = nil
            return (accepted: false, foreignPreserved: FileManager.default.fileExists(atPath: foreign.path))
        }
    }

    private static func schema5NamePrepareDirectories(
        root: URL
    ) throws -> (segments: URL, manifest: URL) {
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(
            root.appendingPathComponent("blobs", isDirectory: true)
        )
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(segments)
        return (
            segments: segments,
            manifest: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func schema5NamePublicOpenRejectsInvalidManifest(root: URL) async -> Bool {
        do {
            var store: FileBlobStore? = try await FileBlobStore.open(root: root)
            _ = await store!.resourceProbeManifestShadowSnapshot()
            store = nil
            return false
        } catch AkashicError.invalidManifest {
            return true
        } catch {
            return false
        }
    }
}
