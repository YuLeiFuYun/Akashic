import AkashicCore
import Foundation

extension FileBlobStore {
    func bootstrapPersistedManifest(
        data: Data,
        schemaVersion: UInt16,
        observer: FileBlobStoreBootstrapObserver
    ) throws {
        switch schemaVersion {
        case Self.segmentedManifestSchemaVersion:
            try bootstrapSegmentedManifest(observer: observer)
        case Self.legacyManifestSchemaVersion,
            Self.currentSchemaVersion,
            Self.directoryHeadManifestSchemaVersion:
            try bootstrapLegacyOrDirectoryHeadManifest(
                data: data,
                schemaVersion: schemaVersion,
                observer: observer
            )
        default:
            throw AkashicError.unsupportedSchema
        }
    }

    private func bootstrapLegacyOrDirectoryHeadManifest(
        data: Data,
        schemaVersion: UInt16,
        observer: FileBlobStoreBootstrapObserver
    ) throws {
        let decoded: Manifest
        do {
            decoded = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw AkashicError.invalidManifest
        }
        if schemaVersion == Self.legacyManifestSchemaVersion {
            guard isValidManifest(decoded) else { throw AkashicError.invalidManifest }
        }
        manifest = decoded
        loadedManifestSchemaVersion = schemaVersion
        segmentedManifestRoot = nil
        observer(.manifestSnapshotLoaded)
        if schemaVersion == Self.directoryHeadManifestSchemaVersion {
            guard decoded.schemaVersion == Self.directoryHeadManifestSchemaVersion,
                decoded.deltaCarrierProfile == .directoryHeadV2
            else { throw AkashicError.invalidManifest }
            let state = try loadOrRepairDirectoryHeadGeneration(generation: decoded.generation)
            let replayed = try Self.applyDirectoryHeadState(state, to: decoded)
            guard isValidManifest(replayed) else { throw AkashicError.invalidManifest }
            manifest = replayed
            directoryHeadState = state
            manifestRecordSequence = state.activeHead.s
            manifestRecordKeys = Set(state.latest.keys)
            try rebuildStaleDirectoryHeadCleanupQueue(staleBeforeGeneration: decoded.generation)
        } else {
            try requireNoDirectoryHeadEvidenceForLegacyManifest()
            try replayManifestRecords()
        }
        observer(.manifestRecordsReplayed)
    }

    private func bootstrapSegmentedManifest(
        observer: FileBlobStoreBootstrapObserver
    ) throws {
        let segmentDirectory = manifestURL.deletingLastPathComponent().appendingPathComponent(
            Self.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.validateDirectory(segmentDirectory)
        let root = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard root.schemaVersion == Int(Self.segmentedManifestSchemaVersion),
            root.profile == SegmentedManifestPrototypeV1.profileV1
                || (allowsSegmentedProfileV2
                    && root.profile == SegmentedManifestPrototypeV1.profileV2)
                || (allowsSegmentedProfileV3
                    && root.profile == SegmentedManifestPrototypeV1.profileV3)
                || (allowsSegmentedProfileV4
                    && root.profile == SegmentedManifestPrototypeV1.profileV4)
        else { throw AkashicError.invalidManifest }
        try SegmentedManifestSegmentCleanupV1.validateReferencedProductionOwnership(root: root)
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: manifestURL,
            segmentDirectory: segmentDirectory
        )
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(recovered.count)
        for (key, entry) in recovered {
            entries[key] = Entry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
        let carrier = Manifest(
            schemaVersion: Self.directoryHeadManifestSchemaVersion,
            generation: root.generation,
            deltaCarrierProfile: .directoryHeadV2,
            entries: entries
        )
        guard isValidManifestEntriesAndOwnership(carrier) else {
            throw AkashicError.invalidManifest
        }
        manifest = carrier
        loadedManifestSchemaVersion = Self.segmentedManifestSchemaVersion
        segmentedManifestRoot = root
        observer(.manifestSnapshotLoaded)

        let state = try loadOrRepairDirectoryHeadGeneration(generation: root.generation)
        let replayed = try Self.applyDirectoryHeadState(state, to: carrier)
        guard isValidManifest(replayed) else { throw AkashicError.invalidManifest }
        manifest = replayed
        directoryHeadState = state
        manifestRecordSequence = state.activeHead.s
        manifestRecordKeys = Set(state.latest.keys)
        try rebuildStaleDirectoryHeadCleanupQueue(staleBeforeGeneration: root.generation)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: root,
            directory: segmentDirectory
        )
        observer(.manifestRecordsReplayed)
    }
}
