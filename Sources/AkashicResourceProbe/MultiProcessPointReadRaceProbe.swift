import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum MultiProcessPointReadPhase: String, Codable {
    case resolveThenOpen = "resolve-then-open"
    case openThenRead = "open-then-read"
}

private struct MultiProcessPointReadReady: Codable {
    let schemaVersion: Int
    let pid: Int32
    let phase: MultiProcessPointReadPhase
    let label: String
    let manifestKey: String
    let physicalID: String
    let byteCount: Int
    let payloadPathExists: Bool
    let descriptorOpenedBeforeReady: Bool
    let profile: String
    let baseKind: String
}

private struct MultiProcessPointReadResult: Codable {
    let schemaVersion: Int
    let phase: MultiProcessPointReadPhase
    let label: String
    let physicalID: String
    let payloadPathExistsAfterWriter: Bool
    let outcome: String
    let bytesRead: Int
    let payloadExact: Bool
    let digestExact: Bool
}

private struct MultiProcessPointReadRemoveResult: Codable {
    let schemaVersion: Int
    let label: String
    let physicalBefore: String?
    let physicalAfter: String?
    let payloadPathExistsAfterRemove: Bool
    let logicalMissAfterRemove: Bool
    let profile: String
    let baseKind: String
}

extension SegmentedManifestShadowProbe {
    static func multiProcessPointReadWait(arguments: [String]) async throws {
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
            let phaseRaw = values["--phase"],
            let phase = MultiProcessPointReadPhase(rawValue: phaseRaw),
            let readyPath = values["--ready"],
            let goPath = values["--go"],
            let resultPath = values["--result"]
        else { throw SegmentedManifestShadowError.invalidArguments }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let ready = URL(fileURLWithPath: readyPath, isDirectory: false)
        let go = URL(fileURLWithPath: goPath, isDirectory: false)
        let result = URL(fileURLWithPath: resultPath, isDirectory: false)
        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let metadata = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard metadata.profile == SegmentedManifestPrototypeV1.profileV3,
            metadata.base.kind == .baseBinaryV2
        else { throw SegmentedManifestShadowError.invariantViolation }
        let state = try SegmentedManifestPrototypeV1.recover(
            root: metadata,
            segmentDirectory: segments
        )
        guard let entry = state[identity.key],
            entry.partition == identity.partition,
            entry.digest == identity.digest,
            entry.byteCount == identity.data.count
        else { throw SegmentedManifestShadowError.invariantViolation }
        let payloadURL = root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(
                entry.physicalID.rawValue.uuidString.lowercased(),
                isDirectory: false
            )

        var descriptor: Int32 = -1
        if phase == .openThenRead {
            descriptor = Darwin.open(payloadURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw schema5PointReadPOSIXError() }
            do {
                let status = try StorageDirectorySecurity.validatedOpenedPrivateRegularFileStatus(descriptor)
                guard status.st_size == entry.byteCount else {
                    throw AkashicError.integrityMismatch
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
        }

        try schema5PointReadWriteJSON(
            MultiProcessPointReadReady(
                schemaVersion: 1,
                pid: ProcessInfo.processInfo.processIdentifier,
                phase: phase,
                label: label,
                manifestKey: identity.key,
                physicalID: entry.physicalID.rawValue.uuidString.lowercased(),
                byteCount: entry.byteCount,
                payloadPathExists: FileManager.default.fileExists(atPath: payloadURL.path),
                descriptorOpenedBeforeReady: descriptor >= 0,
                profile: metadata.profile,
                baseKind: metadata.base.kind.rawValue
            ),
            to: ready
        )
        FileHandle.standardOutput.write(Data("READY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: go.path) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let pathExistsAfterWriter = FileManager.default.fileExists(atPath: payloadURL.path)
        let readData: Data?
        let outcome: String
        do {
            switch phase {
            case .resolveThenOpen:
                readData = try BoundedFileReader.read(
                    from: payloadURL,
                    maximumBytes: entry.byteCount,
                    expectedBytes: entry.byteCount
                )
            case .openThenRead:
                readData = try schema5PointReadDescriptor(
                    descriptor,
                    byteCount: entry.byteCount
                )
            }
            outcome = "success"
        } catch let error as POSIXError where error.code == .ENOENT {
            readData = nil
            outcome = "enoent"
        } catch AkashicError.storageUnavailable {
            readData = nil
            outcome = "storageUnavailable"
        } catch {
            readData = nil
            outcome = "other-error:\(String(describing: error))"
        }
        let payloadExact = readData == identity.data
        let digestExact = readData.map { BlobDigest.sha256(of: $0) == identity.digest } ?? false
        try schema5PointReadWriteJSON(
            MultiProcessPointReadResult(
                schemaVersion: 1,
                phase: phase,
                label: label,
                physicalID: entry.physicalID.rawValue.uuidString.lowercased(),
                payloadPathExistsAfterWriter: pathExistsAfterWriter,
                outcome: outcome,
                bytesRead: readData?.count ?? 0,
                payloadExact: payloadExact,
                digestExact: digestExact
            ),
            to: result
        )
    }

    static func multiProcessPointReadRemove(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--label"
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let label = arguments[3]
        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let metadataBefore = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        guard metadataBefore.profile == SegmentedManifestPrototypeV1.profileV3,
            metadataBefore.base.kind == .baseBinaryV2
        else { throw SegmentedManifestShadowError.invariantViolation }
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let physicalBefore = await store!.physicalID(
            digest: identity.digest,
            partition: identity.partition
        )
        guard let physicalBefore else { throw SegmentedManifestShadowError.invariantViolation }
        let payloadURL = root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(
                physicalBefore.rawValue.uuidString.lowercased(),
                isDirectory: false
            )
        try await store!.remove(digest: identity.digest, partition: identity.partition)
        let physicalAfter = await store!.physicalID(
            digest: identity.digest,
            partition: identity.partition
        )
        let logicalMiss: Bool
        do {
            _ = try await store!.read(
                digest: identity.digest,
                partition: identity.partition
            )
            logicalMiss = false
        } catch AkashicError.notFound {
            logicalMiss = true
        }
        store = nil
        let metadataAfter = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = MultiProcessPointReadRemoveResult(
            schemaVersion: 1,
            label: label,
            physicalBefore: physicalBefore.rawValue.uuidString.lowercased(),
            physicalAfter: physicalAfter?.rawValue.uuidString.lowercased(),
            payloadPathExistsAfterRemove: FileManager.default.fileExists(atPath: payloadURL.path),
            logicalMissAfterRemove: logicalMiss,
            profile: metadataAfter.profile,
            baseKind: metadataAfter.base.kind.rawValue
        )
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5PointReadDescriptor(
        _ descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        guard descriptor >= 0 else { throw AkashicError.storageUnavailable }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw schema5PointReadPOSIXError()
        }
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < byteCount {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw schema5PointReadPOSIXError()
                }
                guard result > 0 else { throw AkashicError.integrityMismatch }
                offset += result
            }
        }
        return data
    }

    private static func schema5PointReadWriteJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value) + Data([0x0A])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try DurableFileWriter.writeReplacing(data, to: url)
    }

    private static func schema5PointReadPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
