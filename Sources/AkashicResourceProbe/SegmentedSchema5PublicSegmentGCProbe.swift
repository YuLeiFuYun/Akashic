import AkashicCore
import AkashicDisk
import Darwin
import Foundation

enum Schema5PublicGCInjectedError: Error {
    case preRename
}

struct Schema5PublicSegmentGCReport: Codable {
    struct CallerCauseLoss: Codable {
        let bootstrapAuthorityExact: Bool
        let activeDistinctKeysBeforeRejectedMutation: Int
        let directFailureFileNameMatches: Bool
        let directFailurePOSIXCode: Int32?
        let directRemainingDebtCount: Int
        let mutationRejectedAsLimitExceeded: Bool
        let mutationErrorText: String?
        let rejectedMutationAuthorityExact: Bool
        let rootUnchangedAfterRejectedMutation: Bool
        let activeDistinctKeysAfterRejectedMutation: Int
        let retryAfterObstacleRemovedSucceeded: Bool
        let retryAuthorityAdvanced: Bool
        let activeDistinctKeysAfterRetry: Int
    }

    struct Claims: Codable {
        let sameUserRaceProtection: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let checkpointOrphanRemoved: Bool
    let checkpointOldAuthorityExact: Bool
    let validUnreferencedRemoved: Bool
    let corruptUnreferencedRemoved: Bool
    let foreignNoncanonicalPreserved: Bool
    let symlinkCanonicalRejected: Bool
    let symlinkTargetPreserved: Bool
    let hardlinkCanonicalRejected: Bool
    let hardlinkTargetPreserved: Bool
    let unsafeModeCanonicalRejected: Bool
    let immutableOpenExact: Bool
    let immutableDebtRemained: Bool
    let immutableRetryRemoved: Bool
    let boundedOverflowRejected: Bool
    let callerCauseLoss: CallerCauseLoss
    let maximumDirectoryEntries: Int
    let claims: Claims
}
