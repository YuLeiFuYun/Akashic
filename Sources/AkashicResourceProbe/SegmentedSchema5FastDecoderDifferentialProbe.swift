import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct Schema5FastDecoderDifferentialReport: Codable {
    struct Claims: Codable {
        let productionDecoder: Bool
        let productionFormat: Bool
        let formalPerformance: Bool
    }

    let schemaVersion: Int
    let legalCases: Int
    let legalRecords: Int
    let malformedCases: Int
    let legalEqualityPass: Bool
    let malformedRejectionEquivalencePass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5FastDecoderDifferential() throws {
        let base = try makeBaseEntries(count: 1_024)
        let sizes = [1, 2, 17, 128, 512]
        var legalCases = 0
        var legalRecords = 0
        var legalPass = true
        var encodedLegalRuns: [(Data, [SegmentedManifestMutation])] = []
        for count in sizes {
            let mutations = try makeRunMutations(base: base, count: count).map(schema5Mutation)
            let data = try SegmentedManifestPrototypeV1.encodeRun(mutations)
            let reference = try SegmentedManifestPrototypeV1.resourceProbeDecodeRunReference(data)
            let production = try SegmentedManifestPrototypeV1.decodeRun(data)
            let candidate = try schema5RawDecodeRun(data)
            legalPass = legalPass
                && reference == mutations
                && production == reference
                && candidate == reference
            legalCases += 1
            legalRecords += mutations.count
            encodedLegalRuns.append((data, mutations))
        }

        let boundaryMutations = try schema5CodecBoundaryMutations()
        let boundaryData = try SegmentedManifestPrototypeV1.encodeRun(boundaryMutations)
        let boundaryReference = try SegmentedManifestPrototypeV1.resourceProbeDecodeRunReference(
            boundaryData
        )
        let boundaryProduction = try SegmentedManifestPrototypeV1.decodeRun(boundaryData)
        let boundaryCandidate = try schema5RawDecodeRun(boundaryData)
        legalPass = legalPass
            && boundaryReference == boundaryMutations
            && boundaryProduction == boundaryReference
            && boundaryCandidate == boundaryReference
        legalCases += 1
        legalRecords += boundaryMutations.count
        encodedLegalRuns.append((boundaryData, boundaryMutations))

        var malformed: [Data] = []
        let mixedData = encodedLegalRuns.last { $0.1.count >= 17 }!.0
        var badMagic = mixedData
        badMagic[0] ^= 0x01
        malformed.append(badMagic)
        var badKind = mixedData
        badKind[8] = 2
        malformed.append(badKind)
        var badWidth = mixedData
        schema5PatchUInt16(&badWidth, offset: 9, value: 135)
        malformed.append(badWidth)
        var badHeaderReserved = mixedData
        badHeaderReserved[11] = 1
        malformed.append(badHeaderReserved)
        var zeroCount = mixedData
        schema5PatchUInt64(&zeroCount, offset: 16, value: 0)
        malformed.append(zeroCount)
        var excessCount = mixedData
        schema5PatchUInt64(
            &excessCount,
            offset: 16,
            value: UInt64(SegmentedManifestPrototypeV1.maximumRunRecords + 1)
        )
        malformed.append(excessCount)
        var badPayloadLength = mixedData
        let currentPayload = schema5ReadUInt64(mixedData, offset: 24)
        schema5PatchUInt64(&badPayloadLength, offset: 24, value: currentPayload + 1)
        malformed.append(badPayloadLength)
        var badPayloadHash = mixedData
        badPayloadHash[SegmentedManifestPrototypeV1.headerBytes] ^= 0x01
        malformed.append(badPayloadHash)

        let mixedMutations = encodedLegalRuns.last { $0.1.count >= 17 }!.1
        if let upsertIndex = mixedMutations.firstIndex(where: {
            if case .upsert = $0 { return true }; return false
        }) {
            let offset = SegmentedManifestPrototypeV1.headerBytes
                + upsertIndex * SegmentedManifestPrototypeV1.runRecordBytes
            var badTag = mixedData
            badTag[offset + 32] = 2
            schema5PatchPayloadHash(&badTag)
            malformed.append(badTag)
            var badTagReserved = mixedData
            badTagReserved[offset + 33] = 1
            schema5PatchPayloadHash(&badTagReserved)
            malformed.append(badTagReserved)
            var badByteCount = mixedData
            schema5PatchUInt64(
                &badByteCount,
                offset: offset + 120,
                value: UInt64(SegmentedManifestPrototypeV1.maximumBlobBytes) + 1
            )
            schema5PatchPayloadHash(&badByteCount)
            malformed.append(badByteCount)
            var badDate = mixedData
            schema5PatchUInt64(&badDate, offset: offset + 128, value: Double.nan.bitPattern)
            schema5PatchPayloadHash(&badDate)
            malformed.append(badDate)
            var badStoredKey = mixedData
            badStoredKey[offset] ^= 0x01
            schema5PatchPayloadHash(&badStoredKey)
            malformed.append(badStoredKey)
        } else { legalPass = false }

        if let tombstoneIndex = mixedMutations.firstIndex(where: {
            if case .tombstone = $0 { return true }; return false
        }) {
            let offset = SegmentedManifestPrototypeV1.headerBytes
                + tombstoneIndex * SegmentedManifestPrototypeV1.runRecordBytes
            var badTombstoneReserved = mixedData
            badTombstoneReserved[offset + 40] = 1
            schema5PatchPayloadHash(&badTombstoneReserved)
            malformed.append(badTombstoneReserved)
        } else { legalPass = false }

        let twoMutations = encodedLegalRuns.first { $0.1.count == 2 }!.1
        var duplicateOrder = encodedLegalRuns.first { $0.1.count == 2 }!.0
        let recordBytes = SegmentedManifestPrototypeV1.runRecordBytes
        let firstOffset = SegmentedManifestPrototypeV1.headerBytes
        let secondOffset = firstOffset + recordBytes
        for byte in 0..<recordBytes {
            duplicateOrder[secondOffset + byte] = duplicateOrder[firstOffset + byte]
        }
        schema5PatchPayloadHash(&duplicateOrder)
        guard twoMutations.count == 2 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        malformed.append(duplicateOrder)

        var truncated = mixedData
        truncated.removeLast()
        malformed.append(truncated)
        var trailing = mixedData
        trailing.append(0)
        malformed.append(trailing)

        var malformedPass = true
        for data in malformed {
            let referenceRejected = schema5ReferenceDecoderRejects(data)
            let productionRejected = schema5ProductionDecoderRejects(data)
            let candidateRejected = schema5RawDecoderRejects(data)
            malformedPass = malformedPass
                && referenceRejected
                && productionRejected
                && candidateRejected
        }
        guard legalPass, malformedPass else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let report = Schema5FastDecoderDifferentialReport(
            schemaVersion: 1,
            legalCases: legalCases,
            legalRecords: legalRecords,
            malformedCases: malformed.count,
            legalEqualityPass: legalPass,
            malformedRejectionEquivalencePass: malformedPass,
            claims: .init(
                productionDecoder: false,
                productionFormat: false,
                formalPerformance: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5CodecBoundaryMutations() throws -> [SegmentedManifestMutation] {
        let byteCounts = [0, 1, 64 * 1024, SegmentedManifestPrototypeV1.maximumBlobBytes]
        var mutations: [SegmentedManifestMutation] = []
        for (index, byteCount) in byteCounts.enumerated() {
            let partition = try CachePartitionID.derive(
                domain: "schema5-codec-boundary-v1",
                material: Data("partition-\(index)".utf8)
            )
            let seed = BlobDigest.sha256(of: Data("digest-\(index)".utf8))
            let digest = try BlobDigest(
                algorithm: .sha256,
                bytes: seed.bytes,
                byteCount: byteCount
            )
            let key = FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
            let lastAccess = index % 2 == 0 ? Double(index) : -Double(index)
            mutations.append(
                .upsert(
                    SegmentedManifestEntry(
                        key: key,
                        physicalID: PhysicalBlobID(),
                        partition: partition,
                        digest: digest,
                        byteCount: byteCount,
                        lastAccess: Date(timeIntervalSinceReferenceDate: lastAccess)
                    )
                )
            )
        }
        return mutations.sorted { $0.key < $1.key }
    }

    private static func schema5ReferenceDecoderRejects(_ data: Data) -> Bool {
        do { _ = try SegmentedManifestPrototypeV1.resourceProbeDecodeRunReference(data); return false }
        catch { return true }
    }

    private static func schema5ProductionDecoderRejects(_ data: Data) -> Bool {
        do { _ = try SegmentedManifestPrototypeV1.decodeRun(data); return false }
        catch { return true }
    }

    private static func schema5RawDecoderRejects(_ data: Data) -> Bool {
        do { _ = try schema5RawDecodeRun(data); return false }
        catch { return true }
    }

    private static func schema5PatchPayloadHash(_ data: inout Data) {
        let payload = data.dropFirst(SegmentedManifestPrototypeV1.headerBytes)
        let digest = SHA256.hash(data: payload)
        for (index, byte) in digest.enumerated() { data[32 + index] = byte }
    }

    private static func schema5PatchUInt16(_ data: inout Data, offset: Int, value: UInt16) {
        let value = value.littleEndian
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func schema5PatchUInt64(_ data: inout Data, offset: Int, value: UInt64) {
        let value = value.littleEndian
        for byte in 0..<8 {
            data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt64(byte * 8))
        }
    }

    private static func schema5ReadUInt64(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<8 { value |= UInt64(data[offset + byte]) << UInt64(byte * 8) }
        return value
    }
}
