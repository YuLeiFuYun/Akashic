import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

extension SegmentedManifestShadowProbe {
    static func validateDescriptorShape(
        _ descriptor: SegmentedShadowDescriptor
    ) throws {
        guard descriptor.recordCount >= 0,
            descriptor.sha256.utf8.count == 64,
            descriptor.sha256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }),
            isCanonicalSegmentFileName(descriptor.fileName, kind: descriptor.kind)
        else { throw SegmentedManifestShadowError.invalidFormat }
        let recordBytes: Int
        let maximumRecords: Int
        let maximumBytes: Int
        switch descriptor.kind {
        case .base:
            recordBytes = baseRecordBytes
            maximumRecords = maximumBaseRecords
            maximumBytes = maximumBaseBytes
        case .run:
            guard descriptor.recordCount > 0 else {
                throw SegmentedManifestShadowError.invalidFormat
            }
            recordBytes = runRecordBytes
            maximumRecords = maximumRunRecords
            maximumBytes = maximumRunBytes
        }
        let payload = descriptor.recordCount.multipliedReportingOverflow(by: recordBytes)
        let total = headerBytes.addingReportingOverflow(payload.partialValue)
        guard descriptor.recordCount <= maximumRecords,
            !payload.overflow,
            !total.overflow,
            descriptor.byteCount == total.partialValue,
            descriptor.byteCount <= maximumBytes
        else { throw SegmentedManifestShadowError.invalidFormat }
    }

    static func validateRootStructure(_ root: SegmentedShadowRoot) throws {
        guard root.schemaVersion == 1,
            root.generation > 0,
            root.runs.count <= maximumRunDescriptors,
            root.base.kind == .base,
            root.runs.allSatisfy({ $0.kind == .run })
        else { throw SegmentedManifestShadowError.invalidFormat }
        try validateDescriptorShape(root.base)
        for descriptor in root.runs {
            try validateDescriptorShape(descriptor)
        }
        let descriptors = [root.base] + root.runs
        var referencedBytes = 0
        for descriptor in descriptors {
            let next = referencedBytes.addingReportingOverflow(descriptor.byteCount)
            guard !next.overflow else { throw SegmentedManifestShadowError.invalidFormat }
            referencedBytes = next.partialValue
        }
        guard referencedBytes <= maximumReferencedSegmentBytes,
            Set(descriptors.map(\.fileName)).count == descriptors.count,
            Set(descriptors.map(\.sha256)).count == descriptors.count
        else { throw SegmentedManifestShadowError.invalidFormat }
    }

    static func isCanonicalSegmentFileName(
        _ fileName: String,
        kind: SegmentedShadowDescriptor.Kind
    ) -> Bool {
        let requiredPrefix = kind == .base ? "base-" : "run-"
        guard fileName.hasPrefix(requiredPrefix),
            fileName.hasSuffix(".seg"),
            fileName.utf8.count <= 128
        else { return false }
        let end = fileName.index(fileName.endIndex, offsetBy: -4)
        let stem = fileName[..<end]
        return !stem.isEmpty && stem.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    static func makeRoot(
        generation: UInt64,
        base: SegmentedShadowDescriptor,
        runs: [SegmentedShadowDescriptor]
    ) throws -> SegmentedShadowRoot {
        let transcript = SegmentedShadowRootTranscript(
            schemaVersion: 1,
            generation: generation,
            base: base,
            runs: runs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let transcriptData = try encoder.encode(transcript)
        let seal = SHA256.hash(data: transcriptData).map { String(format: "%02x", $0) }.joined()
        let root = SegmentedShadowRoot(
            schemaVersion: transcript.schemaVersion,
            generation: generation,
            base: base,
            runs: runs,
            seal: seal
        )
        try validateRootStructure(root)
        return root
    }

    static func validateRootSeal(_ root: SegmentedShadowRoot) throws -> Bool {
        let expected = try makeRoot(
            generation: root.generation,
            base: root.base,
            runs: root.runs
        )
        return expected.schemaVersion == root.schemaVersion && expected.seal == root.seal
    }

    static func descriptor(
        _ kind: SegmentedShadowDescriptor.Kind,
        url: URL,
        expectedRecords: Int
    ) throws -> SegmentedShadowDescriptor {
        let recordBytes = kind == .base ? baseRecordBytes : runRecordBytes
        let payload = expectedRecords.multipliedReportingOverflow(by: recordBytes)
        guard expectedRecords >= 0, !payload.overflow else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let total = headerBytes.addingReportingOverflow(payload.partialValue)
        guard !total.overflow else { throw SegmentedManifestShadowError.invalidFormat }
        let data = try BoundedFileReader.read(from: url, maximumBytes: total.partialValue)
        switch kind {
        case .base:
            guard try decodeBase(data).count == expectedRecords else {
                throw SegmentedManifestShadowError.invalidFormat
            }
        case .run:
            guard try decodeRun(data).count == expectedRecords else {
                throw SegmentedManifestShadowError.invalidFormat
            }
        }
        let descriptor = SegmentedShadowDescriptor(
            kind: kind,
            fileName: url.lastPathComponent,
            byteCount: data.count,
            recordCount: expectedRecords,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        try validateDescriptorShape(descriptor)
        return descriptor
    }

    static func readBase(
        _ descriptor: SegmentedShadowDescriptor,
        directory: URL
    ) throws -> [SegmentedShadowEntry] {
        guard descriptor.kind == .base else { throw SegmentedManifestShadowError.invalidFormat }
        let data = try readDescriptorData(descriptor, directory: directory)
        let entries = try decodeBase(data)
        guard entries.count == descriptor.recordCount else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return entries
    }

    static func readRun(
        _ descriptor: SegmentedShadowDescriptor,
        directory: URL
    ) throws -> [SegmentedShadowMutation] {
        guard descriptor.kind == .run else { throw SegmentedManifestShadowError.invalidFormat }
        let data = try readDescriptorData(descriptor, directory: directory)
        let mutations = try decodeRun(data)
        guard mutations.count == descriptor.recordCount else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return mutations
    }

    static func readDescriptorData(
        _ descriptor: SegmentedShadowDescriptor,
        directory: URL
    ) throws -> Data {
        try validateDescriptorShape(descriptor)
        let url = directory.appendingPathComponent(descriptor.fileName)
        let data = try BoundedFileReader.read(from: url, maximumBytes: descriptor.byteCount)
        guard data.count == descriptor.byteCount,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == descriptor.sha256
        else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return data
    }

    static func encodeBase(_ entries: [SegmentedShadowEntry]) throws -> Data {
        var payload = Data(capacity: entries.count * baseRecordBytes)
        var previous: String?
        for entry in entries {
            if let previous, entry.key <= previous { throw SegmentedManifestShadowError.invalidFormat }
            previous = entry.key
            try appendKey(entry.key, to: &payload)
            appendUUID(entry.physicalID.rawValue, to: &payload)
            guard entry.partition.canonicalBytes.count == 32,
                entry.digest.bytes.count == 32,
                entry.byteCount >= 0,
                entry.byteCount <= maximumBlobBytes
            else { throw SegmentedManifestShadowError.invalidFormat }
            payload.append(entry.partition.canonicalBytes)
            payload.append(entry.digest.bytes)
            appendLittleEndian(UInt64(entry.byteCount), to: &payload)
            appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &payload)
        }
        return try frame(kind: 1, recordBytes: baseRecordBytes, count: entries.count, payload: payload)
    }

    static func encodeRun(_ mutations: [SegmentedShadowMutation]) throws -> Data {
        var payload = Data(capacity: mutations.count * runRecordBytes)
        var previous: String?
        for mutation in mutations {
            if let previous, mutation.key <= previous { throw SegmentedManifestShadowError.invalidFormat }
            previous = mutation.key
            try appendKey(mutation.key, to: &payload)
            switch mutation {
            case .tombstone:
                payload.append(0)
                payload.append(Data(repeating: 0, count: 7 + 16 + 32 + 32 + 8 + 8))
            case .upsert(let entry):
                payload.append(1)
                payload.append(Data(repeating: 0, count: 7))
                appendUUID(entry.physicalID.rawValue, to: &payload)
                guard entry.partition.canonicalBytes.count == 32,
                    entry.digest.bytes.count == 32,
                    entry.byteCount >= 0,
                    entry.byteCount <= maximumBlobBytes,
                    entry.key == FileBlobStore.resourceProbeManifestKey(
                        digest: entry.digest,
                        partition: entry.partition
                    )
                else { throw SegmentedManifestShadowError.invalidFormat }
                payload.append(entry.partition.canonicalBytes)
                payload.append(entry.digest.bytes)
                appendLittleEndian(UInt64(entry.byteCount), to: &payload)
                appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &payload)
            }
        }
        return try frame(kind: 2, recordBytes: runRecordBytes, count: mutations.count, payload: payload)
    }

    static func frame(
        kind: UInt8,
        recordBytes: Int,
        count: Int,
        payload: Data
    ) throws -> Data {
        let expectedPayload = count.multipliedReportingOverflow(by: recordBytes)
        guard count >= 0,
            !expectedPayload.overflow,
            payload.count == expectedPayload.partialValue,
            let count64 = UInt64(exactly: count),
            let payloadBytes64 = UInt64(exactly: payload.count)
        else { throw SegmentedManifestShadowError.invalidFormat }
        var data = Data(capacity: headerBytes + payload.count)
        data.append(magic)
        data.append(kind)
        appendLittleEndian(UInt16(recordBytes), to: &data)
        data.append(Data(repeating: 0, count: 5))
        appendLittleEndian(count64, to: &data)
        appendLittleEndian(payloadBytes64, to: &data)
        data.append(Data(SHA256.hash(data: payload)))
        guard data.count == headerBytes else { throw SegmentedManifestShadowError.invalidFormat }
        data.append(payload)
        return data
    }

    static func decodeBase(_ data: Data) throws -> [SegmentedShadowEntry] {
        let (kind, recordBytes, count, payload) = try unframe(data)
        guard kind == 1,
            recordBytes == baseRecordBytes,
            count <= maximumBaseRecords,
            data.count <= maximumBaseBytes
        else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        var cursor = 0
        var result: [SegmentedShadowEntry] = []
        result.reserveCapacity(count)
        var previous: String?
        var physicalIDs = Set<PhysicalBlobID>()
        for _ in 0 ..< count {
            let key = try readKey(payload, cursor: &cursor)
            if let previous, key <= previous { throw SegmentedManifestShadowError.invalidFormat }
            previous = key
            let physicalID = PhysicalBlobID(rawValue: try readUUID(payload, cursor: &cursor))
            let partition = try CachePartitionID(bytes: take(32, from: payload, cursor: &cursor))
            let byteCount64: UInt64
            let digestData = take(32, from: payload, cursor: &cursor)
            byteCount64 = try readLittleEndian(from: payload, cursor: &cursor)
            let dateBits: UInt64 = try readLittleEndian(from: payload, cursor: &cursor)
            guard byteCount64 <= UInt64(maximumBlobBytes) else { throw SegmentedManifestShadowError.invalidFormat }
            let byteCount = Int(byteCount64)
            let digest = try BlobDigest(algorithm: .sha256, bytes: digestData, byteCount: byteCount)
            let timestamp = Double(bitPattern: dateBits)
            guard timestamp.isFinite,
                key == FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
                physicalIDs.insert(physicalID).inserted
            else { throw SegmentedManifestShadowError.invalidFormat }
            result.append(
                SegmentedShadowEntry(
                    key: key,
                    physicalID: physicalID,
                    partition: partition,
                    digest: digest,
                    byteCount: byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: timestamp)
                )
            )
        }
        guard cursor == payload.count else { throw SegmentedManifestShadowError.invalidFormat }
        return result
    }

    static func decodeRun(_ data: Data) throws -> [SegmentedShadowMutation] {
        let (kind, recordBytes, count, payload) = try unframe(data)
        guard kind == 2,
            recordBytes == runRecordBytes,
            count > 0,
            count <= maximumRunRecords,
            data.count <= maximumRunBytes
        else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        var cursor = 0
        var result: [SegmentedShadowMutation] = []
        result.reserveCapacity(count)
        var previous: String?
        for _ in 0 ..< count {
            let key = try readKey(payload, cursor: &cursor)
            if let previous, key <= previous { throw SegmentedManifestShadowError.invalidFormat }
            previous = key
            let tagData = take(1, from: payload, cursor: &cursor)
            guard let tag = tagData.first else { throw SegmentedManifestShadowError.invalidFormat }
            let reserved = take(7, from: payload, cursor: &cursor)
            guard reserved.count == 7, reserved.allSatisfy({ $0 == 0 }) else {
                throw SegmentedManifestShadowError.invalidFormat
            }
            if tag == 0 {
                let tombstoneReserved = take(16 + 32 + 32 + 8 + 8, from: payload, cursor: &cursor)
                guard tombstoneReserved.count == 96,
                    tombstoneReserved.allSatisfy({ $0 == 0 })
                else { throw SegmentedManifestShadowError.invalidFormat }
                result.append(.tombstone(key: key))
                continue
            }
            guard tag == 1 else { throw SegmentedManifestShadowError.invalidFormat }
            let physicalID = PhysicalBlobID(rawValue: try readUUID(payload, cursor: &cursor))
            let partition = try CachePartitionID(bytes: take(32, from: payload, cursor: &cursor))
            let digestData = take(32, from: payload, cursor: &cursor)
            let byteCount64: UInt64 = try readLittleEndian(from: payload, cursor: &cursor)
            let dateBits: UInt64 = try readLittleEndian(from: payload, cursor: &cursor)
            guard byteCount64 <= UInt64(maximumBlobBytes) else { throw SegmentedManifestShadowError.invalidFormat }
            let byteCount = Int(byteCount64)
            let digest = try BlobDigest(algorithm: .sha256, bytes: digestData, byteCount: byteCount)
            let timestamp = Double(bitPattern: dateBits)
            guard timestamp.isFinite,
                key == FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
            else { throw SegmentedManifestShadowError.invalidFormat }
            result.append(
                .upsert(
                    SegmentedShadowEntry(
                        key: key,
                        physicalID: physicalID,
                        partition: partition,
                        digest: digest,
                        byteCount: byteCount,
                        lastAccess: Date(timeIntervalSinceReferenceDate: timestamp)
                    )
                )
            )
        }
        guard cursor == payload.count else { throw SegmentedManifestShadowError.invalidFormat }
        return result
    }

}
