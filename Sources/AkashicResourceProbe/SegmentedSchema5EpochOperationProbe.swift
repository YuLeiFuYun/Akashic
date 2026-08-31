import AkashicCore
import AkashicDisk
import Foundation

enum EpochOperation {
    case removeOld(Int)
    case addNew(Int)
    case readdOld(Int)
}

struct EpochOperationIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    var key: String { FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition) }
}

struct EpochOperationCase: Codable {
    let name: String
    let requestOperationCount: Int
    let effectiveAuthorityMutationCount: Int
    let effectiveDistinctManifestKeyCount: Int
    let predictedCheckpointCount: Int
    let actualRootGenerationDelta: UInt64
    let predictedFinalActiveDistinctKeys: Int
    let actualFinalActiveDistinctKeys: Int
    let expectedFinalAuthorityCount: Int
    let actualFinalAuthorityCount: Int
    let authorityExactBeforeReopen: Bool
    let reopenExact: Bool
    let exactEpochPrediction: Bool
}

struct EpochOperationReport: Codable {
    let schemaVersion: Int
    let thresholdDistinctKeysPerEpoch: Int
    let cases: [EpochOperationCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

struct EpochPhaseAliasingCase: Codable {
    let name: String
    let preconditionRequestCount: Int
    let preconditionLogicalAuthorityExact: Bool
    let preconditionPhysicalIDChanges: Int
    let preconditionActiveDistinctKeys: Int
    let preconditionRootRunCount: Int
    let futureRequestCount: Int
    let futureUniqueKeyCount: Int
    let futureRegularMetadataWriteBytes: Int64
    let futureRootPublicationCount: Int
    let futureRootPublicationBytes: Int64
    let futureSegmentPublicationCount: Int
    let futureSegmentPublicationBytes: Int64
    let futureRootGenerationDelta: UInt64
    let finalActiveDistinctKeys: Int
    let finalLogicalAuthorityExact: Bool
    let reopenExact: Bool
    let finalPhysicalIDChanges: Int
}

struct EpochPhaseAliasingReport: Codable {
    let schemaVersion: Int
    let thresholdDistinctKeysPerEpoch: Int
    let preconditionKeyCount: Int
    let futureUniqueKeyCount: Int
    let cases: [EpochPhaseAliasingCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}
