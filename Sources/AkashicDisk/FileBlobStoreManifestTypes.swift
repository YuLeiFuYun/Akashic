import AkashicCore
import Foundation

extension FileBlobStore {
    struct Manifest: Codable {
        private static let legacySchemaVersion = FileBlobStore.legacyManifestSchemaVersion

        struct CompactEntry: Codable {
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

            init(_ entry: Entry) {
                physicalID = entry.physicalID.rawValue
                partition = entry.partition.canonicalBytes
                digest = entry.digest.bytes
                byteCount = UInt64(entry.byteCount)
                lastAccess = entry.lastAccess.timeIntervalSinceReferenceDate
            }

            func decodedEntry() throws -> Entry {
                guard byteCount <= UInt64(FileBlobStore.maximumSupportedBlobBytes),
                    byteCount <= UInt64(Int.max),
                    lastAccess.isFinite
                else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "invalid compact manifest entry")
                    )
                }
                do {
                    let partitionID = try CachePartitionID(bytes: partition)
                    let blobDigest = try BlobDigest(
                        algorithm: .sha256,
                        bytes: digest,
                        byteCount: Int(byteCount)
                    )
                    return Entry(
                        physicalID: PhysicalBlobID(rawValue: physicalID),
                        partition: partitionID,
                        digest: blobDigest,
                        byteCount: Int(byteCount),
                        lastAccess: Date(timeIntervalSinceReferenceDate: lastAccess)
                    )
                } catch {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "invalid compact manifest identity")
                    )
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case generation
            case entries
            case compactEntries = "e"
            case deltaCarrierProfile = "d"
            case snapshotSeal = "x"
        }

        let schemaVersion: UInt16
        let generation: UInt64
        let deltaCarrierProfile: DeltaCarrierProfile?
        var entries: [String: Entry]

        init(
            schemaVersion: UInt16 = FileBlobStore.currentSchemaVersion,
            generation: UInt64 = 1,
            deltaCarrierProfile: DeltaCarrierProfile? = nil,
            entries: [String: Entry] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.generation = generation
            self.deltaCarrierProfile = deltaCarrierProfile
            self.entries = entries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let storedSchemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
            generation = try container.decode(UInt64.self, forKey: .generation)
            guard generation > 0 else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "invalid manifest generation")
                )
            }
            var compactForSeal: [CompactEntry]?
            switch storedSchemaVersion {
            case Self.legacySchemaVersion:
                entries = try container.decode([String: Entry].self, forKey: .entries)
            case FileBlobStore.compactManifestSchemaVersion,
                FileBlobStore.directoryHeadManifestSchemaVersion:
                let compact = try container.decode([CompactEntry].self, forKey: .compactEntries)
                compactForSeal = compact
                var rebuilt: [String: Entry] = [:]
                rebuilt.reserveCapacity(compact.count)
                var physicalIDs = Set<PhysicalBlobID>()
                physicalIDs.reserveCapacity(compact.count)
                var previousKey: String?
                for item in compact {
                    let entry = try item.decodedEntry()
                    guard physicalIDs.insert(entry.physicalID).inserted else {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: decoder.codingPath, debugDescription: "duplicate compact physical id")
                        )
                    }
                    let key = FileBlobStoreIdentity.manifestKey(
                        digest: entry.digest,
                        partition: entry.partition
                    )
                    if storedSchemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion,
                        let previousKey,
                        key <= previousKey
                    {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: decoder.codingPath, debugDescription: "non-canonical schema4 entry order")
                        )
                    }
                    previousKey = key
                    guard rebuilt.updateValue(entry, forKey: key) == nil else {
                        throw DecodingError.dataCorrupted(
                            .init(codingPath: decoder.codingPath, debugDescription: "duplicate compact manifest key")
                        )
                    }
                }
                entries = rebuilt
            default:
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "unsupported manifest schema")
                )
            }
            if storedSchemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion {
                let profile = try container.decode(
                    DeltaCarrierProfile.self,
                    forKey: .deltaCarrierProfile
                )
                guard profile == .directoryHeadV2,
                    let compact = compactForSeal
                else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "unsupported directory-head profile")
                    )
                }
                let observedSeal = try container.decode(Data.self, forKey: .snapshotSeal)
                let expectedSeal = try Self.directoryHeadSnapshotSeal(
                    generation: generation,
                    profile: profile,
                    compact: compact
                )
                guard observedSeal.count == 32, observedSeal == expectedSeal else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "invalid schema4 snapshot seal")
                    )
                }
                deltaCarrierProfile = profile
                schemaVersion = storedSchemaVersion
            } else {
                deltaCarrierProfile = nil
                schemaVersion = FileBlobStore.currentSchemaVersion
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(generation, forKey: .generation)
            if schemaVersion == Self.legacySchemaVersion {
                guard deltaCarrierProfile == nil else { throw AkashicError.invalidManifest }
                try container.encode(entries, forKey: .entries)
                return
            }
            guard schemaVersion == FileBlobStore.compactManifestSchemaVersion
                || schemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion
            else { throw AkashicError.invalidManifest }
            let compact = entries.sorted { $0.key < $1.key }.map { CompactEntry($0.value) }
            if schemaVersion == FileBlobStore.directoryHeadManifestSchemaVersion {
                guard let deltaCarrierProfile,
                    deltaCarrierProfile == .directoryHeadV2
                else { throw AkashicError.invalidManifest }
                try container.encode(deltaCarrierProfile, forKey: .deltaCarrierProfile)
                try container.encode(
                    Self.directoryHeadSnapshotSeal(
                        generation: generation,
                        profile: deltaCarrierProfile,
                        compact: compact
                    ),
                    forKey: .snapshotSeal
                )
            } else {
                guard deltaCarrierProfile == nil else { throw AkashicError.invalidManifest }
            }
            try container.encode(compact, forKey: .compactEntries)
        }

    }

    struct Entry: Codable, Equatable {
        let physicalID: PhysicalBlobID
        let partition: CachePartitionID
        let digest: BlobDigest
        let byteCount: Int
        let lastAccess: Date
    }

    struct PendingStage {
        let key: String
        let physicalID: PhysicalBlobID
        let partition: CachePartitionID
        let digest: BlobDigest
        let byteCount: Int
        let existing: Entry?
        let createdFile: Bool
    }
}
