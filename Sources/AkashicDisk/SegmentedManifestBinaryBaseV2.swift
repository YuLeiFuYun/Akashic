import AkashicCore
import CryptoKit
import Foundation

/// Package-internal 92-byte fixed-record immutable base candidate for schema5 V3.
///
/// This is a new wire contract rather than an in-place mutation of `SegmentedManifestBinaryBaseV1`.
/// The only record-layout change is encoding byteCount as UInt32. Akashic's hard blob-size domain is
/// <= 1 GiB, so every valid store state is exactly representable while larger on-disk values remain
/// invalid.
package enum SegmentedManifestBinaryBaseV2 {
    package static let magic = Data("AKBSV002".utf8)
    package static let version: UInt8 = 2
    package static let headerBytes = 64
    package static let recordBytes = 92
    package static let maximumRecords = 100_000
    package static let maximumBlobBytes = SegmentedManifestPrototypeV1.maximumBlobBytes
    package static let maximumBytes = headerBytes + recordBytes * maximumRecords

    package static func expectedByteCount(recordCount: Int) -> Int? {
        guard recordCount >= 0, recordCount <= maximumRecords else { return nil }
        let payload = recordCount.multipliedReportingOverflow(by: recordBytes)
        guard !payload.overflow else { return nil }
        let total = headerBytes.addingReportingOverflow(payload.partialValue)
        guard !total.overflow, total.partialValue <= maximumBytes else { return nil }
        return total.partialValue
    }

    package static func encode(
        _ state: [String: SegmentedManifestEntry]
    ) throws -> Data {
        guard state.count <= maximumRecords else { throw AkashicError.invalidManifest }
        let entries = state.values.sorted { $0.key < $1.key }
        var physicalIDs = Set<PhysicalBlobID>()
        physicalIDs.reserveCapacity(entries.count)
        var payload = Data(capacity: entries.count * recordBytes)
        var previousKey: String?

        for entry in entries {
            try SegmentedManifestPrototypeV1.validate(entry)
            guard entry.byteCount >= 0,
                entry.byteCount <= maximumBlobBytes,
                let compactByteCount = UInt32(exactly: entry.byteCount),
                previousKey.map({ entry.key > $0 }) ?? true,
                physicalIDs.insert(entry.physicalID).inserted
            else { throw AkashicError.invalidManifest }
            previousKey = entry.key
            appendUUID(entry.physicalID.rawValue, to: &payload)
            payload.append(entry.partition.canonicalBytes)
            payload.append(entry.digest.bytes)
            appendLittleEndian(compactByteCount, to: &payload)
            appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &payload)
        }

        guard let expected = expectedByteCount(recordCount: entries.count),
            payload.count == expected - headerBytes
        else { throw AkashicError.invalidManifest }

        var result = Data(capacity: expected)
        result.append(magic)
        result.append(version)
        appendLittleEndian(UInt16(recordBytes), to: &result)
        result.append(Data(repeating: 0, count: 5))
        appendLittleEndian(UInt64(entries.count), to: &result)
        appendLittleEndian(UInt64(payload.count), to: &result)
        result.append(Data(SHA256.hash(data: payload)))
        guard result.count == headerBytes else { throw AkashicError.invalidManifest }
        result.append(payload)
        guard result.count == expected else { throw AkashicError.invalidManifest }
        return result
    }

    package static func decode(
        _ data: Data
    ) throws -> [String: SegmentedManifestEntry] {
        guard data.count >= headerBytes, data.count <= maximumBytes else {
            throw AkashicError.invalidManifest
        }
        return try data.withUnsafeBytes { raw -> [String: SegmentedManifestEntry] in
            guard raw.count == data.count,
                rawMatches(raw, offset: 0, data: magic),
                raw[8] == version,
                rawUInt16(raw, offset: 9) == UInt16(recordBytes),
                rawAllZero(raw, offset: 11, count: 5)
            else { throw AkashicError.invalidManifest }

            let count64 = rawUInt64(raw, offset: 16)
            let payloadBytes64 = rawUInt64(raw, offset: 24)
            guard count64 <= UInt64(maximumRecords),
                payloadBytes64 == count64 * UInt64(recordBytes),
                let count = Int(exactly: count64),
                let expected = expectedByteCount(recordCount: count),
                data.count == expected,
                payloadBytes64 == UInt64(expected - headerBytes)
            else { throw AkashicError.invalidManifest }

            let payloadDigest = SHA256.hash(data: data.dropFirst(headerBytes))
            guard payloadDigest.enumerated().allSatisfy({ index, byte in
                raw[32 + index] == byte
            }) else { throw AkashicError.invalidManifest }

            var result: [String: SegmentedManifestEntry] = [:]
            result.reserveCapacity(count)
            var physicalIDs = Set<PhysicalBlobID>()
            physicalIDs.reserveCapacity(count)
            var previousKey: String?

            guard let baseAddress = raw.baseAddress else { throw AkashicError.invalidManifest }
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
                let partition = try CachePartitionID(
                    bytes: Data(bytes: baseAddress.advanced(by: offset + 16), count: 32)
                )
                let digestBytes = Data(bytes: baseAddress.advanced(by: offset + 48), count: 32)
                let byteCount = Int(rawUInt32(raw, offset: offset + 80))
                guard byteCount <= maximumBlobBytes else { throw AkashicError.invalidManifest }
                let digest = try BlobDigest(
                    algorithm: .sha256,
                    bytes: digestBytes,
                    byteCount: byteCount
                )
                let key = FileBlobStoreIdentity.manifestKey(
                    digest: digest,
                    partition: partition
                )
                guard previousKey.map({ key > $0 }) ?? true,
                    physicalIDs.insert(physicalID).inserted
                else { throw AkashicError.invalidManifest }
                previousKey = key

                let lastAccessBits = rawUInt64(raw, offset: offset + 84)
                let lastAccessValue = Double(bitPattern: lastAccessBits)
                guard lastAccessValue.isFinite else { throw AkashicError.invalidManifest }
                let entry = SegmentedManifestEntry(
                    key: key,
                    physicalID: physicalID,
                    partition: partition,
                    digest: digest,
                    byteCount: byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: lastAccessValue)
                )
                try SegmentedManifestPrototypeV1.validate(entry)
                guard result.updateValue(entry, forKey: key) == nil else {
                    throw AkashicError.invalidManifest
                }
            }
            guard result.count == count else { throw AkashicError.invalidManifest }
            return result
        }
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

    private static func rawUInt32(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt32.self))
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
