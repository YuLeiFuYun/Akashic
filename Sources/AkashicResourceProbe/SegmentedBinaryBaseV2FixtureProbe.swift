import AkashicCore
import AkashicDisk
import Foundation

private struct BinaryBaseV2FixtureReport: Codable {
    let schemaVersion: Int
    let rootProfile: String
    let baseKind: String
    let baseFileName: String
    let rootRecoveredExact: Bool
    let entryCount: Int
    let claims: Claims

    struct Claims: Codable {
        let researchOnly: Bool
        let fileBlobStoreIntegration: Bool
        let automaticMigration: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func binaryBaseV2Seed(arguments: [String]) throws {
        guard arguments.count == 1 else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[0], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw SegmentedManifestShadowError.invalidArguments
        }

        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(
            root.appendingPathComponent("blobs", isDirectory: true)
        )
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(segments)

        let state: [String: SegmentedManifestEntry] = [:]
        let baseName = "base-binary-\(UUID().uuidString.lowercased()).akb"
        let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
            state,
            fileName: baseName,
            directory: segments
        )
        let segmentedRoot = try SegmentedManifestPrototypeV1.makeRootV2(
            generation: 1,
            base: base,
            runs: []
        )
        let rootURL = root.appendingPathComponent("manifest.json")
        try SegmentedManifestPrototypeV1.writeRoot(segmentedRoot, to: rootURL)
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: rootURL,
            segmentDirectory: segments
        )
        guard recovered == state else { throw SegmentedManifestShadowError.invariantViolation }

        let report = BinaryBaseV2FixtureReport(
            schemaVersion: 1,
            rootProfile: segmentedRoot.profile,
            baseKind: base.kind.rawValue,
            baseFileName: base.fileName,
            rootRecoveredExact: true,
            entryCount: recovered.count,
            claims: .init(
                researchOnly: true,
                fileBlobStoreIntegration: false,
                automaticMigration: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
