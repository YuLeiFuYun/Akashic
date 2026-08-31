import AkashicCore
import CryptoKit
import Darwin
import Foundation

/// Package-only one-descriptor checkpoint carrier candidate.
///
/// A prefix is materialized as an ordinary run blob while still non-authoritative. Finalization
/// appends one ordinary tail run plus a fixed footer to the same physical file. Recovery overlays
/// tail mutations on the prefix by logical key, then presents one bounded final mutation set to the
/// existing ownership-aware run replay.
package enum SegmentedManifestCompoundRunV1 {
    package struct Draft: Sendable {
        package let fileName: String
        package let prefixByteCount: Int
        package let prefixRecordCount: Int
        package let prefixSHA256: String
    }

    package enum FinalizeSwitchPoint: Sendable {
        case afterTailAppended
        case afterFooterAppended
        case afterFileSynced
    }

    package typealias FinalizeFaultInjector = @Sendable (FinalizeSwitchPoint) throws -> Void

    package static let footerBytes = 64
    package static let maximumPrefixRecords = SegmentedManifestPrototypeV1.maximumRunRecords - 1
    /// First research gate. This is a storage resource bound, not a host/Fovea semantic rule.
    package static let maximumAdoptedTailRecords = 128
    package static let maximumPhysicalRecords = maximumPrefixRecords + maximumAdoptedTailRecords
    package static let maximumBytes =
        2 * SegmentedManifestPrototypeV1.headerBytes
        + maximumPhysicalRecords * SegmentedManifestPrototypeV1.runRecordBytes
        + footerBytes

    private static let footerMagic = Data("AKCFV001".utf8)

    package static func writeDraft(
        prefix: [SegmentedManifestMutation],
        fileName: String,
        directory: URL
    ) throws -> Draft {
        guard !prefix.isEmpty,
            prefix.count <= maximumPrefixRecords,
            SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
                fileName,
                kind: .compoundRunV1
            )
        else { throw AkashicError.invalidManifest }
        try StorageDirectorySecurity.validateDirectory(directory)
        let data = try SegmentedManifestPrototypeV1.encodeRun(prefix)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(data, to: url)
        try StorageDirectorySecurity.validateRegularFile(url)
        return Draft(
            fileName: fileName,
            prefixByteCount: data.count,
            prefixRecordCount: prefix.count,
            prefixSHA256: hexDigest(data)
        )
    }

    package static func finalizeDraft(
        _ draft: Draft,
        tail: [SegmentedManifestMutation],
        directory: URL,
        faultInjector: FinalizeFaultInjector? = nil
    ) throws -> SegmentedManifestDescriptorV1 {
        guard draft.prefixRecordCount > 0,
            draft.prefixRecordCount <= maximumPrefixRecords,
            draft.prefixByteCount > 0,
            !tail.isEmpty,
            tail.count <= maximumAdoptedTailRecords,
            SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
                draft.fileName,
                kind: .compoundRunV1
            )
        else { throw AkashicError.invalidManifest }

        let tailData = try SegmentedManifestPrototypeV1.encodeRun(tail)
        let url = directory.appendingPathComponent(draft.fileName, isDirectory: false)
        try StorageDirectorySecurity.validateDirectory(directory)
        let descriptor = Darwin.open(url.path, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        var isOpen = true
        defer { if isOpen { _ = Darwin.close(descriptor) } }
        try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_size >= 0,
            Int64(draft.prefixByteCount) == status.st_size
        else { throw AkashicError.invalidManifest }

        let prefixData = try readExactly(
            descriptor: descriptor,
            count: draft.prefixByteCount
        )
        guard hexDigest(prefixData) == draft.prefixSHA256,
            try SegmentedManifestPrototypeV1.decodeRun(prefixData).count == draft.prefixRecordCount
        else { throw AkashicError.invalidManifest }

        var bodyHasher = SHA256()
        bodyHasher.update(data: prefixData)
        bodyHasher.update(data: tailData)
        let footer = try makeFooter(
            prefixBytes: prefixData.count,
            tailBytes: tailData.count,
            bodyDigest: Data(bodyHasher.finalize())
        )
        let finalByteCount = prefixData.count + tailData.count + footer.count
        guard finalByteCount <= maximumBytes else { throw AkashicError.invalidManifest }

        try writeAll(tailData, descriptor: descriptor)
        try faultInjector?(.afterTailAppended)
        try writeAll(footer, descriptor: descriptor)
        try faultInjector?(.afterFooterAppended)
        try synchronize(descriptor)
        try faultInjector?(.afterFileSynced)
        guard Darwin.close(descriptor) == 0 else {
            isOpen = false
            throw posixError()
        }
        isOpen = false

        try StorageDirectorySecurity.validateRegularFile(url)
        let finalized = try BoundedFileReader.read(
            from: url,
            maximumBytes: finalByteCount,
            expectedBytes: finalByteCount
        )
        return try finalizedDescriptor(fileName: draft.fileName, data: finalized)
    }

    package static func encodeFinalized(
        prefix: [SegmentedManifestMutation],
        tail: [SegmentedManifestMutation]
    ) throws -> Data {
        guard !prefix.isEmpty,
            prefix.count <= maximumPrefixRecords,
            !tail.isEmpty,
            tail.count <= maximumAdoptedTailRecords
        else { throw AkashicError.invalidManifest }
        let prefixData = try SegmentedManifestPrototypeV1.encodeRun(prefix)
        let tailData = try SegmentedManifestPrototypeV1.encodeRun(tail)
        var body = Data(capacity: prefixData.count + tailData.count)
        body.append(prefixData)
        body.append(tailData)
        body.append(
            try makeFooter(
                prefixBytes: prefixData.count,
                tailBytes: tailData.count,
                bodyDigest: Data(SHA256.hash(data: body))
            )
        )
        guard body.count <= maximumBytes else { throw AkashicError.invalidManifest }
        _ = try decode(body)
        return body
    }

    package static func decode(_ data: Data) throws -> [SegmentedManifestMutation] {
        guard data.count >= 2 * SegmentedManifestPrototypeV1.headerBytes + footerBytes,
            data.count <= maximumBytes
        else { throw AkashicError.invalidManifest }
        let footerStart = data.count - footerBytes
        let parsed = try parseFooter(Data(data[footerStart..<data.count]))
        guard parsed.prefixBytes > 0,
            parsed.tailBytes > 0,
            parsed.prefixBytes + parsed.tailBytes == footerStart
        else { throw AkashicError.invalidManifest }
        let body = Data(data[..<footerStart])
        guard Data(SHA256.hash(data: body)) == parsed.bodyDigest else {
            throw AkashicError.invalidManifest
        }
        let prefixEnd = parsed.prefixBytes
        let prefix = try SegmentedManifestPrototypeV1.decodeRun(Data(body[..<prefixEnd]))
        let tail = try SegmentedManifestPrototypeV1.decodeRun(Data(body[prefixEnd..<body.count]))
        guard prefix.count <= maximumPrefixRecords,
            tail.count <= maximumAdoptedTailRecords
        else { throw AkashicError.invalidManifest }

        var latest: [String: SegmentedManifestMutation] = [:]
        latest.reserveCapacity(
            min(SegmentedManifestPrototypeV1.maximumRunRecords, prefix.count + tail.count)
        )
        for mutation in prefix { latest[mutation.key] = mutation }
        for mutation in tail { latest[mutation.key] = mutation }
        guard !latest.isEmpty,
            latest.count <= SegmentedManifestPrototypeV1.maximumRunRecords
        else { throw AkashicError.invalidManifest }
        return latest.values.sorted { $0.key < $1.key }
    }

    package static func finalizedDescriptor(
        fileName: String,
        data: Data
    ) throws -> SegmentedManifestDescriptorV1 {
        guard SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            fileName,
            kind: .compoundRunV1
        ) else { throw AkashicError.invalidManifest }
        let logical = try decode(data)
        return SegmentedManifestDescriptorV1(
            kind: .compoundRunV1,
            fileName: fileName,
            byteCount: data.count,
            recordCount: logical.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func makeFooter(
        prefixBytes: Int,
        tailBytes: Int,
        bodyDigest: Data
    ) throws -> Data {
        guard prefixBytes > 0, tailBytes > 0, bodyDigest.count == 32 else {
            throw AkashicError.invalidManifest
        }
        var footer = Data(capacity: footerBytes)
        footer.append(footerMagic)
        footer.append(1)
        appendLittleEndian(UInt16(SegmentedManifestPrototypeV1.runRecordBytes), to: &footer)
        footer.append(Data(repeating: 0, count: 5))
        appendLittleEndian(UInt64(prefixBytes), to: &footer)
        appendLittleEndian(UInt64(tailBytes), to: &footer)
        footer.append(bodyDigest)
        guard footer.count == footerBytes else { throw AkashicError.invalidManifest }
        return footer
    }

    private static func parseFooter(
        _ footer: Data
    ) throws -> (prefixBytes: Int, tailBytes: Int, bodyDigest: Data) {
        guard footer.count == footerBytes else { throw AkashicError.invalidManifest }
        return try footer.withUnsafeBytes { raw in
            guard raw.count == footerBytes,
                raw.prefix(8).elementsEqual(footerMagic),
                raw[8] == 1,
                readUInt16(raw, offset: 9) == UInt16(SegmentedManifestPrototypeV1.runRecordBytes),
                (11..<16).allSatisfy({ raw[$0] == 0 }),
                let prefixBytes = Int(exactly: readUInt64(raw, offset: 16)),
                let tailBytes = Int(exactly: readUInt64(raw, offset: 24)),
                let base = raw.baseAddress
            else { throw AkashicError.invalidManifest }
            return (
                prefixBytes,
                tailBytes,
                Data(bytes: base.advanced(by: 32), count: 32)
            )
        }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readUInt16(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    private static func readUInt64(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(raw[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func readExactly(descriptor: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw AkashicError.storageUnavailable }
            while offset < count {
                let result = Darwin.pread(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset,
                    off_t(offset)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw AkashicError.invalidManifest }
                offset += result
            }
        }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw AkashicError.storageUnavailable }
                offset += result
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
