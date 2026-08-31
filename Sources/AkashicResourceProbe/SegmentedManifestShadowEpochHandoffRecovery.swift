import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func recoverEpochAuthority(
        rootURL: URL,
        segmentDirectory: URL,
        headDirectory: URL,
        allowEmptyEpochRepair: Bool
    ) throws -> [String: SegmentedShadowEntry] {
        let rootData = try BoundedFileReader.read(from: rootURL, maximumBytes: maximumRootBytes)
        let root = try JSONDecoder().decode(SegmentedShadowRoot.self, from: rootData)
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        var history = Dictionary(
            uniqueKeysWithValues: try readBase(root.base, directory: segmentDirectory).map { ($0.key, $0) }
        )
        for run in root.runs {
            history = try apply(try readRun(run, directory: segmentDirectory), to: history)
        }
        let shadowBase = epochShadowState(history)
        if allowEmptyEpochRepair {
            try repairEmptyEpochIfNeeded(root: headDirectory, generation: root.generation)
        }
        let recovered = try DirectoryHeadShadowProbe.recover(
            root: headDirectory,
            generation: root.generation,
            base: shadowBase
        )
        return epochSegmentedState(recovered.logical)
    }

    static func repairEmptyEpochIfNeeded(root: URL, generation: UInt64) throws {
        let names = try XattrShadowProbeIO.listAttributes(root)
        var headSlots = Set<UInt8>()
        var recordCount = 0
        for name in names {
            if let head = try DirectoryHeadIdentity.parse(name) {
                if head.generation < generation { continue }
                guard head.generation == generation else {
                    throw DirectoryHeadShadowError.invalidHead
                }
                guard headSlots.insert(head.slot).inserted else {
                    throw DirectoryHeadShadowError.invalidHead
                }
                continue
            }
            if let record = try DirectoryHeadRecordIdentity.parse(name) {
                if record.generation < generation { continue }
                guard record.generation == generation else {
                    throw DirectoryHeadShadowError.invalidRecord
                }
                recordCount += 1
            }
        }
        guard recordCount == 0 else { return }
        switch headSlots.count {
        case 0:
            try DirectoryHeadShadowProbe.initializeMigrationShadow(
                root: root,
                generation: generation
            )
        case 1:
            guard let existingSlot = headSlots.first else {
                throw DirectoryHeadShadowError.invalidHead
            }
            let existingIdentity = DirectoryHeadIdentity(
                generation: generation,
                slot: existingSlot
            )
            let existing = try DirectoryHeadShadowProbe.decodeHead(
                try XattrShadowProbeIO.readAttribute(existingIdentity.name, from: root),
                expected: existingIdentity
            )
            guard existing.s == 0,
                existing.c == 0,
                existing.r == DirectoryHeadShadowProbe.zeroRoot
            else { throw DirectoryHeadShadowError.invalidHead }
            let missingSlot: UInt8 = existingSlot == 0 ? 1 : 0
            let missing = try DirectoryHeadShadowProbe.makeHead(
                generation: generation,
                slot: missingSlot,
                sequence: 0,
                count: 0,
                root: DirectoryHeadShadowProbe.zeroRoot
            )
            try DirectoryHeadShadowIO.setAttribute(
                DirectoryHeadIdentity(generation: generation, slot: missingSlot).name,
                value: try DirectoryHeadShadowProbe.encodeHead(missing),
                at: root,
                flags: XATTR_CREATE
            )
            try DirectoryHeadShadowIO.synchronize(root)
        case 2:
            break
        default:
            throw DirectoryHeadShadowError.invalidHead
        }
    }

    static func epochRemoveEmptyHeads(generation: UInt64, from root: URL) throws {
        for slot: UInt8 in [0, 1] {
            try DirectoryHeadShadowIO.removeAttribute(
                DirectoryHeadIdentity(generation: generation, slot: slot).name,
                at: root
            )
        }
        try DirectoryHeadShadowIO.synchronize(root)
    }

    static func epochWriteBase(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    static func epochShadowState(
        _ source: [String: SegmentedShadowEntry]
    ) -> [String: FileBlobStoreRecordShadowEntry] {
        source.mapValues { entry in
            FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }

    static func epochSegmentedState(
        _ source: [String: FileBlobStoreRecordShadowEntry]
    ) -> [String: SegmentedShadowEntry] {
        Dictionary(uniqueKeysWithValues: source.map { key, entry in
            (
                key,
                SegmentedShadowEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: entry.lastAccess
                )
            )
        })
    }

    static func epochSetImmutable(_ immutable: Bool, url: URL) throws {
        let result = url.path.withCString { chflags($0, immutable ? UInt32(UF_IMMUTABLE) : 0) }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
