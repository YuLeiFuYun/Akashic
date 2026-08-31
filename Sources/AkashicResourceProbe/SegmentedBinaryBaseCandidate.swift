import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

enum SegmentedBinaryBaseCandidate {
    static let magic = Data("AKBSV001".utf8)
    static let version: UInt8 = 1
    static let headerBytes = 64
    static let recordBytes = 96
    static let maximumRecords = 100_000
    static let maximumBytes = headerBytes + recordBytes * maximumRecords

    static func encode(
        _ state: [String: SegmentedManifestEntry]
    ) throws -> Data {
        guard state.count <= maximumRecords else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let entries = state.values.sorted { $0.key < $1.key }
        var physicalIDs = Set<PhysicalBlobID>()
        physicalIDs.reserveCapacity(entries.count)
        var payload = Data(capacity: entries.count * recordBytes)
        var previousKey: String?
        for entry in entries {
            try validate(entry)
            guard previousKey.map({ entry.key > $0 }) ?? true,
                physicalIDs.insert(entry.physicalID).inserted
            else { throw SegmentedManifestShadowError.invalidFormat }
            previousKey = entry.key
            appendUUID(entry.physicalID.rawValue, to: &payload)
            payload.append(entry.partition.canonicalBytes)
            payload.append(entry.digest.bytes)
            appendLittleEndian(UInt64(entry.byteCount), to: &payload)
            appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &payload)
        }
        let expected = entries.count.multipliedReportingOverflow(by: recordBytes)
        guard !expected.overflow, payload.count == expected.partialValue else {
            throw SegmentedManifestShadowError.invalidFormat
        }

        var result = Data(capacity: headerBytes + payload.count)
        result.append(magic)
        result.append(version)
        appendLittleEndian(UInt16(recordBytes), to: &result)
        result.append(Data(repeating: 0, count: 5))
        appendLittleEndian(UInt64(entries.count), to: &result)
        appendLittleEndian(UInt64(payload.count), to: &result)
        result.append(Data(SHA256.hash(data: payload)))
        guard result.count == headerBytes else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        result.append(payload)
        guard result.count == headerBytes + recordBytes * entries.count,
            result.count <= maximumBytes
        else { throw SegmentedManifestShadowError.invalidFormat }
        return result
    }

    static func decode(
        _ data: Data
    ) throws -> [String: SegmentedManifestEntry] {
        guard data.count >= headerBytes, data.count <= maximumBytes else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return try data.withUnsafeBytes { raw -> [String: SegmentedManifestEntry] in
            guard raw.count == data.count,
                rawMatches(raw, offset: 0, data: magic),
                raw[8] == version,
                rawUInt16(raw, offset: 9) == UInt16(recordBytes),
                rawAllZero(raw, offset: 11, count: 5)
            else { throw SegmentedManifestShadowError.invalidFormat }
            let count64 = rawUInt64(raw, offset: 16)
            let payloadBytes64 = rawUInt64(raw, offset: 24)
            guard count64 <= UInt64(maximumRecords),
                payloadBytes64 == count64 * UInt64(recordBytes),
                payloadBytes64 <= UInt64(maximumBytes - headerBytes),
                let count = Int(exactly: count64),
                let payloadBytes = Int(exactly: payloadBytes64),
                data.count == headerBytes + payloadBytes
            else { throw SegmentedManifestShadowError.invalidFormat }

            let payloadDigest = SHA256.hash(data: data.dropFirst(headerBytes))
            guard payloadDigest.enumerated().allSatisfy({ index, byte in
                raw[32 + index] == byte
            }) else { throw SegmentedManifestShadowError.invalidFormat }

            var result: [String: SegmentedManifestEntry] = [:]
            result.reserveCapacity(count)
            var physicalIDs = Set<PhysicalBlobID>()
            physicalIDs.reserveCapacity(count)
            var previousKey: String?
            for index in 0..<count {
                let offset = headerBytes + index * recordBytes
                let physicalID = PhysicalBlobID(
                    rawValue: UUID(uuid: (
                        raw[offset], raw[offset + 1], raw[offset + 2], raw[offset + 3],
                        raw[offset + 4], raw[offset + 5], raw[offset + 6], raw[offset + 7],
                        raw[offset + 8], raw[offset + 9], raw[offset + 10], raw[offset + 11],
                        raw[offset + 12], raw[offset + 13], raw[offset + 14], raw[offset + 15]
                    ))
                )
                guard let base = raw.baseAddress else {
                    throw SegmentedManifestShadowError.invalidFormat
                }
                let partition = try CachePartitionID(
                    bytes: Data(bytes: base.advanced(by: offset + 16), count: 32)
                )
                let digestBytes = Data(bytes: base.advanced(by: offset + 48), count: 32)
                let byteCount64 = rawUInt64(raw, offset: offset + 80)
                let lastAccessBits = rawUInt64(raw, offset: offset + 88)
                guard byteCount64 <= UInt64(SegmentedManifestPrototypeV1.maximumBlobBytes),
                    let byteCount = Int(exactly: byteCount64)
                else { throw SegmentedManifestShadowError.invalidFormat }
                let digest = try BlobDigest(
                    algorithm: .sha256,
                    bytes: digestBytes,
                    byteCount: byteCount
                )
                let key = FileBlobStore.resourceProbeManifestKey(
                    digest: digest,
                    partition: partition
                )
                guard previousKey.map({ key > $0 }) ?? true,
                    physicalIDs.insert(physicalID).inserted
                else { throw SegmentedManifestShadowError.invalidFormat }
                previousKey = key
                let lastAccess = Double(bitPattern: lastAccessBits)
                guard lastAccess.isFinite else {
                    throw SegmentedManifestShadowError.invalidFormat
                }
                let entry = SegmentedManifestEntry(
                    key: key,
                    physicalID: physicalID,
                    partition: partition,
                    digest: digest,
                    byteCount: byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: lastAccess)
                )
                try validate(entry)
                guard result.updateValue(entry, forKey: key) == nil else {
                    throw SegmentedManifestShadowError.invalidFormat
                }
            }
            guard result.count == count else {
                throw SegmentedManifestShadowError.invalidFormat
            }
            return result
        }
    }

    private static func validate(_ entry: SegmentedManifestEntry) throws {
        guard entry.partition.canonicalBytes.count == 32,
            entry.digest.bytes.count == 32,
            entry.digest.byteCount == entry.byteCount,
            entry.byteCount >= 0,
            entry.byteCount <= SegmentedManifestPrototypeV1.maximumBlobBytes,
            entry.lastAccess.timeIntervalSinceReferenceDate.isFinite,
            entry.key == FileBlobStore.resourceProbeManifestKey(
                digest: entry.digest,
                partition: entry.partition
            )
        else { throw SegmentedManifestShadowError.invalidFormat }
    }

    private static func appendUUID(_ uuid: UUID, to data: inout Data) {
        var value = uuid.uuid
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func rawUInt16(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt16.self))
    }

    private static func rawUInt64(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        UInt64(littleEndian: raw.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt64.self))
    }

    private static func rawAllZero(
        _ raw: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> Bool {
        for index in 0..<count where raw[offset + index] != 0 { return false }
        return true
    }

    private static func rawMatches(
        _ raw: UnsafeRawBufferPointer,
        offset: Int,
        data: Data
    ) -> Bool {
        for (index, byte) in data.enumerated() where raw[offset + index] != byte {
            return false
        }
        return true
    }
}
