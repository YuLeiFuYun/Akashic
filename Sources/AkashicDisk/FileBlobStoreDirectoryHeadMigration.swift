import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    private static let directoryHeadCapabilityProbeName =
        "dev.akashic.capability.directory-head-v2"
    private static let directoryHeadCapabilityProbeValue = Data([0xA4, 0x01])

    func probeDirectoryHeadCarrierSupport() throws -> Bool {
        do {
            try directoryHeadOperations.removeAttribute(
                Self.directoryHeadCapabilityProbeName,
                blobs
            )
        } catch let error as POSIXError where Self.isUnsupportedDirectoryHeadXattr(error.code) {
            return false
        }

        do {
            try directoryHeadOperations.setAttribute(
                Self.directoryHeadCapabilityProbeName,
                Self.directoryHeadCapabilityProbeValue,
                blobs,
                XATTR_CREATE
            )
        } catch let error as POSIXError where Self.isUnsupportedDirectoryHeadXattr(error.code) {
            return false
        }

        let observed = try directoryHeadOperations.readAttribute(
            Self.directoryHeadCapabilityProbeName,
            blobs,
            64
        )
        guard observed == Self.directoryHeadCapabilityProbeValue else {
            throw AkashicError.storageUnavailable
        }
        try directoryHeadOperations.removeAttribute(
            Self.directoryHeadCapabilityProbeName,
            blobs
        )
        try directoryHeadOperations.synchronizeDirectory(blobs)
        return true
    }

    func initializeEmptyDirectoryHeadGeneration(
        generation: UInt64
    ) throws -> DirectoryHeadRecoveredState {
        let heads = try Self.initialDirectoryHeads(generation: generation)
        do {
            try writeDirectoryHead(heads.0, flags: XATTR_CREATE)
            try writeDirectoryHead(heads.1, flags: XATTR_CREATE)
            try directoryHeadOperations.synchronizeDirectory(blobs)
        } catch {
            // A schema4 snapshot may already be visible before head initialization completes. The
            // writer cannot continue from a partially initialized authority frontier; reopen owns
            // the narrow empty-generation repair path.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        return try Self.loadDirectoryHeadState(
            directory: blobs,
            generation: generation,
            operations: directoryHeadOperations
        )
    }

    func loadOrRepairDirectoryHeadGeneration(
        generation: UInt64
    ) throws -> DirectoryHeadRecoveredState {
        let names = try directoryHeadOperations.listAttributes(
            blobs,
            Self.maximumDirectoryHeadXattrListBytes
        )
        var currentRecordCount = 0
        var currentHeads: [UInt8: String] = [:]

        for name in names {
            if let identity = try DirectoryHeadIdentity.parse(name) {
                if identity.generation < generation { continue }
                guard identity.generation == generation,
                    currentHeads[identity.slot] == nil
                else { throw AkashicError.invalidManifest }
                currentHeads[identity.slot] = name
                continue
            }
            if let identity = try DirectoryHeadRecordIdentity.parse(name) {
                if identity.generation < generation { continue }
                guard identity.generation == generation else {
                    throw AkashicError.invalidManifest
                }
                currentRecordCount += 1
                guard currentRecordCount <= Self.manifestCheckpointRecordLimit * 2 else {
                    throw AkashicError.invalidManifest
                }
            }
        }

        if currentRecordCount > 0 {
            return try Self.loadDirectoryHeadState(
                directory: blobs,
                generation: generation,
                operations: directoryHeadOperations
            )
        }

        switch currentHeads.count {
        case 0:
            return try initializeEmptyDirectoryHeadGeneration(generation: generation)
        case 1:
            guard let existing = currentHeads.first else {
                throw AkashicError.invalidManifest
            }
            let identity = DirectoryHeadIdentity(
                generation: generation,
                slot: existing.key
            )
            let head = try Self.decodeDirectoryHead(
                directoryHeadOperations.readAttribute(
                    existing.value,
                    blobs,
                    Self.maximumDirectoryHeadValueBytes
                ),
                expected: identity
            )
            guard head.s == 0,
                head.c == 0,
                head.r == Self.directoryHeadZeroRoot
            else { throw AkashicError.invalidManifest }
            let missingSlot: UInt8 = existing.key == 0 ? 1 : 0
            let missing = try Self.makeDirectoryHead(
                generation: generation,
                slot: missingSlot,
                sequence: 0,
                count: 0,
                root: Self.directoryHeadZeroRoot
            )
            do {
                try writeDirectoryHead(missing, flags: XATTR_CREATE)
                try directoryHeadOperations.synchronizeDirectory(blobs)
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            return try Self.loadDirectoryHeadState(
                directory: blobs,
                generation: generation,
                operations: directoryHeadOperations
            )
        case 2:
            return try Self.loadDirectoryHeadState(
                directory: blobs,
                generation: generation,
                operations: directoryHeadOperations
            )
        default:
            throw AkashicError.invalidManifest
        }
    }

    /// Upgrade a fully replayed schema2/3 logical state to an empty-delta schema4 generation.
    ///
    /// The caller must invoke this only after legacy snapshot+delta replay and physical
    /// reconciliation have completed. No schema4 delta may be emitted before this succeeds.
    func rebuildStaleDirectoryHeadCleanupQueue(
        staleBeforeGeneration generation: UInt64
    ) throws {
        let names = try directoryHeadOperations.listAttributes(
            blobs,
            Self.maximumDirectoryHeadXattrListBytes
        )
        var staleNames: [String] = []
        staleNames.reserveCapacity(names.count)
        for name in names {
            if let identity = try DirectoryHeadRecordIdentity.parse(name) {
                if identity.generation < generation {
                    staleNames.append(name)
                } else if identity.generation > generation {
                    throw AkashicError.invalidManifest
                }
                continue
            }
            if let identity = try DirectoryHeadIdentity.parse(name) {
                if identity.generation < generation {
                    staleNames.append(name)
                } else if identity.generation > generation {
                    throw AkashicError.invalidManifest
                }
            }
        }
        staleDirectoryHeadCleanupQueue = staleNames.sorted()
    }

    package func migrateLegacyManifestToDirectoryHeadSchema4() throws -> Bool {
        guard loadedManifestSchemaVersion < Self.directoryHeadManifestSchemaVersion else {
            return false
        }
        guard try probeDirectoryHeadCarrierSupport() else {
            return false
        }
        guard isValidManifestEntriesAndOwnership(manifest) else {
            throw AkashicError.invalidManifest
        }
        let legacyGeneration = manifest.generation
        let legacyRecordKeys = manifestRecordKeys
        let generation = manifest.generation.addingReportingOverflow(1)
        guard !generation.overflow else { throw AkashicError.storageUnavailable }
        let snapshot = Manifest(
            schemaVersion: Self.directoryHeadManifestSchemaVersion,
            generation: generation.partialValue,
            deltaCarrierProfile: .directoryHeadV2,
            entries: manifest.entries
        )
        guard isValidManifestEntriesAndOwnership(snapshot) else {
            throw AkashicError.invalidManifest
        }
        try persistValidatedManifestSnapshot(snapshot, injectFaults: true)
        manifest = snapshot
        loadedManifestSchemaVersion = Self.directoryHeadManifestSchemaVersion
        manifestRecordSequence = 0
        manifestRecordKeys.removeAll(keepingCapacity: true)
        do {
            directoryHeadState = try initializeEmptyDirectoryHeadGeneration(
                generation: snapshot.generation
            )
            try rebuildManifestResourceIndexes()
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        enqueueLegacyManifestRecordCandidatesForCleanup(
            generation: legacyGeneration,
            keys: legacyRecordKeys
        )
        return true
    }

    func writeDirectoryHead(_ head: DirectoryHeadValue, flags: Int32) throws {
        try directoryHeadOperations.setAttribute(
            DirectoryHeadIdentity(generation: head.g, slot: head.p).name,
            try Self.encodeDirectoryHead(head),
            blobs,
            flags
        )
    }

    private static func isUnsupportedDirectoryHeadXattr(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ENOTSUP, .E2BIG:
            true
        default:
            false
        }
    }
}
