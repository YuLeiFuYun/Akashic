import AkashicCore
import CryptoKit
import Foundation

extension SegmentedManifestPrototypeV1 {
    package static func writeBaseJSON(
        _ data: Data,
        entryCount: Int,
        fileName: String,
        directory: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        guard isCanonicalSegmentFileName(fileName, kind: .baseJSON),
            entryCount >= 0,
            entryCount <= 100_000,
            data.count > 0,
            data.count <= maximumBaseBytes,
            data.count <= maximumReferencedSegmentBytes
        else { throw AkashicError.invalidManifest }
        try StorageDirectorySecurity.validateDirectory(directory)
        let url = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(data, to: url)
        try StorageDirectorySecurity.validateRegularFile(url)
        return SegmentedManifestDescriptorV1(
            kind: .baseJSON,
            fileName: fileName,
            byteCount: data.count,
            recordCount: entryCount,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    package static func writeBaseBinary(
        _ state: [String: SegmentedManifestEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        guard isCanonicalSegmentFileName(fileName, kind: .baseBinaryV1),
            state.count <= SegmentedManifestBinaryBaseV1.maximumRecords
        else { throw AkashicError.invalidManifest }
        let data = try SegmentedManifestBinaryBaseV1.encode(state)
        guard data.count <= maximumBaseBytes,
            data.count <= maximumReferencedSegmentBytes
        else { throw AkashicError.limitExceeded }
        try StorageDirectorySecurity.validateDirectory(directory)
        let url = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(data, to: url)
        try StorageDirectorySecurity.validateRegularFile(url)
        return SegmentedManifestDescriptorV1(
            kind: .baseBinaryV1,
            fileName: fileName,
            byteCount: data.count,
            recordCount: state.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    package static func writeBaseBinaryV2(
        _ state: [String: SegmentedManifestEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        guard isCanonicalSegmentFileName(fileName, kind: .baseBinaryV2),
            state.count <= SegmentedManifestBinaryBaseV2.maximumRecords
        else { throw AkashicError.invalidManifest }
        let data = try SegmentedManifestBinaryBaseV2.encode(state)
        guard data.count <= maximumBaseBytes,
            data.count <= maximumReferencedSegmentBytes
        else { throw AkashicError.limitExceeded }
        try StorageDirectorySecurity.validateDirectory(directory)
        let url = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(data, to: url)
        try StorageDirectorySecurity.validateRegularFile(url)
        return SegmentedManifestDescriptorV1(
            kind: .baseBinaryV2,
            fileName: fileName,
            byteCount: data.count,
            recordCount: state.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    package static func writeRun(
        _ mutations: [SegmentedManifestMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        guard isCanonicalSegmentFileName(fileName, kind: .runV1) else {
            throw AkashicError.invalidManifest
        }
        try StorageDirectorySecurity.validateDirectory(directory)
        let data = try encodeRun(mutations)
        let url = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(data, to: url)
        try StorageDirectorySecurity.validateRegularFile(url)
        return SegmentedManifestDescriptorV1(
            kind: .runV1,
            fileName: fileName,
            byteCount: data.count,
            recordCount: mutations.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    package static func writeRoot(
        _ root: SegmentedManifestRootV1,
        to url: URL,
        faultInjector: DurableFileWriteFaultInjector? = nil
    ) throws {
        let data = try encodeRoot(root)
        if let faultInjector {
            try DurableFileWriter.writeReplacing(
                data,
                to: url,
                faultInjector: faultInjector
            )
        } else {
            try DurableFileWriter.writeReplacing(data, to: url)
        }
    }

    package static func readRoot(from url: URL) throws -> SegmentedManifestRootV1 {
        try StorageDirectorySecurity.validateRegularFile(url)
        let data = try BoundedFileReader.read(from: url, maximumBytes: maximumRootBytes)
        return try decodeRoot(data)
    }

    package static func recover(
        rootURL: URL,
        segmentDirectory: URL
    ) throws -> [String: SegmentedManifestEntry] {
        let root = try readRoot(from: rootURL)
        return try recover(root: root, segmentDirectory: segmentDirectory)
    }

    /// Recover exactly the immutable descriptor set supplied by the caller. Background compaction
    /// uses this overload so actor suspension cannot silently move the proof input to a newer root.
    package static func recover(
        root: SegmentedManifestRootV1,
        segmentDirectory: URL
    ) throws -> [String: SegmentedManifestEntry] {
        try StorageDirectorySecurity.validateDirectory(segmentDirectory)
        _ = try encodeRoot(root)
        var state = try readBase(root.base, directory: segmentDirectory)
        var ownerByPhysicalID: [PhysicalBlobID: String] = [:]
        ownerByPhysicalID.reserveCapacity(state.count)
        for (key, entry) in state {
            guard ownerByPhysicalID.updateValue(key, forKey: entry.physicalID) == nil else {
                throw AkashicError.invalidManifest
            }
        }
        for run in root.runs {
            try applyRecoveredRun(
                try readRun(run, directory: segmentDirectory),
                state: &state,
                ownerByPhysicalID: &ownerByPhysicalID
            )
        }
        guard ownerByPhysicalID.count == state.count,
            state.allSatisfy({ key, entry in ownerByPhysicalID[entry.physicalID] == key })
        else { throw AkashicError.invalidManifest }
        return state
    }

    /// Apply one already-decoded immutable run while validating PhysicalBlobID ownership in O(run)
    /// rather than rescanning the whole live manifest after every run. Ownership is a final-run-state
    /// invariant: release every touched key first so same-run transfers/swaps remain legal.
    private static func applyRecoveredRun(
        _ mutations: [SegmentedManifestMutation],
        state: inout [String: SegmentedManifestEntry],
        ownerByPhysicalID: inout [PhysicalBlobID: String]
    ) throws {
        for mutation in mutations {
            guard let old = state[mutation.key] else { continue }
            guard ownerByPhysicalID[old.physicalID] == mutation.key else {
                throw AkashicError.invalidManifest
            }
            ownerByPhysicalID.removeValue(forKey: old.physicalID)
        }
        for mutation in mutations {
            switch mutation {
            case .tombstone(let key):
                state.removeValue(forKey: key)
            case .upsert(let entry):
                guard ownerByPhysicalID[entry.physicalID] == nil else {
                    throw AkashicError.invalidManifest
                }
                state[entry.key] = entry
                ownerByPhysicalID[entry.physicalID] = entry.key
            }
        }
    }

    package static func readBase(
        _ descriptor: SegmentedManifestDescriptorV1,
        directory: URL
    ) throws -> [String: SegmentedManifestEntry] {
        let data = try readDescriptorData(descriptor, directory: directory)
        let result: [String: SegmentedManifestEntry]
        switch descriptor.kind {
        case .baseJSON:
            let decoded = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(data)
            guard decoded.count == descriptor.recordCount else { throw AkashicError.invalidManifest }
            var converted: [String: SegmentedManifestEntry] = [:]
            converted.reserveCapacity(decoded.count)
            for (key, entry) in decoded {
                converted[key] = SegmentedManifestEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: entry.lastAccess
                )
            }
            result = converted
        case .baseBinaryV1:
            result = try SegmentedManifestBinaryBaseV1.decode(data)
            guard result.count == descriptor.recordCount else { throw AkashicError.invalidManifest }
        case .baseBinaryV2:
            result = try SegmentedManifestBinaryBaseV2.decode(data)
            guard result.count == descriptor.recordCount else { throw AkashicError.invalidManifest }
        case .runV1, .compoundRunV1:
            throw AkashicError.invalidManifest
        }
        let physicalIDs = result.values.map(\.physicalID)
        guard Set(physicalIDs).count == physicalIDs.count else { throw AkashicError.invalidManifest }
        return result
    }

    package static func readRun(
        _ descriptor: SegmentedManifestDescriptorV1,
        directory: URL
    ) throws -> [SegmentedManifestMutation] {
        guard descriptor.kind == .runV1 || descriptor.kind == .compoundRunV1 else {
            throw AkashicError.invalidManifest
        }
        let data = try readDescriptorData(descriptor, directory: directory)
        let mutations: [SegmentedManifestMutation]
        switch descriptor.kind {
        case .runV1:
            mutations = try decodeRun(data)
        case .compoundRunV1:
            mutations = try SegmentedManifestCompoundRunV1.decode(data)
        case .baseJSON, .baseBinaryV1, .baseBinaryV2:
            throw AkashicError.invalidManifest
        }
        guard mutations.count == descriptor.recordCount else { throw AkashicError.invalidManifest }
        return mutations
    }

    package static func readDescriptorData(
        _ descriptor: SegmentedManifestDescriptorV1,
        directory: URL
    ) throws -> Data {
        guard isCanonicalSegmentFileName(descriptor.fileName, kind: descriptor.kind) else {
            throw AkashicError.invalidManifest
        }
        let url = directory.appendingPathComponent(descriptor.fileName)
        try StorageDirectorySecurity.validateRegularFile(url)
        let maximum: Int
        switch descriptor.kind {
        case .baseJSON, .baseBinaryV1, .baseBinaryV2:
            maximum = maximumBaseBytes
        case .runV1:
            maximum = maximumRunBytes
        case .compoundRunV1:
            maximum = SegmentedManifestCompoundRunV1.maximumBytes
        }
        guard descriptor.byteCount <= maximum else { throw AkashicError.invalidManifest }
        let data = try BoundedFileReader.read(from: url, maximumBytes: descriptor.byteCount)
        guard data.count == descriptor.byteCount,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256
        else { throw AkashicError.invalidManifest }
        return data
    }

    package static func publishEpochRun(
        mutations: [SegmentedManifestMutation],
        runFileName: String,
        currentRoot: SegmentedManifestRootV1,
        rootURL: URL,
        segmentDirectory: URL,
        rootFaultInjector: DurableFileWriteFaultInjector? = nil
    ) throws -> SegmentedManifestRootV1 {
        guard currentRoot.runs.count < maximumRunDescriptors,
            currentRoot.generation < UInt64.max,
            isCanonicalSegmentFileName(runFileName, kind: .runV1)
        else { throw AkashicError.storageUnavailable }

        // Complete every representability check before new physical segment bytes exist. A hard
        // run/reference/root cap is admission backpressure, not a reason to manufacture orphan debt.
        let runData = try encodeRun(mutations)
        let run = SegmentedManifestDescriptorV1(
            kind: .runV1,
            fileName: runFileName,
            byteCount: runData.count,
            recordCount: mutations.count,
            sha256: SHA256.hash(data: runData).map { String(format: "%02x", $0) }.joined()
        )
        let next = try makeRootPreservingProfile(
            of: currentRoot,
            generation: currentRoot.generation + 1,
            base: currentRoot.base,
            runs: currentRoot.runs + [run]
        )
        let nextRootData = try encodeRoot(next)

        try StorageDirectorySecurity.validateDirectory(segmentDirectory)
        let runURL = segmentDirectory.appendingPathComponent(runFileName)
        guard !FileManager.default.fileExists(atPath: runURL.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(runData, to: runURL)
        try StorageDirectorySecurity.validateRegularFile(runURL)
        if let rootFaultInjector {
            try DurableFileWriter.writeReplacing(
                nextRootData,
                to: rootURL,
                faultInjector: rootFaultInjector
            )
        } else {
            try DurableFileWriter.writeReplacing(nextRootData, to: rootURL)
        }
        return next
    }
}
