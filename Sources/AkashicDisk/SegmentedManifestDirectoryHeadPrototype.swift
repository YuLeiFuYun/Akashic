import AkashicCore
import Darwin
import Foundation

package enum SegmentedManifestDirectoryHeadPrototypeV1 {
    package static func writeEmptyHeadSlot(
        generation: UInt64,
        slot: UInt8,
        blobsDirectory: URL
    ) throws {
        guard slot <= 1 else { throw AkashicError.invalidManifest }
        try StorageDirectorySecurity.validateDirectory(blobsDirectory)
        let heads = try FileBlobStore.initialDirectoryHeads(generation: generation)
        let head = slot == 0 ? heads.0 : heads.1
        let identity = FileBlobStore.DirectoryHeadIdentity(generation: generation, slot: slot)
        let operations = FileBlobStoreDirectoryHeadOperations.system
        try operations.setAttribute(
            identity.name,
            try FileBlobStore.encodeDirectoryHead(head),
            blobsDirectory,
            XATTR_CREATE
        )
        try operations.synchronizeDirectory(blobsDirectory)
    }

    package static func currentHeadCount(
        generation: UInt64,
        blobsDirectory: URL
    ) throws -> Int {
        try StorageDirectorySecurity.validateDirectory(blobsDirectory)
        let scan = try scan(generation: generation, blobsDirectory: blobsDirectory)
        guard scan.currentRecordCount == 0 else { throw AkashicError.invalidManifest }
        return scan.headNames.count
    }

    /// Repair only the empty generation that follows a newly visible segmented root. Any current
    /// generation record body is rejected; non-empty active epochs belong to the normal schema5
    /// mutation/recovery path, not migration initialization.
    @discardableResult
    package static func repairEmptyGeneration(
        generation: UInt64,
        blobsDirectory: URL
    ) throws -> Int {
        try StorageDirectorySecurity.validateDirectory(blobsDirectory)
        let operations = FileBlobStoreDirectoryHeadOperations.system
        var observed = try scan(generation: generation, blobsDirectory: blobsDirectory)
        guard observed.currentRecordCount == 0 else { throw AkashicError.invalidManifest }

        switch observed.headNames.count {
        case 0:
            let heads = try FileBlobStore.initialDirectoryHeads(generation: generation)
            try operations.setAttribute(
                FileBlobStore.DirectoryHeadIdentity(generation: generation, slot: 0).name,
                try FileBlobStore.encodeDirectoryHead(heads.0),
                blobsDirectory,
                XATTR_CREATE
            )
            try operations.setAttribute(
                FileBlobStore.DirectoryHeadIdentity(generation: generation, slot: 1).name,
                try FileBlobStore.encodeDirectoryHead(heads.1),
                blobsDirectory,
                XATTR_CREATE
            )
            try operations.synchronizeDirectory(blobsDirectory)
        case 1:
            guard let existing = observed.headNames.first else {
                throw AkashicError.invalidManifest
            }
            let identity = FileBlobStore.DirectoryHeadIdentity(
                generation: generation,
                slot: existing.key
            )
            let head = try FileBlobStore.decodeDirectoryHead(
                operations.readAttribute(
                    existing.value,
                    blobsDirectory,
                    FileBlobStore.maximumDirectoryHeadValueBytes
                ),
                expected: identity
            )
            guard head.s == 0,
                head.c == 0,
                head.r == FileBlobStore.directoryHeadZeroRoot
            else { throw AkashicError.invalidManifest }
            let missingSlot: UInt8 = existing.key == 0 ? 1 : 0
            let missing = try FileBlobStore.makeDirectoryHead(
                generation: generation,
                slot: missingSlot,
                sequence: 0,
                count: 0,
                root: FileBlobStore.directoryHeadZeroRoot
            )
            try operations.setAttribute(
                FileBlobStore.DirectoryHeadIdentity(
                    generation: generation,
                    slot: missingSlot
                ).name,
                try FileBlobStore.encodeDirectoryHead(missing),
                blobsDirectory,
                XATTR_CREATE
            )
            try operations.synchronizeDirectory(blobsDirectory)
        case 2:
            break
        default:
            throw AkashicError.invalidManifest
        }

        observed = try scan(generation: generation, blobsDirectory: blobsDirectory)
        guard observed.currentRecordCount == 0,
            observed.headNames.count == 2
        else { throw AkashicError.invalidManifest }
        let state = try FileBlobStore.loadDirectoryHeadState(
            directory: blobsDirectory,
            generation: generation,
            operations: operations
        )
        guard state.activeHead.s == 0,
            state.activeHead.c == 0,
            state.activeHead.r == FileBlobStore.directoryHeadZeroRoot,
            state.latest.isEmpty,
            state.uncommittedRecordNames.isEmpty
        else { throw AkashicError.invalidManifest }
        return observed.headNames.count
    }

    private struct Scan {
        var headNames: [UInt8: String]
        var currentRecordCount: Int
    }

    private static func scan(
        generation: UInt64,
        blobsDirectory: URL
    ) throws -> Scan {
        let names = try FileBlobStoreDirectoryHeadOperations.system.listAttributes(
            blobsDirectory,
            FileBlobStore.maximumDirectoryHeadXattrListBytes
        )
        var heads: [UInt8: String] = [:]
        var records = 0
        for name in names {
            if let identity = try FileBlobStore.DirectoryHeadIdentity.parse(name) {
                if identity.generation < generation { continue }
                guard identity.generation == generation,
                    heads[identity.slot] == nil
                else { throw AkashicError.invalidManifest }
                heads[identity.slot] = name
                continue
            }
            if let identity = try FileBlobStore.DirectoryHeadRecordIdentity.parse(name) {
                if identity.generation < generation { continue }
                guard identity.generation == generation else {
                    throw AkashicError.invalidManifest
                }
                records += 1
                guard records <= FileBlobStore.resourceProbeManifestCheckpointRecordLimit * 2 else {
                    throw AkashicError.invalidManifest
                }
            }
        }
        return Scan(headNames: heads, currentRecordCount: records)
    }
}
