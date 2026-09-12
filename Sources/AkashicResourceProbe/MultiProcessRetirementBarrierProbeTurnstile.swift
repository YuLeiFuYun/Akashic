import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct RetirementTurnstileReaderInput {
    let root: URL
    let label: String
    let barrier: URL
    let ready: URL
    let openSignal: URL
    let fdOpened: URL
    let readSignal: URL
    let result: URL
}

extension SegmentedManifestShadowProbe {
    static func multiProcessRetirementTurnstileReader(arguments: [String]) async throws {
        let input = try retirementTurnstileReaderInput(arguments)
        let barrier = try MultiProcessRetirementBarrier(path: input.barrier)
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

        let identity = try schema5MigrationIdentities(labels: [input.label])[0]
        let resolved = try schema5RetirementResolve(root: input.root, label: input.label)
        try emitRetirementTurnstileReaderReady(input: input, resolved: resolved)
        let descriptor = try await openRetirementTurnstileDescriptor(
            input: input,
            resolved: resolved,
            barrier: barrier
        )
        retirementHeld = false
        defer { _ = Darwin.close(descriptor) }
        try await finishRetirementTurnstileReader(
            input: input,
            resolved: resolved,
            identity: identity,
            descriptor: descriptor
        )
    }

    private static func retirementTurnstileReaderInput(
        _ arguments: [String]
    ) throws -> RetirementTurnstileReaderInput {
        let values = try retirementArgumentValues(arguments)
        guard let rootPath = values["--root"],
            let label = values["--label"],
            let barrierPath = values["--barrier"],
            let readyPath = values["--ready"],
            let openSignalPath = values["--open-signal"],
            let fdOpenedPath = values["--fd-opened"],
            let readSignalPath = values["--read-signal"],
            let resultPath = values["--result"]
        else { throw SegmentedManifestShadowError.invalidArguments }
        return RetirementTurnstileReaderInput(
            root: URL(fileURLWithPath: rootPath, isDirectory: true),
            label: label,
            barrier: URL(fileURLWithPath: barrierPath, isDirectory: false),
            ready: URL(fileURLWithPath: readyPath, isDirectory: false),
            openSignal: URL(fileURLWithPath: openSignalPath, isDirectory: false),
            fdOpened: URL(fileURLWithPath: fdOpenedPath, isDirectory: false),
            readSignal: URL(fileURLWithPath: readSignalPath, isDirectory: false),
            result: URL(fileURLWithPath: resultPath, isDirectory: false)
        )
    }

    private static func emitRetirementTurnstileReaderReady(
        input: RetirementTurnstileReaderInput,
        resolved: (root: SegmentedManifestRootV1, entry: SegmentedManifestEntry, payloadURL: URL)
    ) throws {
        try schema5RetirementWriteJSON(
            RetirementTurnstileReaderReady(
                schemaVersion: 1,
                pid: ProcessInfo.processInfo.processIdentifier,
                label: input.label,
                physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
                byteCount: resolved.entry.byteCount,
                gateReleased: true,
                retirementSharedHeld: true,
                profile: resolved.root.profile,
                baseKind: resolved.root.base.kind.rawValue
            ),
            to: input.ready
        )
        FileHandle.standardOutput.write(Data("TURNSTILE-READER-READY-SETTLED\n".utf8))
    }

    private static func openRetirementTurnstileDescriptor(
        input: RetirementTurnstileReaderInput,
        resolved: (root: SegmentedManifestRootV1, entry: SegmentedManifestEntry, payloadURL: URL),
        barrier: MultiProcessRetirementBarrier
    ) async throws -> Int32 {
        while !FileManager.default.fileExists(atPath: input.openSignal.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let descriptor = Darwin.open(
            resolved.payloadURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw schema5RetirementPOSIXError() }
        do {
            let status = try StorageDirectorySecurity.validatedOpenedPrivateRegularFileStatus(descriptor)
            guard status.st_size >= 0,
                UInt64(status.st_size) == UInt64(resolved.entry.byteCount)
            else { throw AkashicError.integrityMismatch }
            let pathExistsAtOpen = FileManager.default.fileExists(atPath: resolved.payloadURL.path)
            try barrier.unlock(
                start: RetirementTurnstileRange.retirement,
                length: RetirementTurnstileRange.length
            )
            try schema5RetirementWriteJSON(
                RetirementBarrierFDOpened(
                    schemaVersion: 1,
                    label: input.label,
                    physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
                    descriptorValidated: true,
                    sharedBarrierReleased: true,
                    payloadPathExistsAtOpen: pathExistsAtOpen
                ),
                to: input.fdOpened
            )
            FileHandle.standardOutput.write(Data("TURNSTILE-FD-OPENED-SETTLED\n".utf8))
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func finishRetirementTurnstileReader(
        input: RetirementTurnstileReaderInput,
        resolved: (root: SegmentedManifestRootV1, entry: SegmentedManifestEntry, payloadURL: URL),
        identity: MigrationIdentity,
        descriptor: Int32
    ) async throws {
        while !FileManager.default.fileExists(atPath: input.readSignal.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let data = try schema5RetirementReadDescriptor(
            descriptor,
            byteCount: resolved.entry.byteCount
        )
        let result = RetirementBarrierReaderResult(
            schemaVersion: 1,
            label: input.label,
            physicalID: resolved.entry.physicalID.rawValue.uuidString.lowercased(),
            payloadPathExistsAfterWriter: FileManager.default.fileExists(
                atPath: resolved.payloadURL.path
            ),
            bytesRead: data.count,
            payloadExact: data == identity.data,
            digestExact: BlobDigest.sha256(of: data) == identity.digest
        )
        try schema5RetirementWriteJSON(result, to: input.result)
    }

    static func multiProcessRetirementTurnstileRemove(arguments: [String]) async throws {
        let values = try retirementArgumentValues(arguments)
        guard let rootPath = values["--root"],
            let label = values["--label"],
            let barrierPath = values["--barrier"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let barrier = try MultiProcessRetirementBarrier(
            path: URL(fileURLWithPath: barrierPath, isDirectory: false)
        )
        let gateImmediate = try acquireRetirementTurnstileGate(
            barrier: barrier,
            markerPath: values["--gate-acquired"]
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

        let retirementImmediate = try acquireRetirementTurnstileRetirement(
            barrier: barrier,
            markerPath: values["--retirement-state"]
        )
        retirementHeld = true
        let removal = try await removeRetirementTurnstilePayload(root: root, label: label)
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
            physicalBefore: removal.physicalBefore.rawValue.uuidString.lowercased(),
            physicalAfter: removal.physicalAfter?.rawValue.uuidString.lowercased(),
            logicalMissAfterRemove: removal.logicalMiss,
            payloadPathExistsAfterRemove: removal.payloadPathExists,
            profile: removal.metadata.profile,
            baseKind: removal.metadata.base.kind.rawValue
        )
        try emitRetirementTurnstileWriterReport(report, resultPath: values["--result"])
    }

    private static func acquireRetirementTurnstileGate(
        barrier: MultiProcessRetirementBarrier,
        markerPath: String?
    ) throws -> Bool {
        let immediate = try barrier.tryLockExclusive(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        if !immediate {
            try barrier.lockExclusive(
                start: RetirementTurnstileRange.gate,
                length: RetirementTurnstileRange.length
            )
        }
        FileHandle.standardOutput.write(Data("TURNSTILE-GATE-ACQUIRED\n".utf8))
        do {
            try emitRetirementTurnstileWriterPhase(markerPath, phase: "gate-acquired")
        } catch {
            try? barrier.unlock(
                start: RetirementTurnstileRange.gate,
                length: RetirementTurnstileRange.length
            )
            throw error
        }
        return immediate
    }

    private static func acquireRetirementTurnstileRetirement(
        barrier: MultiProcessRetirementBarrier,
        markerPath: String?
    ) throws -> Bool {
        let immediate = try barrier.tryLockExclusive(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        if immediate {
            FileHandle.standardOutput.write(Data("TURNSTILE-RETIREMENT-ACQUIRED-IMMEDIATE\n".utf8))
            do {
                try emitRetirementTurnstileWriterPhase(
                    markerPath,
                    phase: "retirement-acquired-immediate"
                )
            } catch {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.retirement,
                    length: RetirementTurnstileRange.length
                )
                throw error
            }
            return true
        }

        FileHandle.standardOutput.write(Data("TURNSTILE-RETIREMENT-WOULD-BLOCK\n".utf8))
        try emitRetirementTurnstileWriterPhase(markerPath, phase: "retirement-would-block")
        try barrier.lockExclusive(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        FileHandle.standardOutput.write(Data("TURNSTILE-RETIREMENT-ACQUIRED\n".utf8))
        return false
    }

    private static func emitRetirementTurnstileWriterPhase(
        _ markerPath: String?,
        phase: String
    ) throws {
        guard let markerPath else { return }
        try schema5RetirementWriteJSON(
            RetirementTurnstileWriterPhaseState(
                schemaVersion: 1,
                pid: ProcessInfo.processInfo.processIdentifier,
                phase: phase
            ),
            to: URL(fileURLWithPath: markerPath, isDirectory: false)
        )
    }

    private static func removeRetirementTurnstilePayload(
        root: URL,
        label: String
    ) async throws -> (
        physicalBefore: PhysicalBlobID,
        physicalAfter: PhysicalBlobID?,
        logicalMiss: Bool,
        payloadPathExists: Bool,
        metadata: SegmentedManifestRootV1
    ) {
        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let resolved = try schema5RetirementResolve(root: root, label: label)
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        guard let physicalBefore = await store!.physicalID(
            digest: identity.digest,
            partition: identity.partition
        ), physicalBefore == resolved.entry.physicalID else {
            throw SegmentedManifestShadowError.invariantViolation
        }
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
        let metadata = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        return (
            physicalBefore,
            physicalAfter,
            logicalMiss,
            FileManager.default.fileExists(atPath: resolved.payloadURL.path),
            metadata
        )
    }

    private static func emitRetirementTurnstileWriterReport(
        _ report: RetirementTurnstileWriterResult,
        resultPath: String?
    ) throws {
        if let resultPath {
            try schema5RetirementWriteJSON(
                report,
                to: URL(fileURLWithPath: resultPath, isDirectory: false)
            )
        }
        try writeRetirementResult(report)
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
        try writeRetirementResult(report)
    }
}
