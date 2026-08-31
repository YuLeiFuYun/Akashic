import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func multiProcessRetirementLocalWriterRemoteReader(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        let required = [
            "--barrier", "--ready",
            "--finish-one", "--result-one",
            "--finish-two", "--result-two",
            "--release-writer", "--writer-released",
        ]
        guard required.allSatisfy({ values[$0] != nil }) else {
            throw SegmentedManifestShadowError.invalidArguments
        }

        let coordinator = try RetirementLocalReaderCoordinator(
            path: URL(fileURLWithPath: values["--barrier"]!, isDirectory: false)
        )
        guard try coordinator.beginWriterIntent() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "writer-pending-gate-held-no-local-readers",
                acquired: false,
                readerCount: 0,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--ready"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REMOTE-WRITER-READY-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--finish-one"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let first = try coordinator.tryFinishWriterAcquire()
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "first-finish",
                acquired: first.acquired,
                readerCount: first.readerCount,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--result-one"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REMOTE-WRITER-FIRST-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--finish-two"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = try coordinator.tryFinishWriterAcquire()
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "second-finish",
                acquired: second.acquired,
                readerCount: second.readerCount,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--result-two"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REMOTE-WRITER-SECOND-SETTLED\n".utf8))

        while !FileManager.default.fileExists(atPath: values["--release-writer"]!) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try coordinator.releaseWriter()
        try schema5RetirementWriteJSON(
            RetirementLocalWriterState(
                schemaVersion: 1,
                phase: "writer-released",
                acquired: false,
                readerCount: 0,
                readerAdmissionWhileWriterActive: nil
            ),
            to: URL(fileURLWithPath: values["--writer-released"]!, isDirectory: false)
        )
        FileHandle.standardOutput.write(Data("LOCAL-REMOTE-WRITER-RELEASED-SETTLED\n".utf8))
    }

    static func schema5RetirementResolve(
        root: URL,
        label: String
    ) throws -> (root: SegmentedManifestRootV1, entry: SegmentedManifestEntry, payloadURL: URL) {
        let identity = try schema5MigrationIdentities(labels: [label])[0]
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let metadata = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard metadata.profile == SegmentedManifestPrototypeV1.profileV3,
            metadata.base.kind == .baseBinaryV2
        else { throw SegmentedManifestShadowError.invariantViolation }
        let state = try SegmentedManifestPrototypeV1.recover(
            root: metadata,
            segmentDirectory: segmentDirectory
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
        return (metadata, entry, payloadURL)
    }

    static func schema5RetirementReadDescriptor(
        _ descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw schema5RetirementPOSIXError()
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
                    throw schema5RetirementPOSIXError()
                }
                guard result > 0 else { throw AkashicError.integrityMismatch }
                offset += result
            }
        }
        return data
    }

    static func schema5RetirementWriteJSON<T: Encodable>(
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

    static func schema5RetirementPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
