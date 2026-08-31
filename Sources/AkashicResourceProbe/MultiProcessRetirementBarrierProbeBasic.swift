import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func multiProcessRetirementBarrierReader(arguments: [String]) async throws {
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
            let label = values["--label"],
            let barrierPath = values["--barrier"],
            let readyPath = values["--ready"],
            let openSignalPath = values["--open-signal"],
            let fdOpenedPath = values["--fd-opened"],
            let readSignalPath = values["--read-signal"],
            let resultPath = values["--result"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let barrierURL = URL(fileURLWithPath: barrierPath, isDirectory: false)
        let readyURL = URL(fileURLWithPath: readyPath, isDirectory: false)
        let openSignalURL = URL(fileURLWithPath: openSignalPath, isDirectory: false)
        let fdOpenedURL = URL(fileURLWithPath: fdOpenedPath, isDirectory: false)
        let readSignalURL = URL(fileURLWithPath: readSignalPath, isDirectory: false)
        let resultURL = URL(fileURLWithPath: resultPath, isDirectory: false)
        let barrier = try MultiProcessRetirementBarrier(path: barrierURL)
        try barrier.lockShared()
        var sharedHeld = true
        defer {
            if sharedHeld { try? barrier.unlock() }
        }
        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let resolved = try schema5RetirementResolve(root: root, label: label)

        try schema5RetirementWriteJSON(
            RetirementBarrierReaderReady(
                schemaVersion: 1,
                pid: ProcessInfo.processInfo.processIdentifier,
                label: label,
                physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
                byteCount: resolved.entry.byteCount,
                profile: resolved.root.profile,
                baseKind: resolved.root.base.kind.rawValue,
                sharedBarrierHeld: true,
                payloadPathExists: FileManager.default.fileExists(atPath: resolved.payloadURL.path)
            ),
            to: readyURL
        )
        FileHandle.standardOutput.write(Data("READER-READY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: openSignalURL.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let descriptor = Darwin.open(
            resolved.payloadURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw schema5RetirementPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        let status = try StorageDirectorySecurity.validatedOpenedPrivateRegularFileStatus(descriptor)
        guard status.st_size >= 0,
            UInt64(status.st_size) == UInt64(resolved.entry.byteCount)
        else { throw AkashicError.integrityMismatch }
        let pathExistsAtOpen = FileManager.default.fileExists(atPath: resolved.payloadURL.path)
        try barrier.unlock()
        sharedHeld = false

        try schema5RetirementWriteJSON(
            RetirementBarrierFDOpened(
                schemaVersion: 1,
                label: label,
                physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
                descriptorValidated: true,
                sharedBarrierReleased: true,
                payloadPathExistsAtOpen: pathExistsAtOpen
            ),
            to: fdOpenedURL
        )
        FileHandle.standardOutput.write(Data("FD-OPENED-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: readSignalURL.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let data = try schema5RetirementReadDescriptor(
            descriptor,
            byteCount: resolved.entry.byteCount
        )
        let result = RetirementBarrierReaderResult(
            schemaVersion: 1,
            label: label,
            physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
            payloadPathExistsAfterWriter: FileManager.default.fileExists(
                atPath: resolved.payloadURL.path
            ),
            bytesRead: data.count,
            payloadExact: data == identity.data,
            digestExact: BlobDigest.sha256(of: data) == identity.digest
        )
        try schema5RetirementWriteJSON(result, to: resultURL)
    }

    static func multiProcessRetirementBarrierRemove(arguments: [String]) async throws {
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
            let label = values["--label"],
            let barrierPath = values["--barrier"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let barrierURL = URL(fileURLWithPath: barrierPath, isDirectory: false)
        let barrier = try MultiProcessRetirementBarrier(path: barrierURL)
        let immediateExclusive = try barrier.tryLockExclusive()
        if immediateExclusive {
            try barrier.unlock()
            FileHandle.standardOutput.write(Data("INITIAL-EXCLUSIVE-ACQUIRED\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data("INITIAL-EXCLUSIVE-WOULD-BLOCK\n".utf8))
        }
        try barrier.lockExclusive()
        FileHandle.standardOutput.write(Data("EXCLUSIVE-ACQUIRED\n".utf8))
        var exclusiveHeld = true
        defer {
            if exclusiveHeld { try? barrier.unlock() }
        }

        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let resolved = try schema5RetirementResolve(root: root, label: label)

        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let physicalBefore = await store!.physicalID(
            digest: identity.digest,
            partition: identity.partition
        )
        guard let physicalBefore,
            physicalBefore == resolved.entry.physicalID
        else { throw SegmentedManifestShadowError.invariantViolation }
        try await store!.remove(digest: identity.digest, partition: identity.partition)
        let physicalAfter = await store!.physicalID(
            digest: identity.digest,
            partition: identity.partition
        )
        let logicalMiss: Bool
        do {
            _ = try await store!.read(digest: identity.digest, partition: identity.partition)
            logicalMiss = false
        } catch AkashicError.notFound {
            logicalMiss = true
        }
        store = nil
        let metadataAfter = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let payloadPathExists = FileManager.default.fileExists(atPath: resolved.payloadURL.path)
        try barrier.unlock()
        exclusiveHeld = false
        let report = RetirementBarrierWriterResult(
            schemaVersion: 1,
            label: label,
            initialExclusiveWouldBlock: !immediateExclusive,
            exclusiveEventuallyAcquired: true,
            physicalBefore: physicalBefore.rawValue.uuidString.lowercased(),
            physicalAfter: physicalAfter?.rawValue.uuidString.lowercased(),
            logicalMissAfterRemove: logicalMiss,
            payloadPathExistsAfterRemove: payloadPathExists,
            profile: metadataAfter.profile,
            baseKind: metadataAfter.base.kind.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func multiProcessRetirementBarrierCheck(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--barrier",
            arguments[2] == "--kind",
            arguments[3] == "shared" || arguments[3] == "exclusive"
        else { throw SegmentedManifestShadowError.invalidArguments }
        let barrier = try MultiProcessRetirementBarrier(
            path: URL(fileURLWithPath: arguments[1], isDirectory: false)
        )
        let available: Bool
        if arguments[3] == "shared" {
            available = try barrier.tryLockShared()
        } else {
            available = try barrier.tryLockExclusive()
        }
        if available { try barrier.unlock() }
        let report = RetirementBarrierCheckResult(
            schemaVersion: 1,
            lockKind: arguments[3],
            immediatelyAvailable: available
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
