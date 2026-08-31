import AkashicCore
import AkashicDisk
import Foundation

private struct SegmentedV3RecoveryCleanupReady: Codable {
    let schemaVersion: Int
    let pid: Int32
    let profile: String
    let baseKind: String
    let segmentDirectoryEntryCount: Int
}

private struct SegmentedV3RecoveryCleanupCompleted: Codable {
    let schemaVersion: Int
    let profile: String
    let baseKind: String
    let activeEntryCount: Int
    let segmentDirectoryEntryCount: Int
}

extension SegmentedManifestShadowProbe {
    static func schema5V3RecoveryCleanupOpen(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootPath = values["--root"],
            let readyPath = values["--ready"],
            let completedPath = values["--completed"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let ready = URL(fileURLWithPath: readyPath, isDirectory: false)
        let completed = URL(fileURLWithPath: completedPath, isDirectory: false)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard initialRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            initialRoot.base.kind == .baseBinaryV2
        else { throw SegmentedManifestShadowError.invariantViolation }

        try schema5V3RecoveryCleanupWriteJSON(
            SegmentedV3RecoveryCleanupReady(
                schemaVersion: 1,
                pid: ProcessInfo.processInfo.processIdentifier,
                profile: initialRoot.profile,
                baseKind: initialRoot.base.kind.rawValue,
                segmentDirectoryEntryCount: try BoundedDirectoryReader.names(
                    in: segmentDirectory,
                    maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
                ).count
            ),
            to: ready
        )

        let store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        let recoveredRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard recoveredRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            recoveredRoot.base.kind == .baseBinaryV2
        else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5V3RecoveryCleanupWriteJSON(
            SegmentedV3RecoveryCleanupCompleted(
                schemaVersion: 1,
                profile: recoveredRoot.profile,
                baseKind: recoveredRoot.base.kind.rawValue,
                activeEntryCount: snapshot.entries.count,
                segmentDirectoryEntryCount: try BoundedDirectoryReader.names(
                    in: segmentDirectory,
                    maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
                ).count
            ),
            to: completed
        )
        _ = store
    }

    private static func schema5V3RecoveryCleanupWriteJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value) + Data([0x0A])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try DurableFileWriter.writeReplacing(data, to: url)
    }
}
