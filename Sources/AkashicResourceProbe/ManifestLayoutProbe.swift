import AkashicCore
import CryptoKit
import Dispatch
import Foundation

private enum ManifestLayoutProbeError: Error {
    case invalidArguments
    case invalidManifest
    case invalidBinary
}

private struct LayoutCurrentManifest: Codable {
    let schemaVersion: UInt16
    let generation: UInt64
    let entries: [String: LayoutCurrentEntry]
}

private struct LayoutCurrentEntry: Codable, Equatable {
    let physicalID: PhysicalBlobID
    let partition: CachePartitionID
    let digest: BlobDigest
    let byteCount: Int
    let lastAccess: Date
}

private struct LayoutCompactManifest: Codable {
    let version: UInt16
    let generation: UInt64
    let entries: [LayoutCompactEntry]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case generation = "g"
        case entries = "e"
    }
}

private struct LayoutCompactEntry: Codable {
    let physicalID: UUID
    let partition: Data
    let digest: Data
    let byteCount: UInt64
    let lastAccess: Double

    enum CodingKeys: String, CodingKey {
        case physicalID = "u"
        case partition = "p"
        case digest = "h"
        case byteCount = "n"
        case lastAccess = "t"
    }
}

private struct LayoutTiming: Codable {
    let encodeNanoseconds: [UInt64]
    let decodeAndValidateNanoseconds: [UInt64]
}

private struct ManifestLayoutReport: Codable {
    let schemaVersion: Int
    let entryCount: Int
    let sourceGeneration: UInt64
    let originalBytes: Int
    let currentReencodedBytes: Int
    let compactJSONBytes: Int
    let fixedBinaryBytes: Int
    let compactJSONRatioToCurrent: Double
    let fixedBinaryRatioToCurrent: Double
    let currentJSON: LayoutTiming
    let compactJSON: LayoutTiming
    let fixedBinary: LayoutTiming
    let claims: ManifestLayoutClaims
}

private struct ManifestLayoutClaims: Codable {
    let productionFormatChanged: Bool
    let formalPerformance: Bool
    let physicalDevice: Bool
    let physicalIOBytes: Bool
}

enum ManifestLayoutProbe {
    static func run(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw ManifestLayoutProbeError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootValue = values["--root"] else {
            throw ManifestLayoutProbeError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let sourceData = try Data(contentsOf: manifestURL)
        let source = try JSONDecoder().decode(LayoutCurrentManifest.self, from: sourceData)
        guard try validate(source) else { throw ManifestLayoutProbeError.invalidManifest }

        let compact = LayoutCompactManifest(
            version: source.schemaVersion,
            generation: source.generation,
            entries: source.entries.sorted { $0.key < $1.key }.map { _, entry in
                LayoutCompactEntry(
                    physicalID: entry.physicalID.rawValue,
                    partition: entry.partition.canonicalBytes,
                    digest: entry.digest.bytes,
                    byteCount: UInt64(entry.byteCount),
                    lastAccess: entry.lastAccess.timeIntervalSinceReferenceDate
                )
            }
        )

        let currentEncoder = JSONEncoder()
        currentEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let compactEncoder = JSONEncoder()
        compactEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let currentData = try currentEncoder.encode(source)
        let compactData = try compactEncoder.encode(compact)
        let binaryData = try encodeBinary(source)

        let currentTiming = try time(repetitions: 7) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(source)
        } decode: { data in
            let decoded = try JSONDecoder().decode(LayoutCurrentManifest.self, from: data)
            guard try validate(decoded), decoded.entries.count == source.entries.count else {
                throw ManifestLayoutProbeError.invalidManifest
            }
        }

        let compactTiming = try time(repetitions: 7) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(compact)
        } decode: { data in
            let decoded = try JSONDecoder().decode(LayoutCompactManifest.self, from: data)
            let rebuilt = try rebuild(decoded)
            guard rebuilt == source.entries else {
                throw ManifestLayoutProbeError.invalidManifest
            }
        }

        let binaryTiming = try time(repetitions: 7) {
            try encodeBinary(source)
        } decode: { data in
            let rebuilt = try decodeBinary(
                data,
                expectedVersion: source.schemaVersion,
                expectedGeneration: source.generation
            )
            guard rebuilt == source.entries else {
                throw ManifestLayoutProbeError.invalidBinary
            }
        }

        let report = ManifestLayoutReport(
            schemaVersion: 1,
            entryCount: source.entries.count,
            sourceGeneration: source.generation,
            originalBytes: sourceData.count,
            currentReencodedBytes: currentData.count,
            compactJSONBytes: compactData.count,
            fixedBinaryBytes: binaryData.count,
            compactJSONRatioToCurrent: Double(compactData.count) / Double(currentData.count),
            fixedBinaryRatioToCurrent: Double(binaryData.count) / Double(currentData.count),
            currentJSON: currentTiming,
            compactJSON: compactTiming,
            fixedBinary: binaryTiming,
            claims: ManifestLayoutClaims(
                productionFormatChanged: false,
                formalPerformance: false,
                physicalDevice: false,
                physicalIOBytes: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func time(
        repetitions: Int,
        encode: () throws -> Data,
        decode: (Data) throws -> Void
    ) throws -> LayoutTiming {
        var encodeSamples: [UInt64] = []
        var decodeSamples: [UInt64] = []
        encodeSamples.reserveCapacity(repetitions)
        decodeSamples.reserveCapacity(repetitions)
        for _ in 0 ..< repetitions {
            let encodeStart = DispatchTime.now().uptimeNanoseconds
            let data = try encode()
            encodeSamples.append(DispatchTime.now().uptimeNanoseconds &- encodeStart)
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            try decode(data)
            decodeSamples.append(DispatchTime.now().uptimeNanoseconds &- decodeStart)
        }
        return LayoutTiming(
            encodeNanoseconds: encodeSamples,
            decodeAndValidateNanoseconds: decodeSamples
        )
    }

    private static func validate(_ manifest: LayoutCurrentManifest) throws -> Bool {
        guard manifest.schemaVersion == 2, manifest.generation > 0 else { return false }
        var physicalIDs = Set<PhysicalBlobID>()
        for (key, entry) in manifest.entries {
            guard entry.byteCount > 0,
                entry.byteCount <= 1024 * 1024 * 1024,
                entry.digest.byteCount == entry.byteCount,
                entry.lastAccess.timeIntervalSinceReferenceDate.isFinite,
                physicalIDs.insert(entry.physicalID).inserted,
                key == manifestKey(digest: entry.digest, partition: entry.partition)
            else { return false }
        }
        return true
    }

    private static func rebuild(_ manifest: LayoutCompactManifest) throws -> [String: LayoutCurrentEntry] {
        guard manifest.version == 2, manifest.generation > 0 else {
            throw ManifestLayoutProbeError.invalidManifest
        }
        var result: [String: LayoutCurrentEntry] = [:]
        result.reserveCapacity(manifest.entries.count)
        var physicalIDs = Set<PhysicalBlobID>()
        for compact in manifest.entries {
            guard compact.byteCount > 0,
                compact.byteCount <= UInt64(1024 * 1024 * 1024),
                compact.byteCount <= UInt64(Int.max),
                compact.lastAccess.isFinite
            else { throw ManifestLayoutProbeError.invalidManifest }
            let physicalID = PhysicalBlobID(rawValue: compact.physicalID)
            guard physicalIDs.insert(physicalID).inserted else {
                throw ManifestLayoutProbeError.invalidManifest
            }
            let partition = try CachePartitionID(bytes: compact.partition)
            let digest = try BlobDigest(
                algorithm: .sha256,
                bytes: compact.digest,
                byteCount: Int(compact.byteCount)
            )
            let entry = LayoutCurrentEntry(
                physicalID: physicalID,
                partition: partition,
                digest: digest,
                byteCount: Int(compact.byteCount),
                lastAccess: Date(timeIntervalSinceReferenceDate: compact.lastAccess)
            )
            let key = manifestKey(digest: digest, partition: partition)
            guard result.updateValue(entry, forKey: key) == nil else {
                throw ManifestLayoutProbeError.invalidManifest
            }
        }
        return result
    }

    private static func manifestKey(digest: BlobDigest, partition: CachePartitionID) -> String {
        var input = Data("akashic-file-blob-key-v1\u{0}".utf8)
        input.append(partition.canonicalBytes)
        input.append(0)
        input.append(Data(digest.canonicalString.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    // Prototype only: fixed little-endian layout, no production authority or migration semantics.
    // Header: 8-byte magic + UInt16 version + UInt64 generation + UInt32 count.
    // Entry: UUID(16) + partition(32) + digest(32) + UInt64 byteCount + UInt64 Date bitPattern.
    private static func encodeBinary(_ manifest: LayoutCurrentManifest) throws -> Data {
        guard manifest.entries.count <= Int(UInt32.max) else {
            throw ManifestLayoutProbeError.invalidBinary
        }
        var data = Data("AKMFIX01".utf8)
        appendLittleEndian(manifest.schemaVersion, to: &data)
        appendLittleEndian(manifest.generation, to: &data)
        appendLittleEndian(UInt32(manifest.entries.count), to: &data)
        for (_, entry) in manifest.entries.sorted(by: { $0.key < $1.key }) {
            var uuid = entry.physicalID.rawValue.uuid
            withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
            guard entry.partition.canonicalBytes.count == 32,
                entry.digest.bytes.count == 32,
                entry.byteCount > 0
            else { throw ManifestLayoutProbeError.invalidBinary }
            data.append(entry.partition.canonicalBytes)
            data.append(entry.digest.bytes)
            appendLittleEndian(UInt64(entry.byteCount), to: &data)
            appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &data)
        }
        return data
    }

    private static func decodeBinary(
        _ data: Data,
        expectedVersion: UInt16,
        expectedGeneration: UInt64
    ) throws -> [String: LayoutCurrentEntry] {
        var cursor = 0
        guard take(count: 8, from: data, cursor: &cursor) == Data("AKMFIX01".utf8) else {
            throw ManifestLayoutProbeError.invalidBinary
        }
        let version: UInt16 = try readLittleEndian(from: data, cursor: &cursor)
        let generation: UInt64 = try readLittleEndian(from: data, cursor: &cursor)
        let count: UInt32 = try readLittleEndian(from: data, cursor: &cursor)
        guard version == expectedVersion, generation == expectedGeneration else {
            throw ManifestLayoutProbeError.invalidBinary
        }
        let expectedBytes = 22 + Int(count) * 96
        guard expectedBytes == data.count else { throw ManifestLayoutProbeError.invalidBinary }

        var result: [String: LayoutCurrentEntry] = [:]
        result.reserveCapacity(Int(count))
        var physicalIDs = Set<PhysicalBlobID>()
        for _ in 0 ..< count {
            let uuidData = take(count: 16, from: data, cursor: &cursor)
            guard uuidData.count == 16 else { throw ManifestLayoutProbeError.invalidBinary }
            let uuid = uuidData.withUnsafeBytes { raw -> UUID? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                let string = NSUUID(uuidBytes: base).uuidString
                return UUID(uuidString: string)
            }
            guard let uuid else { throw ManifestLayoutProbeError.invalidBinary }
            let partitionData = take(count: 32, from: data, cursor: &cursor)
            let digestData = take(count: 32, from: data, cursor: &cursor)
            let byteCount: UInt64 = try readLittleEndian(from: data, cursor: &cursor)
            let dateBits: UInt64 = try readLittleEndian(from: data, cursor: &cursor)
            guard byteCount > 0,
                byteCount <= UInt64(1024 * 1024 * 1024),
                byteCount <= UInt64(Int.max)
            else { throw ManifestLayoutProbeError.invalidBinary }
            let physicalID = PhysicalBlobID(rawValue: uuid)
            guard physicalIDs.insert(physicalID).inserted else {
                throw ManifestLayoutProbeError.invalidBinary
            }
            let partition = try CachePartitionID(bytes: partitionData)
            let digest = try BlobDigest(
                algorithm: .sha256,
                bytes: digestData,
                byteCount: Int(byteCount)
            )
            let timestamp = Double(bitPattern: dateBits)
            guard timestamp.isFinite else { throw ManifestLayoutProbeError.invalidBinary }
            let entry = LayoutCurrentEntry(
                physicalID: physicalID,
                partition: partition,
                digest: digest,
                byteCount: Int(byteCount),
                lastAccess: Date(timeIntervalSinceReferenceDate: timestamp)
            )
            let key = manifestKey(digest: digest, partition: partition)
            guard result.updateValue(entry, forKey: key) == nil else {
                throw ManifestLayoutProbeError.invalidBinary
            }
        }
        return result
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndian<T: FixedWidthInteger>(
        from data: Data,
        cursor: inout Int
    ) throws -> T {
        let size = MemoryLayout<T>.size
        let bytes = take(count: size, from: data, cursor: &cursor)
        guard bytes.count == size else { throw ManifestLayoutProbeError.invalidBinary }
        return bytes.withUnsafeBytes { raw in
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: raw)
            }
            return T(littleEndian: value)
        }
    }

    private static func take(count: Int, from data: Data, cursor: inout Int) -> Data {
        guard count >= 0, cursor >= 0, cursor <= data.count, count <= data.count - cursor else {
            return Data()
        }
        defer { cursor += count }
        return data.subdata(in: cursor ..< cursor + count)
    }
}
