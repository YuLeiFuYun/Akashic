import AkashicCore
import CryptoKit
import Foundation

extension SegmentedManifestPrototypeV1 {
    package static func encodeRun(_ mutations: [SegmentedManifestMutation]) throws -> Data {
        guard !mutations.isEmpty, mutations.count <= maximumRunRecords else {
            throw AkashicError.invalidManifest
        }
        var payload = Data(capacity: mutations.count * runRecordBytes)
        var previousKey: String?
        for mutation in mutations {
            if let previousKey, mutation.key <= previousKey { throw AkashicError.invalidManifest }
            previousKey = mutation.key
            try appendManifestKey(mutation.key, to: &payload)
            switch mutation {
            case .tombstone:
                payload.append(0)
                payload.append(Data(repeating: 0, count: 7 + 16 + 32 + 32 + 8 + 8))
            case .upsert(let entry):
                try validate(entry)
                payload.append(1)
                payload.append(Data(repeating: 0, count: 7))
                appendUUID(entry.physicalID.rawValue, to: &payload)
                payload.append(entry.partition.canonicalBytes)
                payload.append(entry.digest.bytes)
                appendLittleEndian(UInt64(entry.byteCount), to: &payload)
                appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &payload)
            }
        }
        let expected = mutations.count.multipliedReportingOverflow(by: runRecordBytes)
        guard !expected.overflow, payload.count == expected.partialValue else {
            throw AkashicError.invalidManifest
        }
        var result = Data(capacity: headerBytes + payload.count)
        result.append(runMagic)
        result.append(1)
        appendLittleEndian(UInt16(runRecordBytes), to: &result)
        result.append(Data(repeating: 0, count: 5))
        appendLittleEndian(UInt64(mutations.count), to: &result)
        appendLittleEndian(UInt64(payload.count), to: &result)
        result.append(Data(SHA256.hash(data: payload)))
        guard result.count == headerBytes else { throw AkashicError.invalidManifest }
        result.append(payload)
        guard result.count <= maximumRunBytes else { throw AkashicError.invalidManifest }
        return result
    }
    package static func decodeRun(_ data: Data) throws -> [SegmentedManifestMutation] {
        guard data.count >= headerBytes, data.count <= maximumRunBytes else {
            throw AkashicError.invalidManifest
        }
        return try data.withUnsafeBytes { raw -> [SegmentedManifestMutation] in
            guard raw.count == data.count,
                rawMatches(raw, offset: 0, data: runMagic),
                raw[8] == 1,
                rawUInt16(raw, offset: 9) == UInt16(runRecordBytes),
                rawAllZero(raw, offset: 11, count: 5)
            else { throw AkashicError.invalidManifest }
            let count64 = rawUInt64(raw, offset: 16)
            let payloadBytes64 = rawUInt64(raw, offset: 24)
            guard count64 > 0,
                count64 <= UInt64(maximumRunRecords),
                payloadBytes64 == count64 * UInt64(runRecordBytes),
                payloadBytes64 <= UInt64(maximumRunBytes - headerBytes),
                let count = Int(exactly: count64),
                let payloadBytes = Int(exactly: payloadBytes64),
                data.count == headerBytes + payloadBytes
            else { throw AkashicError.invalidManifest }

            let payloadDigest = SHA256.hash(data: data.dropFirst(headerBytes))
            guard payloadDigest.enumerated().allSatisfy({ index, byte in
                raw[32 + index] == byte
            }) else { throw AkashicError.invalidManifest }

            var result: [SegmentedManifestMutation] = []
            result.reserveCapacity(count)
            var previousKey: String?
            for recordIndex in 0..<count {
                let offset = headerBytes + recordIndex * runRecordBytes
                let tag = raw[offset + 32]
                guard rawAllZero(raw, offset: offset + 33, count: 7) else {
                    throw AkashicError.invalidManifest
                }
                if tag == 0 {
                    guard rawAllZero(raw, offset: offset + 40, count: 96) else {
                        throw AkashicError.invalidManifest
                    }
                    let key = rawHexString(raw, offset: offset, count: 32)
                    if let previousKey, key <= previousKey { throw AkashicError.invalidManifest }
                    previousKey = key
                    result.append(.tombstone(key: key))
                    continue
                }
                guard tag == 1 else { throw AkashicError.invalidManifest }

                let uuidOffset = offset + 40
                let physicalID = PhysicalBlobID(
                    rawValue: UUID(uuid: (
                        raw[uuidOffset], raw[uuidOffset + 1], raw[uuidOffset + 2], raw[uuidOffset + 3],
                        raw[uuidOffset + 4], raw[uuidOffset + 5], raw[uuidOffset + 6], raw[uuidOffset + 7],
                        raw[uuidOffset + 8], raw[uuidOffset + 9], raw[uuidOffset + 10], raw[uuidOffset + 11],
                        raw[uuidOffset + 12], raw[uuidOffset + 13], raw[uuidOffset + 14], raw[uuidOffset + 15]
                    ))
                )
                guard let baseAddress = raw.baseAddress else { throw AkashicError.invalidManifest }
                let partition = try CachePartitionID(
                    bytes: Data(bytes: baseAddress.advanced(by: offset + 56), count: 32)
                )
                let digestBytes = Data(bytes: baseAddress.advanced(by: offset + 88), count: 32)
                let byteCount64 = rawUInt64(raw, offset: offset + 120)
                let lastAccessBits = rawUInt64(raw, offset: offset + 128)
                guard byteCount64 <= UInt64(maximumBlobBytes),
                    let byteCount = Int(exactly: byteCount64)
                else { throw AkashicError.invalidManifest }
                let digest = try BlobDigest(
                    algorithm: .sha256,
                    bytes: digestBytes,
                    byteCount: byteCount
                )
                let keyDigest = FileBlobStoreIdentity.manifestKeyDigest(
                    digest: digest,
                    partition: partition
                )
                guard keyDigest.enumerated().allSatisfy({ index, byte in
                    raw[offset + index] == byte
                }) else { throw AkashicError.invalidManifest }
                let key = rawHexString(raw, offset: offset, count: 32)
                guard previousKey.map({ key > $0 }) ?? true else {
                    throw AkashicError.invalidManifest
                }
                previousKey = key
                let lastAccessValue = Double(bitPattern: lastAccessBits)
                guard lastAccessValue.isFinite else { throw AkashicError.invalidManifest }
                result.append(
                    .upsert(
                        SegmentedManifestEntry(
                            key: key,
                            physicalID: physicalID,
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
    package static func makeRoot(
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        try makeRoot(
            profile: profileV1,
            generation: generation,
            base: base,
            runs: runs
        )
    }
    package static func makeRootV2(
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        try makeRoot(
            profile: profileV2,
            generation: generation,
            base: base,
            runs: runs
        )
    }
    package static func makeRootV3(
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        try makeRoot(
            profile: profileV3,
            generation: generation,
            base: base,
            runs: runs
        )
    }
    package static func makeRootV4(
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        try makeRoot(
            profile: profileV4,
            generation: generation,
            base: base,
            runs: runs
        )
    }
    package static func makeRootPreservingProfile(
        of currentRoot: SegmentedManifestRootV1,
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        switch currentRoot.profile {
        case profileV1:
            return try makeRoot(
                generation: generation,
                base: base,
                runs: runs
            )
        case profileV2:
            return try makeRootV2(
                generation: generation,
                base: base,
                runs: runs
            )
        case profileV3:
            return try makeRootV3(
                generation: generation,
                base: base,
                runs: runs
            )
        case profileV4:
            return try makeRootV4(
                generation: generation,
                base: base,
                runs: runs
            )
        default:
            throw AkashicError.invalidManifest
        }
    }
    private static func makeRoot(
        profile: String,
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        let transcript = SegmentedManifestRootTranscriptV1(
            schemaVersion: schemaVersion,
            profile: profile,
            generation: generation,
            base: base,
            runs: runs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let transcriptData = try encoder.encode(transcript)
        let seal = SHA256.hash(data: transcriptData).map { String(format: "%02x", $0) }.joined()
        let root = SegmentedManifestRootV1(
            schemaVersion: schemaVersion,
            profile: profile,
            generation: generation,
            base: base,
            runs: runs,
            seal: seal
        )
        try validateRoot(root)
        return root
    }
    package static func encodeRoot(_ root: SegmentedManifestRootV1) throws -> Data {
        try validateRoot(root)
        guard try validateRootSeal(root) else { throw AkashicError.invalidManifest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(root)
        guard data.count <= maximumRootBytes else { throw AkashicError.invalidManifest }
        return data
    }
    package static func decodeRoot(_ data: Data) throws -> SegmentedManifestRootV1 {
        guard data.count <= maximumRootBytes else { throw AkashicError.invalidManifest }
        let root: SegmentedManifestRootV1
        do { root = try JSONDecoder().decode(SegmentedManifestRootV1.self, from: data) }
        catch { throw AkashicError.invalidManifest }
        try validateRoot(root)
        guard try validateRootSeal(root) else { throw AkashicError.invalidManifest }
        return root
    }
    package static func apply(
        _ mutations: [SegmentedManifestMutation],
        to source: [String: SegmentedManifestEntry]
    ) throws -> [String: SegmentedManifestEntry] {
        var result = source
        var previousKey: String?
        for mutation in mutations {
            if let previousKey, mutation.key <= previousKey { throw AkashicError.invalidManifest }
            previousKey = mutation.key
            switch mutation {
            case .upsert(let entry):
                try validate(entry)
                result[entry.key] = entry
            case .tombstone(let key):
                result.removeValue(forKey: key)
            }
        }
        let physicalIDs = result.values.map(\.physicalID)
        guard Set(physicalIDs).count == physicalIDs.count else { throw AkashicError.invalidManifest }
        return result
    }
    package static func semanticStateCommitment(
        _ state: [String: SegmentedManifestEntry]
    ) throws -> String {
        let entries = state.values.sorted { $0.key < $1.key }
        var transcript = Data("AKASHIC-SEGMENTED-STATE-V1\0".utf8)
        for entry in entries {
            try validate(entry)
            try appendManifestKey(entry.key, to: &transcript)
            appendUUID(entry.physicalID.rawValue, to: &transcript)
            transcript.append(entry.partition.canonicalBytes)
            transcript.append(entry.digest.bytes)
            appendLittleEndian(UInt64(entry.byteCount), to: &transcript)
            appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &transcript)
        }
        return SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
    }
    private static func validateRoot(_ root: SegmentedManifestRootV1) throws {
        guard root.schemaVersion == schemaVersion,
            root.generation > 0,
            root.runs.count <= maximumRunDescriptors
        else { throw AkashicError.invalidManifest }
        switch root.profile {
        case profileV1:
            guard root.base.kind == .baseJSON,
                root.runs.allSatisfy({ $0.kind == .runV1 })
            else { throw AkashicError.invalidManifest }
        case profileV2:
            guard root.base.kind == .baseBinaryV1,
                root.runs.allSatisfy({ $0.kind == .runV1 })
            else { throw AkashicError.invalidManifest }
        case profileV3:
            guard root.base.kind == .baseBinaryV2,
                root.runs.allSatisfy({ $0.kind == .runV1 })
            else { throw AkashicError.invalidManifest }
        case profileV4:
            guard root.base.kind == .baseBinaryV2,
                root.runs.allSatisfy({ $0.kind == .runV1 || $0.kind == .compoundRunV1 })
            else { throw AkashicError.invalidManifest }
        default:
            throw AkashicError.invalidManifest
        }
        try validateDescriptor(root.base)
        var referencedBytes = root.base.byteCount
        var names = Set([root.base.fileName])
        for run in root.runs {
            try validateDescriptor(run)
            let sum = referencedBytes.addingReportingOverflow(run.byteCount)
            guard !sum.overflow else { throw AkashicError.invalidManifest }
            referencedBytes = sum.partialValue
            // Physical identity is the canonical file name. Equal immutable bytes under distinct
            // names are legitimate: a periodic workload may emit the exact same deterministic
            // epoch delta again in a later generation. Each descriptor independently binds its
            // bytes to SHA-256 at read time, so content-hash uniqueness adds no integrity proof and
            // would turn repeated valid deltas into a liveness failure.
            guard names.insert(run.fileName).inserted else { throw AkashicError.invalidManifest }
        }
        guard referencedBytes <= maximumReferencedSegmentBytes else { throw AkashicError.invalidManifest }
    }
    private static func validateDescriptor(_ descriptor: SegmentedManifestDescriptorV1) throws {
        guard descriptor.byteCount > 0,
            descriptor.recordCount >= 0,
            descriptor.sha256.utf8.count == 64,
            descriptor.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            isCanonicalSegmentFileName(descriptor.fileName, kind: descriptor.kind)
        else { throw AkashicError.invalidManifest }
        switch descriptor.kind {
        case .baseJSON:
            guard descriptor.recordCount <= 100_000,
                descriptor.byteCount <= maximumBaseBytes
            else { throw AkashicError.invalidManifest }
        case .baseBinaryV1:
            guard descriptor.recordCount <= SegmentedManifestBinaryBaseV1.maximumRecords,
                descriptor.byteCount <= maximumBaseBytes,
                SegmentedManifestBinaryBaseV1.expectedByteCount(
                    recordCount: descriptor.recordCount
                ) == descriptor.byteCount
            else { throw AkashicError.invalidManifest }
        case .baseBinaryV2:
            guard descriptor.recordCount <= SegmentedManifestBinaryBaseV2.maximumRecords,
                descriptor.byteCount <= maximumBaseBytes,
                SegmentedManifestBinaryBaseV2.expectedByteCount(
                    recordCount: descriptor.recordCount
                ) == descriptor.byteCount
            else { throw AkashicError.invalidManifest }
        case .runV1:
            let payload = descriptor.recordCount.multipliedReportingOverflow(by: runRecordBytes)
            let total = headerBytes.addingReportingOverflow(payload.partialValue)
            guard descriptor.recordCount > 0,
                descriptor.recordCount <= maximumRunRecords,
                !payload.overflow,
                !total.overflow,
                descriptor.byteCount == total.partialValue,
                descriptor.byteCount <= maximumRunBytes
            else { throw AkashicError.invalidManifest }
        case .compoundRunV1:
            guard descriptor.recordCount > 0,
                descriptor.recordCount <= maximumRunRecords,
                descriptor.byteCount >= 2 * headerBytes + SegmentedManifestCompoundRunV1.footerBytes,
                descriptor.byteCount <= SegmentedManifestCompoundRunV1.maximumBytes
            else { throw AkashicError.invalidManifest }
        }
    }

    private static func validateRootSeal(_ root: SegmentedManifestRootV1) throws -> Bool {
        let expected = try makeRoot(
            profile: root.profile,
            generation: root.generation,
            base: root.base,
            runs: root.runs
        )
        return expected.seal == root.seal
    }

    static func validate(_ entry: SegmentedManifestEntry) throws {
        guard entry.partition.canonicalBytes.count == 32,
            entry.digest.bytes.count == 32,
            entry.digest.byteCount == entry.byteCount,
            entry.byteCount >= 0,
            entry.byteCount <= maximumBlobBytes,
            entry.lastAccess.timeIntervalSinceReferenceDate.isFinite,
            entry.key == FileBlobStore.resourceProbeManifestKey(
                digest: entry.digest,
                partition: entry.partition
            )
        else { throw AkashicError.invalidManifest }
    }

    private static func appendManifestKey(_ key: String, to data: inout Data) throws {
        guard key.utf8.count == 64 else { throw AkashicError.invalidManifest }
        let bytes = Array(key.utf8)
        var decoded = Data(capacity: 32)
        for offset in stride(from: 0, to: 64, by: 2) {
            guard let high = hex(bytes[offset]), let low = hex(bytes[offset + 1]) else {
                throw AkashicError.invalidManifest
            }
            decoded.append(high << 4 | low)
        }
        data.append(decoded)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func appendUUID(_ uuid: UUID, to data: inout Data) {
        var value = uuid.uuid
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
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
        for (index, byte) in data.enumerated() where raw[offset + index] != byte { return false }
        return true
    }

    private static func rawHexString(
        _ raw: UnsafeRawBufferPointer,
        offset: Int,
        count: Int
    ) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(count * 2)
        for index in 0..<count {
            let byte = raw[offset + index]
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

}
