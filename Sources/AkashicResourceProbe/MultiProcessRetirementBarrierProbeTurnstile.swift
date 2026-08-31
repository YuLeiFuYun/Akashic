import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func multiProcessRetirementTurnstileReader(arguments: [String]) async throws {
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
        let barrier = try MultiProcessRetirementBarrier(
            path: URL(fileURLWithPath: barrierPath, isDirectory: false)
        )
        try barrier.lockShared(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        var gateHeld = true
        var retirementHeld = false
        defer {
            if retirementHeld {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.retirement,
                    length: RetirementTurnstileRange.length
                )
            }
            if gateHeld {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.gate,
                    length: RetirementTurnstileRange.length
                )
            }
        }
        try barrier.lockShared(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        retirementHeld = true
        try barrier.unlock(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        gateHeld = false

        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let resolved = try schema5RetirementResolve(root: root, label: label)
        let readyURL = URL(fileURLWithPath: readyPath, isDirectory: false)
        try schema5RetirementWriteJSON(
            RetirementTurnstileReaderReady(
                schemaVersion: 1,
                pid: ProcessInfo.processInfo.processIdentifier,
                label: label,
                physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
                byteCount: resolved.entry.byteCount,
                gateReleased: true,
                retirementSharedHeld: true,
                profile: resolved.root.profile,
                baseKind: resolved.root.base.kind.rawValue
            ),
            to: readyURL
        )
        FileHandle.standardOutput.write(Data("TURNSTILE-READER-READY-SETTLED\n".utf8))

        let openSignalURL = URL(fileURLWithPath: openSignalPath, isDirectory: false)
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
        try barrier.unlock(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        retirementHeld = false

        let fdOpenedURL = URL(fileURLWithPath: fdOpenedPath, isDirectory: false)
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
        FileHandle.standardOutput.write(Data("TURNSTILE-FD-OPENED-SETTLED\n".utf8))

        let readSignalURL = URL(fileURLWithPath: readSignalPath, isDirectory: false)
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
        try schema5RetirementWriteJSON(
            result,
            to: URL(fileURLWithPath: resultPath, isDirectory: false)
        )
    }

    static func multiProcessRetirementTurnstileRemove(arguments: [String]) async throws {
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
        let barrier = try MultiProcessRetirementBarrier(
            path: URL(fileURLWithPath: barrierPath, isDirectory: false)
        )
        let gateImmediate = try barrier.tryLockExclusive(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        if !gateImmediate {
            try barrier.lockExclusive(
                start: RetirementTurnstileRange.gate,
                length: RetirementTurnstileRange.length
            )
        }
        var gateHeld = true
        var retirementHeld = false
        defer {
            if retirementHeld {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.retirement,
                    length: RetirementTurnstileRange.length
                )
            }
            if gateHeld {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.gate,
                    length: RetirementTurnstileRange.length
                )
            }
        }
        FileHandle.standardOutput.write(Data("TURNSTILE-GATE-ACQUIRED\n".utf8))

        let retirementImmediate = try barrier.tryLockExclusive(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        if retirementImmediate {
            retirementHeld = true
            FileHandle.standardOutput.write(Data("TURNSTILE-RETIREMENT-ACQUIRED-IMMEDIATE\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data("TURNSTILE-RETIREMENT-WOULD-BLOCK\n".utf8))
            try barrier.lockExclusive(
                start: RetirementTurnstileRange.retirement,
                length: RetirementTurnstileRange.length
            )
            retirementHeld = true
            FileHandle.standardOutput.write(Data("TURNSTILE-RETIREMENT-ACQUIRED\n".utf8))
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
        try barrier.unlock(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        retirementHeld = false
        try barrier.unlock(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        gateHeld = false

        let report = RetirementTurnstileWriterResult(
            schemaVersion: 1,
            label: label,
            gateInitiallyAvailable: gateImmediate,
            retirementInitiallyWouldBlock: !retirementImmediate,
            retirementEventuallyAcquired: true,
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

    static func multiProcessRetirementTurnstileCheck(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let barrierPath = values["--barrier"],
            let rangeName = values["--range"],
            rangeName == "gate" || rangeName == "retirement",
            let kind = values["--kind"],
            kind == "shared" || kind == "exclusive"
        else { throw SegmentedManifestShadowError.invalidArguments }
        let start = rangeName == "gate"
            ? RetirementTurnstileRange.gate
            : RetirementTurnstileRange.retirement
        let barrier = try MultiProcessRetirementBarrier(
            path: URL(fileURLWithPath: barrierPath, isDirectory: false)
        )
        let available: Bool
        if kind == "shared" {
            available = try barrier.tryLockShared(
                start: start,
                length: RetirementTurnstileRange.length
            )
        } else {
            available = try barrier.tryLockExclusive(
                start: start,
                length: RetirementTurnstileRange.length
            )
        }
        if available {
            try barrier.unlock(start: start, length: RetirementTurnstileRange.length)
        }
        let report = RetirementTurnstileCheckResult(
            schemaVersion: 1,
            range: rangeName,
            lockKind: kind,
            immediatelyAvailable: available
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
