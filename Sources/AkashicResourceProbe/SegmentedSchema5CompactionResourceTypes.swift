import AkashicCore
import AkashicDisk
import Darwin
import Foundation

enum Schema5CompactionResourceProfile: String, Sendable {
    case v1JSON = "v1-json"
    case v2Binary = "v2-binary"
    case v3CompactBinary = "v3-binary-compact"
}

struct Schema5CompactionResourceBarrier {
    let readyFD: Int32
    let goFD: Int32
    let doneFD: Int32
    let releaseFD: Int32

    func enter() throws {
        try writeByte(0x52, to: readyFD)
        try readByte(from: goFD)
    }

    func leave() throws {
        try writeByte(0x44, to: doneFD)
        try readByte(from: releaseFD)
    }

    private func writeByte(_ value: UInt8, to descriptor: Int32) throws {
        var value = value
        while true {
            let result = Darwin.write(descriptor, &value, 1)
            if result == 1 { return }
            if result < 0, errno == EINTR { continue }
            throw SegmentedManifestShadowError.invalidFormat
        }
    }

    private func readByte(from descriptor: Int32) throws {
        var value: UInt8 = 0
        while true {
            let result = Darwin.read(descriptor, &value, 1)
            if result == 1 { return }
            if result < 0, errno == EINTR { continue }
            throw SegmentedManifestShadowError.invalidFormat
        }
    }
}

actor Schema5CompactionResourceGate {
    private var preparationStartedAt: UInt64?
    private var candidateVerifiedAt: UInt64?
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseRequested = false
    private var verifiedPauseContinuation: CheckedContinuation<Void, Never>?

    func preparationStarted() {
        if preparationStartedAt == nil {
            preparationStartedAt = DispatchTime.now().uptimeNanoseconds
        }
        let waiters = preparationWaiters
        preparationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    func waitForPreparationStart() async {
        if preparationStartedAt != nil { return }
        await withCheckedContinuation { continuation in
            preparationWaiters.append(continuation)
        }
    }

    func candidateVerifiedAndPause() async {
        if candidateVerifiedAt == nil {
            candidateVerifiedAt = DispatchTime.now().uptimeNanoseconds
        }
        guard !releaseRequested else { return }
        await withCheckedContinuation { continuation in
            verifiedPauseContinuation = continuation
        }
    }

    func releaseVerifiedPause() {
        releaseRequested = true
        verifiedPauseContinuation?.resume()
        verifiedPauseContinuation = nil
    }

    func timing() -> (preparationStartedAt: UInt64?, candidateVerifiedAt: UInt64?) {
        (preparationStartedAt, candidateVerifiedAt)
    }
}

struct Schema5CompactionResourceSegmentStats: Codable, Sendable {
    let fileCount: Int
    let byteCount: Int
}

struct Schema5CompactionResourceMeasuredResult: Sendable {
    let foregroundOperationNanoseconds: [UInt64]
    let foregroundStartedAt: UInt64
    let foregroundEndedAt: UInt64
    let checkpointNanoseconds: UInt64?
    let capacityBackpressureObserved: Bool
    let postCompactionRetryNanoseconds: UInt64?
    let compactionPublished: Bool?
    let compactionStartedAt: UInt64?
    let candidateVerifiedAt: UInt64?
    let compactionEndedAt: UInt64?
    let pausedSegmentStats: Schema5CompactionResourceSegmentStats?
    let finalSegmentStats: Schema5CompactionResourceSegmentStats
    let finalRootRunCount: Int
    let finalRootBytes: Int
    let finalBaseBytes: Int
    let finalActorSnapshot: FileBlobStoreManifestShadowSnapshot
    let finalActiveDistinctKeys: Int
}

struct Schema5CompactionResourceCaseReport: Codable {
    struct Claims: Codable {
        let mechanismMeasurement: Bool
        let formalPerformance: Bool
        let endToEndStorePerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let energy: Bool
        let powerLoss: Bool
        let automaticCompactionTrigger: Bool
    }

    let schemaVersion: Int
    let profile: String
    let mode: String
    let liveEntries: Int
    let frozenRunCount: Int
    let recordsPerRun: Int
    let replayRecords: Int
    let history: String
    let workload: String
    let foregroundPayloadBytes: Int
    let frozenBaseBytes: Int
    let frozenRunBytes: Int
    let frozenRootBytes: Int
    let frozenSegmentStats: Schema5CompactionResourceSegmentStats
    let pausedSegmentStats: Schema5CompactionResourceSegmentStats?
    let finalSegmentStats: Schema5CompactionResourceSegmentStats
    let finalRootRunCount: Int
    let finalRootBytes: Int
    let finalBaseBytes: Int
    let foregroundOperationNanoseconds: [UInt64]
    let foregroundElapsedNanoseconds: UInt64
    let checkpointNanoseconds: UInt64?
    let capacityBackpressureObserved: Bool
    let postCompactionRetryNanoseconds: UInt64?
    let compactionPublished: Bool?
    let compactionPreparationNanoseconds: UInt64?
    let compactionTotalNanoseconds: UInt64?
    let foregroundPreparationOverlapNanoseconds: UInt64?
    let finalActiveDistinctKeys: Int
    let frozenIdentityCommitment: String
    let actorEntryCount: Int
    let freshReopenEntryCount: Int
    let actorLogicalAuthorityCommitment: String
    let freshReopenLogicalAuthorityCommitment: String
    let actorIdentityCommitment: String
    let freshReopenIdentityCommitment: String
    let freshReopenExact: Bool
    let claims: Claims
}
