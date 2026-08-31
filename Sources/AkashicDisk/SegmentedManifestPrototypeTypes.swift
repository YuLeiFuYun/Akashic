import AkashicCore
import Foundation

package struct SegmentedManifestEntry: Equatable, Sendable {
    package let key: String
    package let physicalID: PhysicalBlobID
    package let partition: CachePartitionID
    package let digest: BlobDigest
    package let byteCount: Int
    package let lastAccess: Date

    package init(
        key: String,
        physicalID: PhysicalBlobID,
        partition: CachePartitionID,
        digest: BlobDigest,
        byteCount: Int,
        lastAccess: Date
    ) {
        self.key = key
        self.physicalID = physicalID
        self.partition = partition
        self.digest = digest
        self.byteCount = byteCount
        self.lastAccess = lastAccess
    }
}

package enum SegmentedManifestMutation: Equatable, Sendable {
    case upsert(SegmentedManifestEntry)
    case tombstone(key: String)

    package var key: String {
        switch self {
        case .upsert(let entry): entry.key
        case .tombstone(let key): key
        }
    }
}

package struct SegmentedManifestDescriptorV1: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case baseJSON
        case baseBinaryV1
        case baseBinaryV2
        case runV1
        case compoundRunV1
    }

    package let kind: Kind
    package let fileName: String
    package let byteCount: Int
    package let recordCount: Int
    package let sha256: String

    package init(
        kind: Kind,
        fileName: String,
        byteCount: Int,
        recordCount: Int,
        sha256: String
    ) {
        self.kind = kind
        self.fileName = fileName
        self.byteCount = byteCount
        self.recordCount = recordCount
        self.sha256 = sha256
    }
}

package struct SegmentedManifestRootV1: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let profile: String
    package let generation: UInt64
    package let base: SegmentedManifestDescriptorV1
    package let runs: [SegmentedManifestDescriptorV1]
    package let seal: String

    package init(
        schemaVersion: Int,
        profile: String,
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1],
        seal: String
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.generation = generation
        self.base = base
        self.runs = runs
        self.seal = seal
    }
}

struct SegmentedManifestRootTranscriptV1: Codable {
    let schemaVersion: Int
    let profile: String
    let generation: UInt64
    let base: SegmentedManifestDescriptorV1
    let runs: [SegmentedManifestDescriptorV1]
}

package enum SegmentedManifestPrototypeV1 {
    package static let schemaVersion = 5
    package static let profileV1 = "segmentedDirectoryHeadV1"
    package static let profileV2 = "segmentedDirectoryHeadV2"
    package static let profileV3 = "segmentedDirectoryHeadV3"
    package static let profileV4 = "segmentedDirectoryHeadV4"
    package static let profile = profileV1
    package static let headerBytes = 64
    package static let runRecordBytes = 136
    package static let maximumRunRecords = 512
    package static let maximumRunDescriptors = 64
    package static let maximumRunBytes = 1 * 1024 * 1024
    package static let maximumRootBytes = 64 * 1024
    package static let maximumBaseBytes = 64 * 1024 * 1024
    package static let maximumReferencedSegmentBytes = 32 * 1024 * 1024
    package static let maximumBlobBytes = 1024 * 1024 * 1024
    static let runMagic = Data("AKRNV001".utf8)
}
