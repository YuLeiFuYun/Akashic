import AkashicCore
import AkashicDisk
import Foundation

actor Schema5StablePrefixSuffixAdmissionGate {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func reachAndPause() async {
        reached = true
        let current = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in current { waiter.resume() }
        await withCheckedContinuation { continuation in releaseContinuation = continuation }
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

enum Schema5StablePrefixSuffixAdmissionStage: String, Codable {
    case planning
    case materialization
}

struct Schema5StablePrefixSuffixAdmissionIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    let key: String
}

struct Schema5StablePrefixSuffixAdmissionCase: Codable {
    let stage: Schema5StablePrefixSuffixAdmissionStage
    let seededRunCount: Int
    let triggerRunCount: Int
    let frozenPlanInputRunCount: Int
    let frozenPlanOutputRunCount: Int
    let frozenPlanInputRunBytes: Int
    let frozenPlanOutputRunBytes: Int
    let frozenStaticAdmissionAccepted: Bool
    let suffixAwareAdmissionAtSixteenAccepted: Bool
    let suffixCheckpointsBeforeResume: Int
    let runCountBeforeResume: Int
    let sourceReadLeaseCountWhilePaused: Int
    let reservedOutputNameCountWhilePaused: Int
    let materializedOutputNameCountWhilePaused: Int
    let planningTaskActiveWhilePaused: Bool
    let materializationTaskActiveWhilePaused: Bool
    let runCountAfterAutomaticRejection: Int
    let automaticAttemptCount: Int
    let automaticPreparedCount: Int
    let automaticAdoptedCount: Int
    let automaticNilCount: Int
    let automaticErrorCount: Int
    let automaticHardCapCancellationCount: Int
    let automaticSuffixBeforeMaterializationCount: Int
    let automaticSuffixAfterMaterializationCount: Int
    let automaticNextRetryRunCount: Int?
    let authorityUnchangedByAutomaticRejection: Bool
    let backgroundStateClearedAfterRejection: Bool
    let segmentSetExactlyReferencedAfterRejection: Bool
    let hardBoundaryCommitSucceeded: Bool
    let runCountAfterHardBoundary: Int
    let physicalOwnershipExact: Bool
    let finalAuthorityCount: Int
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenExact: Bool
    let sampleReadable: Bool
}

struct Schema5StablePrefixSuffixAdmissionReport: Codable {
    let schemaVersion: Int
    let planningLag: Schema5StablePrefixSuffixAdmissionCase
    let materializationLag: Schema5StablePrefixSuffixAdmissionCase
    let allChecksPass: Bool
    let claims: [String: Bool]
}
