import AkashicCore
import AkashicDisk
import Foundation

actor Schema5StablePrefixPreparationGate {
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func reachAndPause() async {
        reached = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct Schema5StablePrefixOverlapCase: Codable {
    let startingRunCount: Int
    let runCountWhilePreparationPaused: Int
    let backgroundPrepared: Bool
    let preparedPrefixRunCount: Int
    let preparedReplacementRunCount: Int
    let preparedObservedSuffixRunCount: Int
    let finalRunCountAfterAdoption: Int
    let authorityUnchangedByAdoption: Bool
    let segmentSetExactlyReferenced: Bool
    let reopenExact: Bool
    let sampleReadable: Bool
}

struct Schema5StablePrefixHardCapCase: Codable {
    let startingRunCount: Int
    let runCountAfterFirstForegroundCheckpoint: Int
    let finalBoundaryCommitSucceededWhilePreparationPaused: Bool
    let runCountBeforeBackgroundResume: Int
    let activeDistinctBeforeBackgroundResume: Int
    let unreferencedReadLeasedRunCountBeforeResume: Int
    let backgroundCandidatePublishedAfterResume: Bool
    let runCountAfterBackgroundResume: Int
    let authorityUnchangedByBackgroundResume: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let reopenExact: Bool
    let sampleReadable: Bool
}

struct Schema5StablePrefixMaterializationOverlapCase: Codable {
    let startingRunCount: Int
    let sourceReadLeaseCountWhileMaterializationPaused: Int
    let reservedOutputNameCountWhilePaused: Int
    let materializedOutputNameCountWhilePaused: Int
    let materializationTaskActiveWhilePaused: Bool
    let runCountAfterForegroundCheckpointWhilePaused: Int
    let preparedObservedSuffixRunCount: Int
    let finalRunCountAfterAdoption: Int
    let authorityUnchangedByAdoption: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let reopenExact: Bool
    let sampleReadable: Bool
}

struct Schema5StablePrefixMaterializationHardCapCase: Codable {
    let startingRunCount: Int
    let reservedOutputNameCountWhilePaused: Int
    let materializedOutputNameCountWhilePaused: Int
    let runCountAfterFirstForegroundCheckpoint: Int
    let runCountAfterHardCapRescue: Int
    let sourceReadLeaseCountAfterHardCapBeforeResume: Int
    let reservedOutputNameCountAfterHardCapBeforeResume: Int
    let materializedOutputNameCountAfterHardCapBeforeResume: Int
    let materializationTaskActiveAfterHardCapBeforeResume: Bool
    let segmentSetExactlyReferencedBeforeBackgroundResume: Bool
    let backgroundCandidatePublishedAfterResume: Bool
    let backgroundStateClearedAfterResume: Bool
    let authorityUnchangedByBackgroundResume: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let reopenExact: Bool
    let sampleReadable: Bool
}

struct Schema5StablePrefixConcurrencyReport: Codable {
    struct Claims: Codable {
        let foregroundProgressDuringDetachedPreparation: Bool
        let hardProgressIndependentOfBackgroundCompletion: Bool
        let automaticSchedulingSelected: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let suffixOverlap: Schema5StablePrefixOverlapCase
    let hardCapIndependence: Schema5StablePrefixHardCapCase
    let materializationOverlap: Schema5StablePrefixMaterializationOverlapCase
    let materializationHardCapIndependence: Schema5StablePrefixMaterializationHardCapCase
    let allChecksPass: Bool
    let claims: Claims
}
