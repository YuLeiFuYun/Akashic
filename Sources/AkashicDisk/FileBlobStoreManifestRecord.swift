import AkashicCore
import Foundation

extension FileBlobStore {
    /// 单 key 增量记录的紧凑、向后兼容磁盘表示。
    ///
    /// v2 不再重复持久化文件名已经携带的 manifest key；replay 必须从文件名恢复 key，
    /// 再由 partition + digest 反算并验证一致性。v1 JSON 记录继续可读，任何未知版本失败关闭。
    struct ManifestRecord: Codable {
        struct FileIdentity: Equatable {
            let generation: UInt64?
            let key: String
        }

        static let currentSchemaVersion: UInt16 = 2
        private static let legacySchemaVersion: UInt16 = 1
        private static let filePrefix = ".manifest-entry-"
        private static let fileSuffix = ".json"

        let schemaVersion: UInt16
        let generation: UInt64
        let sequence: UInt64
        let persistedKey: String?
        let entry: Entry?

        init(generation: UInt64, sequence: UInt64, key: String, entry: Entry?) {
            self.schemaVersion = Self.currentSchemaVersion
            self.generation = generation
            self.sequence = sequence
            self.persistedKey = key
            self.entry = entry
        }

        private enum CompactCodingKeys: String, CodingKey {
            case schemaVersion = "v"
            case generation = "g"
            case sequence = "s"
            case key = "k"
            case entry = "e"
        }

        private enum LegacyCodingKeys: String, CodingKey {
            case schemaVersion
            case generation
            case sequence
            case key
            case entry
        }

        init(from decoder: any Decoder) throws {
            let compact = try decoder.container(keyedBy: CompactCodingKeys.self)
            if compact.contains(.schemaVersion) {
                let version = try compact.decode(UInt16.self, forKey: .schemaVersion)
                guard version == Self.currentSchemaVersion else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .schemaVersion,
                        in: compact,
                        debugDescription: "Unsupported compact manifest record schema"
                    )
                }
                self.schemaVersion = version
                self.generation = try compact.decode(UInt64.self, forKey: .generation)
                self.sequence = try compact.decode(UInt64.self, forKey: .sequence)
                if let keyBytes = try compact.decodeIfPresent(Data.self, forKey: .key) {
                    guard keyBytes.count == 32 else { throw AkashicError.invalidManifest }
                    self.persistedKey = keyBytes.map { String(format: "%02x", $0) }.joined()
                } else {
                    self.persistedKey = nil
                }
                if let compactEntry = try compact.decodeIfPresent(
                    CompactEntry.self,
                    forKey: .entry
                ) {
                    self.entry = try compactEntry.makeEntry()
                } else {
                    self.entry = nil
                }
                guard self.entry != nil || self.persistedKey != nil else {
                    throw AkashicError.invalidManifest
                }
                return
            }

            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let version = try legacy.decode(UInt16.self, forKey: .schemaVersion)
            guard version == Self.legacySchemaVersion else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: legacy,
                    debugDescription: "Unsupported legacy manifest record schema"
                )
            }
            // 解码后归一化到当前内存 schema；persistedKey 保留 v1 自带 key 以供 replay
            // 与文件名做双重一致性验证。
            self.schemaVersion = Self.currentSchemaVersion
            self.generation = try legacy.decode(UInt64.self, forKey: .generation)
            self.sequence = try legacy.decode(UInt64.self, forKey: .sequence)
            self.persistedKey = try legacy.decode(String.self, forKey: .key)
            self.entry = try legacy.decodeIfPresent(Entry.self, forKey: .entry)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CompactCodingKeys.self)
            try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
            try container.encode(generation, forKey: .generation)
            try container.encode(sequence, forKey: .sequence)
            if let entry {
                try container.encode(CompactEntry(entry), forKey: .entry)
            } else {
                guard let persistedKey, let keyBytes = Self.decodeManifestKey(persistedKey) else {
                    throw AkashicError.invalidManifest
                }
                try container.encode(keyBytes, forKey: .key)
            }
        }

        static func fileName(generation: UInt64, key: String) -> String? {
            guard isValidManifestKey(key), generation > 0 else { return nil }
            return "\(filePrefix)g\(String(format: "%016llx", generation))-\(key)\(fileSuffix)"
        }

        static func legacyFileName(key: String) -> String? {
            guard isValidManifestKey(key) else { return nil }
            return "\(filePrefix)\(key)\(fileSuffix)"
        }

        static func fileIdentity(from name: String) -> FileIdentity? {
            // 该文件名是固定 ASCII 协议；按 byte shape 解析，避免 recovery 扫描数百个
            // stale records 时为 body/split/Substring 反复分配临时 String。
            let bytes = Array(name.utf8)
            let prefix = Array(filePrefix.utf8)
            let suffix = Array(fileSuffix.utf8)
            guard bytes.count >= prefix.count + suffix.count,
                bytes.prefix(prefix.count).elementsEqual(prefix),
                bytes.suffix(suffix.count).elementsEqual(suffix)
            else { return nil }

            let bodyStart = prefix.count
            let bodyEnd = bytes.count - suffix.count
            let bodyCount = bodyEnd - bodyStart
            if bodyCount == 64 {
                let keyBytes = bytes[bodyStart ..< bodyEnd]
                guard keyBytes.allSatisfy(isLowercaseHex) else { return nil }
                return FileIdentity(
                    generation: nil,
                    key: String(decoding: keyBytes, as: UTF8.self)
                )
            }

            // scoped: g + 16 lowercase hex generation + '-' + 64 lowercase hex key
            guard bodyCount == 82,
                bytes[bodyStart] == 103,
                bytes[bodyStart + 17] == 45
            else { return nil }
            var generation: UInt64 = 0
            for byte in bytes[(bodyStart + 1) ..< (bodyStart + 17)] {
                guard let nibble = hexNibble(byte) else { return nil }
                generation = (generation << 4) | UInt64(nibble)
            }
            guard generation > 0 else { return nil }
            let keyStart = bodyStart + 18
            let keyBytes = bytes[keyStart ..< bodyEnd]
            guard keyBytes.count == 64, keyBytes.allSatisfy(isLowercaseHex) else { return nil }
            return FileIdentity(
                generation: generation,
                key: String(decoding: keyBytes, as: UTF8.self)
            )
        }

        private static func isValidManifestKey(_ key: String) -> Bool {
            key.utf8.count == 64 && key.utf8.allSatisfy(isLowercaseHex)
        }

        private static func isLowercaseHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (97...102).contains(byte)
        }

        private static func decodeManifestKey(_ key: String) -> Data? {
            let bytes = Array(key.utf8)
            guard bytes.count == 64 else { return nil }
            var result = Data(capacity: 32)
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                guard let high = hexNibble(bytes[offset]), let low = hexNibble(bytes[offset + 1])
                else { return nil }
                result.append((high << 4) | low)
            }
            return result
        }

        private static func hexNibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 97...102: byte - 87
            default: nil
            }
        }
    }

    private struct CompactEntry: Codable {
        let physicalID: String
        let partitionBytes: Data
        let digestBytes: Data
        let byteCount: Int
        let lastAccessReferenceTime: Double

        private enum CodingKeys: String, CodingKey {
            case physicalID = "u"
            case partitionBytes = "p"
            case digestBytes = "h"
            case byteCount = "n"
            case lastAccessReferenceTime = "t"
        }

        init(_ entry: Entry) {
            self.physicalID = entry.physicalID.rawValue.uuidString.lowercased()
            self.partitionBytes = entry.partition.canonicalBytes
            self.digestBytes = entry.digest.bytes
            self.byteCount = entry.byteCount
            self.lastAccessReferenceTime = entry.lastAccess.timeIntervalSinceReferenceDate
        }

        func makeEntry() throws -> Entry {
            guard byteCount >= 0,
                lastAccessReferenceTime.isFinite,
                let uuid = UUID(uuidString: physicalID),
                uuid.uuidString.lowercased() == physicalID
            else { throw AkashicError.invalidManifest }
            let partition = try CachePartitionID(bytes: partitionBytes)
            let digest = try BlobDigest(
                algorithm: .sha256,
                bytes: digestBytes,
                byteCount: byteCount
            )
            return Entry(
                physicalID: PhysicalBlobID(rawValue: uuid),
                partition: partition,
                digest: digest,
                byteCount: byteCount,
                lastAccess: Date(timeIntervalSinceReferenceDate: lastAccessReferenceTime)
            )
        }
    }
}
