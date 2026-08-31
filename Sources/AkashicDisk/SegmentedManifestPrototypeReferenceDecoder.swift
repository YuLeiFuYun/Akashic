import AkashicCore
import CryptoKit
import Foundation

extension SegmentedManifestPrototypeV1 {
    /// Research-only semantic reference retained while the raw-buffer V1 decoder is qualified.
    /// This intentionally preserves the former subdata/formatting implementation.
    package static func resourceProbeDecodeRunReference(
        _ data: Data
    ) throws -> [SegmentedManifestMutation] {
        guard data.count >= headerBytes, data.count <= maximumRunBytes else {
            throw AkashicError.invalidManifest
        }
        var cursor = 0
        guard referenceTake(runMagic.count, from: data, cursor: &cursor) == runMagic else {
            throw AkashicError.invalidManifest
        }
        let kind = referenceTake(1, from: data, cursor: &cursor).first
        let recordBytes: UInt16 = try referenceReadLittleEndian(from: data, cursor: &cursor)
        let reserved = referenceTake(5, from: data, cursor: &cursor)
        let count64: UInt64 = try referenceReadLittleEndian(from: data, cursor: &cursor)
        let payloadBytes64: UInt64 = try referenceReadLittleEndian(from: data, cursor: &cursor)
        let payloadHash = referenceTake(32, from: data, cursor: &cursor)
        guard kind == 1,
            recordBytes == UInt16(runRecordBytes),
            reserved.count == 5,
            reserved.allSatisfy({ $0 == 0 }),
            count64 > 0,
            count64 <= UInt64(maximumRunRecords),
            payloadBytes64 == count64 * UInt64(runRecordBytes),
            payloadBytes64 <= UInt64(maximumRunBytes - headerBytes),
            cursor == headerBytes,
            let payloadBytes = Int(exactly: payloadBytes64),
            data.count == headerBytes + payloadBytes
        else { throw AkashicError.invalidManifest }
        let payload = data.subdata(in: headerBytes..<data.count)
        guard Data(SHA256.hash(data: payload)) == payloadHash,
            let count = Int(exactly: count64)
        else { throw AkashicError.invalidManifest }

        cursor = 0
        var result: [SegmentedManifestMutation] = []
        result.reserveCapacity(count)
        var previousKey: String?
        for _ in 0..<count {
            let key = try referenceReadManifestKey(payload, cursor: &cursor)
            if let previousKey, key <= previousKey { throw AkashicError.invalidManifest }
            previousKey = key
            guard let tag = referenceTake(1, from: payload, cursor: &cursor).first else {
                throw AkashicError.invalidManifest
            }
            let tagReserved = referenceTake(7, from: payload, cursor: &cursor)
            guard tagReserved.count == 7, tagReserved.allSatisfy({ $0 == 0 }) else {
                throw AkashicError.invalidManifest
            }
            if tag == 0 {
                let tombstoneReserved = referenceTake(96, from: payload, cursor: &cursor)
                guard tombstoneReserved.count == 96,
                    tombstoneReserved.allSatisfy({ $0 == 0 })
                else { throw AkashicError.invalidManifest }
                result.append(.tombstone(key: key))
                continue
            }
            guard tag == 1 else { throw AkashicError.invalidManifest }
            let physicalID = PhysicalBlobID(rawValue: try referenceReadUUID(payload, cursor: &cursor))
            let partition = try CachePartitionID(
                bytes: referenceTake(32, from: payload, cursor: &cursor)
            )
            let digestBytes = referenceTake(32, from: payload, cursor: &cursor)
            let byteCount64: UInt64 = try referenceReadLittleEndian(from: payload, cursor: &cursor)
            let lastAccessBits: UInt64 = try referenceReadLittleEndian(from: payload, cursor: &cursor)
            guard byteCount64 <= UInt64(maximumBlobBytes),
                let byteCount = Int(exactly: byteCount64)
            else { throw AkashicError.invalidManifest }
            let digest = try BlobDigest(
                algorithm: .sha256,
                bytes: digestBytes,
                byteCount: byteCount
            )
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
            try validate(entry)
            result.append(.upsert(entry))
        }
        guard cursor == payload.count else { throw AkashicError.invalidManifest }
        return result
    }

    private static func referenceReadManifestKey(
        _ data: Data, cursor: inout Int
    ) throws -> String {
        let bytes = referenceTake(32, from: data, cursor: &cursor)
        guard bytes.count == 32 else { throw AkashicError.invalidManifest }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func referenceReadUUID(_ data: Data, cursor: inout Int) throws -> UUID {
        let bytes = referenceTake(16, from: data, cursor: &cursor)
        guard bytes.count == 16 else { throw AkashicError.invalidManifest }
        let array = Array(bytes)
        return UUID(uuid: (
            array[0], array[1], array[2], array[3], array[4], array[5], array[6], array[7],
            array[8], array[9], array[10], array[11], array[12], array[13], array[14], array[15]
        ))
    }

    private static func referenceTake(
        _ count: Int, from data: Data, cursor: inout Int
    ) -> Data {
        guard count >= 0, cursor >= 0, cursor <= data.count - count else { return Data() }
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }

    private static func referenceReadLittleEndian<T: FixedWidthInteger>(
        from data: Data,
        cursor: inout Int
    ) throws -> T {
        let width = MemoryLayout<T>.size
        let bytes = referenceTake(width, from: data, cursor: &cursor)
        guard bytes.count == width else { throw AkashicError.invalidManifest }
        return bytes.withUnsafeBytes { raw in
            T(littleEndian: raw.loadUnaligned(as: T.self))
        }
    }
}
