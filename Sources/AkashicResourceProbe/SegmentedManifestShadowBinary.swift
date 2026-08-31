import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

extension SegmentedManifestShadowProbe {
    static func unframe(_ data: Data) throws -> (UInt8, Int, Int, Data) {
        guard data.count >= headerBytes else { throw SegmentedManifestShadowError.invalidFormat }
        var cursor = 0
        guard take(8, from: data, cursor: &cursor) == magic else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        guard let kind = take(1, from: data, cursor: &cursor).first else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let recordBytes16: UInt16 = try readLittleEndian(from: data, cursor: &cursor)
        let headerReserved = take(5, from: data, cursor: &cursor)
        guard headerReserved.count == 5, headerReserved.allSatisfy({ $0 == 0 }) else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let count64: UInt64 = try readLittleEndian(from: data, cursor: &cursor)
        let payloadBytes64: UInt64 = try readLittleEndian(from: data, cursor: &cursor)
        let expectedHash = take(32, from: data, cursor: &cursor)
        guard cursor == headerBytes,
            count64 <= UInt64(Int.max),
            payloadBytes64 <= UInt64(Int.max)
        else { throw SegmentedManifestShadowError.invalidFormat }
        let count = Int(count64)
        let recordBytes = Int(recordBytes16)
        let payloadBytes = Int(payloadBytes64)
        let expectedLength = count.multipliedReportingOverflow(by: recordBytes)
        guard !expectedLength.overflow,
            expectedLength.partialValue == payloadBytes,
            data.count == headerBytes + payloadBytes
        else { throw SegmentedManifestShadowError.invalidFormat }
        let payload = data.subdata(in: headerBytes..<data.count)
        guard Data(SHA256.hash(data: payload)) == expectedHash else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return (kind, recordBytes, count, payload)
    }

    static func appendKey(_ key: String, to data: inout Data) throws {
        guard key.utf8.count == 64,
            let decoded = Data(hexLowercase: key),
            decoded.count == 32
        else { throw SegmentedManifestShadowError.invalidFormat }
        data.append(decoded)
    }

    static func readKey(_ data: Data, cursor: inout Int) throws -> String {
        let bytes = take(32, from: data, cursor: &cursor)
        guard bytes.count == 32 else { throw SegmentedManifestShadowError.invalidFormat }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func appendUUID(_ uuid: UUID, to data: inout Data) {
        let value = uuid.uuid
        data.append(contentsOf: [
            value.0, value.1, value.2, value.3, value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11, value.12, value.13, value.14, value.15,
        ])
    }

    static func readUUID(_ data: Data, cursor: inout Int) throws -> UUID {
        let bytes = [UInt8](take(16, from: data, cursor: &cursor))
        guard bytes.count == 16 else { throw SegmentedManifestShadowError.invalidFormat }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    static func readLittleEndian<T: FixedWidthInteger>(
        from data: Data,
        cursor: inout Int
    ) throws -> T {
        let width = MemoryLayout<T>.size
        let bytes = [UInt8](take(width, from: data, cursor: &cursor))
        guard bytes.count == width else { throw SegmentedManifestShadowError.invalidFormat }
        var value: T = 0
        for (offset, byte) in bytes.enumerated() {
            value |= T(byte) << T(offset * 8)
        }
        return value
    }

    static func take(_ count: Int, from data: Data, cursor: inout Int) -> Data {
        guard count >= 0, cursor >= 0, cursor <= data.count, count <= data.count - cursor else {
            cursor = data.count + 1
            return Data()
        }
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }
}

private extension Data {
    init?(hexLowercase string: String) {
        guard string.count % 2 == 0, string.allSatisfy({ $0.isNumber || ($0 >= "a" && $0 <= "f") }) else {
            return nil
        }
        var result = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let value = UInt8(string[index..<next], radix: 16) else { return nil }
            result.append(value)
            index = next
        }
        self = result
    }
}
