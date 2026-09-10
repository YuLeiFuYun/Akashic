import AkashicCore
import AkashicDisk
import Foundation

enum Schema5LocalityProfile: String {
    case v1JSON = "v1-json"
    case v2Binary = "v2-binary"
    case v3CompactBinary = "v3-binary-compact"
    case v4Compound = "v4-compound"
}

extension SegmentedSchema5LocalityIOProbe {
    static func openProfile(
        _ profile: Schema5LocalityProfile,
        root: URL,
        limits: FileBlobStoreLimits,
        operations: FileBlobStoreDirectoryHeadOperations
    ) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                switch profile {
                case .v1JSON:
                    return try await FileBlobStore.open(
                        root: root,
                        limits: limits,
                        faultInjector: { _ in },
                        directoryHeadOperations: operations
                    )
                case .v2Binary:
                    return try await FileBlobStore.openSegmentedV2Candidate(
                        root: root,
                        limits: limits,
                        directoryHeadOperations: operations
                    )
                case .v3CompactBinary:
                    return try await FileBlobStore.openSegmentedV3Candidate(
                        root: root,
                        limits: limits,
                        directoryHeadOperations: operations
                    )
                case .v4Compound:
                    return try await FileBlobStore.openSegmentedV4Candidate(
                        root: root,
                        limits: limits,
                        directoryHeadOperations: operations
                    )
                }
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.transactionConflict {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw ProbeError.resourceSampleFailed
    }

    static func transitionProfile(
        _ profile: Schema5LocalityProfile,
        root: URL,
        limits: FileBlobStoreLimits,
        migration: FileBlobStoreSegmentedMigrationPrototypeResult
    ) async throws {
        guard profile != .v1JSON else { return }
        let rootURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = migration.segmentDirectory

        switch profile {
        case .v1JSON:
            return
        case .v2Binary:
            let transition = try SegmentedManifestBinaryBaseTransitionV2.prepare(
                frozenRoot: migration.root,
                segmentDirectory: segmentDirectory,
                candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
            )
            try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: transition.root,
                directory: segmentDirectory
            )
        case .v3CompactBinary, .v4Compound:
            let transition = try SegmentedManifestBinaryBaseTransitionV3.prepare(
                frozenRoot: migration.root,
                segmentDirectory: segmentDirectory,
                candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
            )
            try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
            _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
                root: transition.root,
                directory: segmentDirectory
            )
            if profile == .v4Compound {
                var v3: FileBlobStore? = try await openProfile(
                    .v3CompactBinary,
                    root: root,
                    limits: limits,
                    operations: .system
                )
                _ = try await v3!.resourceProbeMigrateSegmentedV3ToCompoundV4()
                v3 = nil
            }
        }
    }

    static func parseArguments(
        _ arguments: [String]
    ) throws -> (root: URL, profile: Schema5LocalityProfile) {
        guard arguments.count == 2 || arguments.count == 4,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let profile: Schema5LocalityProfile
        if arguments.count == 2 {
            profile = .v1JSON
        } else {
            guard arguments[2] == "--profile",
                let parsed = Schema5LocalityProfile(rawValue: arguments[3])
            else { throw ProbeError.invalidArguments }
            profile = parsed
        }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            profile
        )
    }
}
