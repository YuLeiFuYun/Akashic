import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct Schema5CodecMicroReport: Codable {
    struct Claims: Codable {
        let formalPerformance: Bool
        let productionDecoder: Bool
        let productionFormat: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let runCount: Int
    let recordsPerRun: Int
    let totalRecords: Int
    let totalRunBytes: Int
    let repetitions: Int
    let packageDecodeMedianNanoseconds: UInt64
    let manifestKeyMedianNanoseconds: UInt64
    let rawCandidateDecodeMedianNanoseconds: UInt64
    let allCandidateRunsExact: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5CodecMicro() throws {
        let liveCount = 16_384
        let recordsPerRun = 512
        let runCount = 64
        let repetitions = 3
        let baseEntries = try makeBaseEntries(count: liveCount)
        var state = Dictionary(
            uniqueKeysWithValues: baseEntries.map { ($0.key, schema5DepthEntry($0)) }
        )
        var runData: [Data] = []
        runData.reserveCapacity(runCount)
        for runIndex in 0..<runCount {
            let mutations = try schema5DepthMutations(
                runIndex: runIndex,
                baseEntries: baseEntries,
                expected: state,
                count: recordsPerRun
            )
            state = try SegmentedManifestPrototypeV1.apply(mutations, to: state)
            runData.append(try SegmentedManifestPrototypeV1.encodeRun(mutations))
        }
        let expectedRuns = try runData.map(SegmentedManifestPrototypeV1.decodeRun)
        _ = try SegmentedManifestPrototypeV1.decodeRun(runData[0])
        _ = try schema5RawDecodeRun(runData[0])

        var packageTimes: [UInt64] = []
        var keyTimes: [UInt64] = []
        var rawTimes: [UInt64] = []
        var allExact = true
        for _ in 0..<repetitions {
            let packageStart = DispatchTime.now().uptimeNanoseconds
            var packageCount = 0
            for data in runData {
                packageCount += try SegmentedManifestPrototypeV1.decodeRun(data).count
            }
            packageTimes.append(DispatchTime.now().uptimeNanoseconds &- packageStart)
            guard packageCount == runCount * recordsPerRun else {
                throw SegmentedManifestShadowError.invariantViolation
            }

            let keyStart = DispatchTime.now().uptimeNanoseconds
            var keyCount = 0
            for mutations in expectedRuns {
                for mutation in mutations {
                    guard case .upsert(let entry) = mutation else { continue }
                    let key = FileBlobStore.resourceProbeManifestKey(
                        digest: entry.digest,
                        partition: entry.partition
                    )
                    guard key == entry.key else {
                        throw SegmentedManifestShadowError.invariantViolation
                    }
                    keyCount += 1
                }
            }
            keyTimes.append(DispatchTime.now().uptimeNanoseconds &- keyStart)
            guard keyCount == runCount * recordsPerRun else {
                throw SegmentedManifestShadowError.invariantViolation
            }

            let rawStart = DispatchTime.now().uptimeNanoseconds
            for index in runData.indices {
                let decoded = try schema5RawDecodeRun(runData[index])
                if decoded != expectedRuns[index] { allExact = false }
            }
            rawTimes.append(DispatchTime.now().uptimeNanoseconds &- rawStart)
        }
        guard allExact else { throw SegmentedManifestShadowError.invariantViolation }

        let report = Schema5CodecMicroReport(
            schemaVersion: 1,
            runCount: runCount,
            recordsPerRun: recordsPerRun,
            totalRecords: runCount * recordsPerRun,
            totalRunBytes: runData.reduce(0) { $0 + $1.count },
            repetitions: repetitions,
            packageDecodeMedianNanoseconds: schema5CodecMedian(packageTimes),
            manifestKeyMedianNanoseconds: schema5CodecMedian(keyTimes),
            rawCandidateDecodeMedianNanoseconds: schema5CodecMedian(rawTimes),
            allCandidateRunsExact: allExact,
            claims: .init(
                formalPerformance: false,
                productionDecoder: false,
                productionFormat: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func schema5RawDecodeRun(_ data: Data) throws -> [SegmentedManifestMutation] {
        let headerBytes = SegmentedManifestPrototypeV1.headerBytes
        let recordBytes = SegmentedManifestPrototypeV1.runRecordBytes
        guard data.count >= headerBytes,
            data.count <= SegmentedManifestPrototypeV1.maximumRunBytes
        else { throw SegmentedManifestShadowError.invalidFormat }

        return try data.withUnsafeBytes { raw -> [SegmentedManifestMutation] in
            guard raw.count == data.count,
                schema5RawMatches(raw, offset: 0, bytes: Array("AKRNV001".utf8)),
                raw[8] == 1,
                schema5RawUInt16(raw, offset: 9) == UInt16(recordBytes),
                schema5RawAllZero(raw, offset: 11, count: 5)
            else { throw SegmentedManifestShadowError.invalidFormat }
            let count64 = schema5RawUInt64(raw, offset: 16)
            let payloadBytes64 = schema5RawUInt64(raw, offset: 24)
            guard count64 > 0,
                count64 <= UInt64(SegmentedManifestPrototypeV1.maximumRunRecords),
                payloadBytes64 == count64 * UInt64(recordBytes),
                payloadBytes64 <= UInt64(SegmentedManifestPrototypeV1.maximumRunBytes - headerBytes),
                let count = Int(exactly: count64),
                let payloadBytes = Int(exactly: payloadBytes64),
                data.count == headerBytes + payloadBytes
            else { throw SegmentedManifestShadowError.invalidFormat }

            let payload = data.dropFirst(headerBytes)
            let payloadDigest = SHA256.hash(data: payload)
            guard payloadDigest.enumerated().allSatisfy({ index, byte in
                raw[32 + index] == byte
            }) else { throw SegmentedManifestShadowError.invalidFormat }

            var result: [SegmentedManifestMutation] = []
            result.reserveCapacity(count)
            var previousKey: String?
            let digits = Array("0123456789abcdef".utf8)
            for recordIndex in 0..<count {
                let offset = headerBytes + recordIndex * recordBytes
                let tag = raw[offset + 32]
                guard schema5RawAllZero(raw, offset: offset + 33, count: 7) else {
                    throw SegmentedManifestShadowError.invalidFormat
                }
                if tag == 0 {
                    guard schema5RawAllZero(raw, offset: offset + 40, count: 96) else {
                        throw SegmentedManifestShadowError.invalidFormat
                    }
                    let key = schema5RawHexString(raw, offset: offset, count: 32, digits: digits)
                    if let previousKey, key <= previousKey {
                        throw SegmentedManifestShadowError.invalidFormat
                    }
                    previousKey = key
                    result.append(.tombstone(key: key))
                    continue
                }
                guard tag == 1 else { throw SegmentedManifestShadowError.invalidFormat }

                let uuidOffset = offset + 40
                let uuid = UUID(uuid: (
                    raw[uuidOffset], raw[uuidOffset + 1], raw[uuidOffset + 2], raw[uuidOffset + 3],
                    raw[uuidOffset + 4], raw[uuidOffset + 5], raw[uuidOffset + 6], raw[uuidOffset + 7],
                    raw[uuidOffset + 8], raw[uuidOffset + 9], raw[uuidOffset + 10], raw[uuidOffset + 11],
                    raw[uuidOffset + 12], raw[uuidOffset + 13], raw[uuidOffset + 14], raw[uuidOffset + 15]
                ))
                let partition = try CachePartitionID(
                    bytes: Data(bytes: raw.baseAddress!.advanced(by: offset + 56), count: 32)
                )
                let digestBytes = Data(bytes: raw.baseAddress!.advanced(by: offset + 88), count: 32)
                let byteCount64 = schema5RawUInt64(raw, offset: offset + 120)
                let lastAccessBits = schema5RawUInt64(raw, offset: offset + 128)
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
                guard schema5RawKeyMatches(raw, offset: offset, key: key),
                    previousKey.map({ key > $0 }) ?? true
                else { throw SegmentedManifestShadowError.invalidFormat }
                previousKey = key
                let lastAccessValue = Double(bitPattern: lastAccessBits)
                guard lastAccessValue.isFinite else {
                    throw SegmentedManifestShadowError.invalidFormat
                }
                result.append(
                    .upsert(
                        SegmentedManifestEntry(
                            key: key,
                            physicalID: PhysicalBlobID(rawValue: uuid),
                            partition: partition,
                            digest: digest,
                            byteCount: byteCount,
                            lastAccess: Date(timeIntervalSinceReferenceDate: lastAccessValue)
                        )
                    )
                )
            }
            return result
        }
    }

    private static func schema5RawUInt16(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt16.self))
    }

    private static func schema5RawUInt64(_ raw: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        UInt64(littleEndian: raw.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt64.self))
    }

    private static func schema5RawAllZero(
        _ raw: UnsafeRawBufferPointer, offset: Int, count: Int
    ) -> Bool {
        for index in 0..<count where raw[offset + index] != 0 { return false }
        return true
    }

    private static func schema5RawMatches(
        _ raw: UnsafeRawBufferPointer, offset: Int, bytes: [UInt8]
    ) -> Bool {
        for index in bytes.indices where raw[offset + index] != bytes[index] { return false }
        return true
    }

    private static func schema5RawHexString(
        _ raw: UnsafeRawBufferPointer, offset: Int, count: Int, digits: [UInt8]
    ) -> String {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(count * 2)
        for index in 0..<count {
            let byte = raw[offset + index]
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func schema5RawKeyMatches(
        _ raw: UnsafeRawBufferPointer, offset: Int, key: String
    ) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count == 64 else { return false }
        for index in 0..<32 {
            guard let high = schema5HexNibble(bytes[index * 2]),
                let low = schema5HexNibble(bytes[index * 2 + 1]),
                raw[offset + index] == high << 4 | low
            else { return false }
        }
        return true
    }

    private static func schema5HexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func schema5CodecMedian(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}
