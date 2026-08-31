import AkashicCore
import AkashicDisk
import Foundation

struct Schema5CheckpointPresealIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    var key: String {
        FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
    }
}

struct Schema5CheckpointPresealCase: Codable {
    let name: String
    let sourceDistinctKeys: Int
    let candidateBytes: Int
    let candidateRecords: Int
    let finalRunCount: Int
    let finalRunRecordCounts: [Int]
    let generationDelta: UInt64
    let finalActiveDistinctKeys: Int
    let finalEntryCount: Int
    let candidateReferencedAfterCheckpoint: Bool
    let candidateReclaimedAfterCheckpoint: Bool
    let churnedPrefixKeys: Int
    let deletedPrefixPhysicalIDChanges: Int
    let authorityExactBeforeReopen: Bool
    let reopenExact: Bool
    let targetReadableAfterReopen: Bool
    let segmentSetExactlyReferenced: Bool
}

struct Schema5CheckpointPresealReport: Codable {
    let schemaVersion: Int
    let checkpointDistinctLimit: Int
    let cases: [Schema5CheckpointPresealCase]
    let allChecksPass: Bool
    let claims: [String: Bool]
}
