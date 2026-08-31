import AkashicCore
import Foundation

package enum FileBlobStoreSegmentedMigrationSwitchPoint: Sendable {
    case afterBaseDurable
    case root(DurableFileWriteSwitchPoint)
}

package typealias FileBlobStoreSegmentedMigrationFaultInjector =
    @Sendable (FileBlobStoreSegmentedMigrationSwitchPoint) throws -> Void

package struct FileBlobStoreSegmentedMigrationPrototypeResult: Sendable {
    package let root: SegmentedManifestRootV1
    package let segmentDirectory: URL
    package let activeSchema4DistinctKeys: Int

    package init(
        root: SegmentedManifestRootV1,
        segmentDirectory: URL,
        activeSchema4DistinctKeys: Int
    ) {
        self.root = root
        self.segmentDirectory = segmentDirectory
        self.activeSchema4DistinctKeys = activeSchema4DistinctKeys
    }
}

extension FileBlobStore {
    package static let segmentedManifestPrototypeDirectoryName = ".manifest-segments-v1"

    /// Explicit research migration from a fully replayed schema4 actor state to the package-only
    /// segmented root. This is intentionally not called by public `open()` and does not enable
    /// automatic schema migration.
    package func resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1(
        faultInjector: FileBlobStoreSegmentedMigrationFaultInjector? = nil
    ) throws -> FileBlobStoreSegmentedMigrationPrototypeResult {
        guard !requiresReopenBeforeFurtherAccess,
            loadedManifestSchemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            isValidManifestEntriesAndOwnership(manifest)
        else { throw AkashicError.unsupportedSchema }

        let headState = try currentDirectoryHeadState()
        guard headState.activeHead.g == manifest.generation,
            Int(headState.activeHead.c) == headState.latest.count
        else { throw AkashicError.invalidManifest }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let baseData = try encoder.encode(manifest)
        guard baseData.count <= SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes else {
            throw AkashicError.limitExceeded
        }

        let rootDirectory = manifestURL.deletingLastPathComponent()
        let segmentDirectory = rootDirectory.appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(segmentDirectory)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: nil,
            directory: segmentDirectory
        )
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory
        )
        let baseFileName = "base-migration-\(UUID().uuidString.lowercased()).json"
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: manifest.entries.count,
            fileName: baseFileName,
            directory: segmentDirectory
        )
        try faultInjector?(.afterBaseDurable)
        let generation = manifest.generation.addingReportingOverflow(1)
        guard !generation.overflow else {
            throw AkashicError.storageUnavailable
        }
        let segmentedRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: generation.partialValue,
            base: base,
            runs: []
        )

        let rootFaultInjector: DurableFileWriteFaultInjector?
        if let faultInjector {
            rootFaultInjector = { switchPoint in
                try faultInjector(.root(switchPoint))
            }
        } else {
            rootFaultInjector = nil
        }
        do {
            try SegmentedManifestPrototypeV1.writeRoot(
                segmentedRoot,
                to: manifestURL,
                faultInjector: rootFaultInjector
            )
        } catch {
            // Root replacement may have crossed rename visibility. Conservatively require a fresh
            // bootstrap even when the injected failure occurred before rename.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        requiresReopenBeforeFurtherAccess = true
        return FileBlobStoreSegmentedMigrationPrototypeResult(
            root: segmentedRoot,
            segmentDirectory: segmentDirectory,
            activeSchema4DistinctKeys: Int(headState.activeHead.c)
        )
    }
}
