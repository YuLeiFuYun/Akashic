import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

extension SegmentedManifestShadowProbe {
    static func binaryBaseCandidateState(
        count: Int,
        seed: Int
    ) throws -> [String: SegmentedManifestEntry] {
        guard count >= 0, count <= SegmentedBinaryBaseCandidate.maximumRecords, seed >= 0 else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let payloadSizes = [0, 1, 16, 64, 1024, 64 * 1024]
        var state: [String: SegmentedManifestEntry] = [:]
        state.reserveCapacity(count)
        for index in 0..<count {
            let partition = try CachePartitionID.derive(
                domain: "resource-binary-base-candidate-v1",
                material: Data("seed-\(seed)-partition-\(index)".utf8)
            )
            let payloadSize = payloadSizes[(seed + index) % payloadSizes.count]
            let payload: Data
            if payloadSize == 0 {
                payload = Data()
            } else {
                payload = Data(
                    repeating: UInt8(truncatingIfNeeded: seed &* 31 &+ index &* 17),
                    count: payloadSize
                )
            }
            let digest = BlobDigest.sha256(of: payload)
            let key = FileBlobStore.resourceProbeManifestKey(
                digest: digest,
                partition: partition
            )
            let logicalIndex = seed.multipliedReportingOverflow(by: 100_003)
            guard !logicalIndex.overflow else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            let physicalIndex = logicalIndex.partialValue.addingReportingOverflow(index)
            guard !physicalIndex.overflow else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            let entry = SegmentedManifestEntry(
                key: key,
                physicalID: schema5CompactionResourcePhysicalID(
                    index: physicalIndex.partialValue,
                    version: 1 + seed % 65_000
                ),
                partition: partition,
                digest: digest,
                byteCount: payload.count,
                lastAccess: Date(
                    timeIntervalSinceReferenceDate:
                        700_000_000 + Double(seed) + Double(index) / 10_000
                )
            )
            guard state.updateValue(entry, forKey: key) == nil else {
                throw SegmentedManifestShadowError.invariantViolation
            }
        }
        return state
    }

    static func binaryBaseCandidateJSON(
        _ state: [String: SegmentedManifestEntry]
    ) throws -> Data {
        try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: schema5DepthShadow(state)
        )
    }

    static func binaryBaseCandidateJSONDecode(
        _ data: Data
    ) throws -> [String: SegmentedManifestEntry] {
        try binaryBaseCandidateJSONState(
            FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(data)
        )
    }

    static func binaryBaseCandidateJSONDecodeValidated(
        _ data: Data
    ) throws -> [String: SegmentedManifestEntry] {
        try binaryBaseCandidateJSONState(
            FileBlobStore.resourceProbeDecodeAndValidateDirectoryHeadSnapshot(data)
        )
    }

    private static func binaryBaseCandidateJSONState(
        _ decoded: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> [String: SegmentedManifestEntry] {
        var result: [String: SegmentedManifestEntry] = [:]
        result.reserveCapacity(decoded.count)
        for (key, entry) in decoded {
            result[key] = SegmentedManifestEntry(
                key: key,
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
        return result
    }

    static func binaryBaseCandidateCorruptions(
        valid: Data
    ) throws -> [(name: String, data: Data)] {
        let header = SegmentedBinaryBaseCandidate.headerBytes
        let record = SegmentedBinaryBaseCandidate.recordBytes
        guard valid.count >= header + 2 * record else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        var cases: [(String, Data)] = []

        var badMagic = valid
        badMagic[0] ^= 0xff
        cases.append(("bad-magic", badMagic))

        var futureVersion = valid
        futureVersion[8] = 2
        cases.append(("future-version", futureVersion))

        var badWidth = valid
        binaryBaseWriteUInt16(UInt16(record + 1), to: &badWidth, offset: 9)
        cases.append(("wrong-record-width", badWidth))

        var reserved = valid
        reserved[11] = 1
        cases.append(("nonzero-reserved", reserved))

        var tooMany = valid
        binaryBaseWriteUInt64(
            UInt64(SegmentedBinaryBaseCandidate.maximumRecords + 1),
            to: &tooMany,
            offset: 16
        )
        cases.append(("count-over-limit", tooMany))

        var lengthMismatch = valid
        binaryBaseWriteUInt64(
            UInt64(valid.count - header + record),
            to: &lengthMismatch,
            offset: 24
        )
        cases.append(("payload-length-mismatch", lengthMismatch))

        cases.append(("truncated", valid.dropLast().withUnsafeBytes { Data($0) }))
        var trailing = valid
        trailing.append(0)
        cases.append(("trailing-byte", trailing))

        var payloadHash = valid
        payloadHash[header] ^= 1
        cases.append(("payload-hash-mismatch", payloadHash))

        var badByteCount = valid
        binaryBaseWriteUInt64(
            UInt64(SegmentedManifestPrototypeV1.maximumBlobBytes) + 1,
            to: &badByteCount,
            offset: header + 80
        )
        binaryBaseRewritePayloadDigest(&badByteCount)
        cases.append(("blob-byte-count-over-limit", badByteCount))

        var nonFinite = valid
        binaryBaseWriteUInt64(
            Double.infinity.bitPattern,
            to: &nonFinite,
            offset: header + 88
        )
        binaryBaseRewritePayloadDigest(&nonFinite)
        cases.append(("nonfinite-last-access", nonFinite))

        var duplicatePhysical = valid
        duplicatePhysical.replaceSubrange(
            (header + record)..<(header + record + 16),
            with: valid[header..<(header + 16)]
        )
        binaryBaseRewritePayloadDigest(&duplicatePhysical)
        cases.append(("duplicate-physical-id", duplicatePhysical))

        var duplicateLogical = valid
        duplicateLogical.replaceSubrange(
            (header + record + 16)..<(header + record + 80),
            with: valid[(header + 16)..<(header + 80)]
        )
        let secondByteCount = valid[(header + 80)..<(header + 88)]
        duplicateLogical.replaceSubrange(
            (header + record + 80)..<(header + record + 88),
            with: secondByteCount
        )
        binaryBaseRewritePayloadDigest(&duplicateLogical)
        cases.append(("duplicate-recomputed-key", duplicateLogical))

        var outOfOrder = valid
        let first = Data(valid[header..<(header + record)])
        let second = Data(valid[(header + record)..<(header + 2 * record)])
        outOfOrder.replaceSubrange(header..<(header + record), with: second)
        outOfOrder.replaceSubrange((header + record)..<(header + 2 * record), with: first)
        binaryBaseRewritePayloadDigest(&outOfOrder)
        cases.append(("out-of-order-recomputed-key", outOfOrder))

        return cases
    }

    private static func binaryBaseRewritePayloadDigest(_ data: inout Data) {
        let digest = Data(SHA256.hash(data: data.dropFirst(SegmentedBinaryBaseCandidate.headerBytes)))
        data.replaceSubrange(32..<64, with: digest)
    }

    private static func binaryBaseWriteUInt16(
        _ value: UInt16,
        to data: inout Data,
        offset: Int
    ) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { bytes in
            data.replaceSubrange(offset..<(offset + 2), with: bytes)
        }
    }

    private static func binaryBaseWriteUInt64(
        _ value: UInt64,
        to data: inout Data,
        offset: Int
    ) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { bytes in
            data.replaceSubrange(offset..<(offset + 8), with: bytes)
        }
    }
}
