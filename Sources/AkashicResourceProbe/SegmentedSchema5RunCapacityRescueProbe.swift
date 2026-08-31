import AkashicCore
import AkashicDisk
import Foundation

struct Schema5RunCapacityControlReport: Codable {
    let startingRunCount: Int
    let startingActiveDistinctKeys: Int
    let limitExceeded: Bool
    let rootUnchanged: Bool
    let segmentSetUnchanged: Bool
    let actorAuthorityUnchanged: Bool
    let targetAbsent: Bool
    let reopenExact: Bool
}

struct Schema5RunCapacityRescueCaseReport: Codable {
    let startingRunCount: Int
    let startingActiveDistinctKeys: Int
    let boundaryCommitSucceeded: Bool
    let generationDelta: UInt64
    let finalRunCount: Int
    let finalActiveDistinctKeys: Int
    let finalEntryCount: Int
    let finalProfile: String
    let finalBaseKind: String
    let baseDescriptorUnchanged: Bool
    let finalSegmentFileCount: Int
    let segmentSetExactlyReferenced: Bool
    let priorAuthorityPreserved: Bool
    let targetAuthorityExact: Bool
    let reopenExact: Bool
    let targetReadableAfterReopen: Bool
}

struct Schema5RunCapacityFallbackReport: Codable {
    let schemaVersion: Int
    let startingRunCount: Int
    let startingLiveEntryCount: Int
    let startingActiveDistinctKeys: Int
    let collapsePlanRejected: Bool
    let boundaryCommitSucceeded: Bool
    let generationDelta: UInt64
    let finalRunCount: Int
    let finalEntryCount: Int
    let baseDescriptorChanged: Bool
    let finalSegmentFileCount: Int
    let segmentSetExactlyReferenced: Bool
    let priorAuthorityPreserved: Bool
    let targetAuthorityExact: Bool
    let reopenExact: Bool
    let targetReadableAfterReopen: Bool
    let claims: [String: Bool]
}

struct Schema5RunCapacityRescueReport: Codable {
    struct Claims: Codable {
        let publicDefaultChanged: Bool
        let automaticBackgroundCompaction: Bool
        let hardCapacityProgressCandidate: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let maximumRunDescriptors: Int
    let maximumRecordsPerRun: Int
    let control: Schema5RunCapacityControlReport
    let rescue: Schema5RunCapacityRescueCaseReport
    let collapseFirstRescue: Schema5RunCapacityRescueCaseReport
    let allChecksPass: Bool
    let claims: Claims
}
