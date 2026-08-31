import AkashicCore
import AkashicDisk
import Foundation

private actor Schema5HeadroomPauseGate {
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let current = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in current { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct Schema5HeadroomLiveResult: Sendable {
    let startingRuns: Int
    let firstCheckpointPublished: Bool
    let secondCheckpointPublished: Bool
    let hardCeilingRejectedBeforeSegment: Bool
    let rejectedKeyAbsent: Bool
    let active511Preserved: Bool
    let candidatePreserved: Bool
    let compactionPublished: Bool
    let suffixCountAfterCompaction: Int
    let retrySucceeded: Bool
    let finalRunCount: Int
    let finalActiveDistinctKeys: Int
    let finalCommitment: String
    let finalEntries: [String: FileBlobStoreRecordShadowEntry]
    let finalSegmentSetExact: Bool
    let maximumObservedRunCount: Int
}

private struct Schema5HeadroomCaseReport: Codable {
    let startingRuns: Int
    let firstCheckpointPublished: Bool
    let secondCheckpointPublishedBeforeResume: Bool
    let hardCeilingRejectedBeforeSegment: Bool
    let rejectedKeyAbsent: Bool
    let active511PreservedAtCeiling: Bool
    let candidatePreserved: Bool
    let compactionPublished: Bool
    let suffixCountAfterCompaction: Int
    let retryAfterCompactionSucceeded: Bool
    let finalRunCount: Int
    let finalActiveDistinctKeys: Int
    let finalExactAfterReopen: Bool
    let finalSegmentSetExact: Bool
    let maximumObservedRunCount: Int
}

private struct Schema5HeadroomReport: Codable {
    struct Claims: Codable {
        let automaticTrigger: Bool
        let synchronousForegroundCompaction: Bool
        let formalLatency: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let cases: [Schema5HeadroomCaseReport]
    let allCasesPass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5CompactionHeadroom(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var cases: [Schema5HeadroomCaseReport] = []
        for startingRuns in [48, 60, 63] {
            cases.append(
                try await schema5HeadroomCase(
                    root: root.appendingPathComponent("runs-\(startingRuns)", isDirectory: true),
                    startingRuns: startingRuns
                )
            )
        }
        let all = cases.allSatisfy { item in
            item.firstCheckpointPublished
                && item.candidatePreserved
                && item.compactionPublished
                && item.finalExactAfterReopen
                && item.finalSegmentSetExact
                && item.maximumObservedRunCount <= SegmentedManifestPrototypeV1.maximumRunDescriptors
                && (item.startingRuns < 63
                    ? item.secondCheckpointPublishedBeforeResume
                        && !item.hardCeilingRejectedBeforeSegment
                        && item.suffixCountAfterCompaction == 2
                        && item.finalRunCount == 2
                        && item.finalActiveDistinctKeys == 0
                    : item.hardCeilingRejectedBeforeSegment
                        && item.rejectedKeyAbsent
                        && item.active511PreservedAtCeiling
                        && item.suffixCountAfterCompaction == 1
                        && item.retryAfterCompactionSucceeded
                        && item.finalRunCount == 2
                        && item.finalActiveDistinctKeys == 0)
        }
        let report = Schema5HeadroomReport(
            schemaVersion: 1,
            cases: cases,
            allCasesPass: all,
            claims: .init(
                automaticTrigger: false,
                synchronousForegroundCompaction: false,
                formalLatency: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5HeadroomCase(
        root: URL,
        startingRuns: Int
    ) async throws -> Schema5HeadroomCaseReport {
        let live = try await schema5HeadroomLivePhase(root: root, startingRuns: startingRuns)
        let reopenedStore = try await schema5HeadroomOpen(root)
        let reopened = await reopenedStore.resourceProbeManifestShadowSnapshot()
        let reopenedHead = try await reopenedStore.resourceProbeDirectoryHeadEpochSnapshot()
        let reopenedRoot = try schema5HeadroomReadRoot(root)
        let reopenedCommitment = try schema5IdentityCommitment(reopened.entries)
        let reopenExact = reopenedCommitment == live.finalCommitment
            && reopened.entries == live.finalEntries
            && reopenedRoot.runs.count == live.finalRunCount
            && reopenedHead.distinctKeyCount == live.finalActiveDistinctKeys
        return Schema5HeadroomCaseReport(
            startingRuns: startingRuns,
            firstCheckpointPublished: live.firstCheckpointPublished,
            secondCheckpointPublishedBeforeResume: live.secondCheckpointPublished,
            hardCeilingRejectedBeforeSegment: live.hardCeilingRejectedBeforeSegment,
            rejectedKeyAbsent: live.rejectedKeyAbsent,
            active511PreservedAtCeiling: live.active511Preserved,
            candidatePreserved: live.candidatePreserved,
            compactionPublished: live.compactionPublished,
            suffixCountAfterCompaction: live.suffixCountAfterCompaction,
            retryAfterCompactionSucceeded: live.retrySucceeded,
            finalRunCount: live.finalRunCount,
            finalActiveDistinctKeys: live.finalActiveDistinctKeys,
            finalExactAfterReopen: reopenExact,
            finalSegmentSetExact: live.finalSegmentSetExact,
            maximumObservedRunCount: live.maximumObservedRunCount
        )
    }

    private static func schema5HeadroomLivePhase(
        root: URL,
        startingRuns: Int
    ) async throws -> Schema5HeadroomLiveResult {
        let store = try await schema5HeadroomSeed(root: root, runCount: startingRuns)
        let gate = Schema5HeadroomPauseGate()
        let compaction = Task { [store, gate] in
            try await store.resourceProbeCompactSegmentedManifestV1(observer: { _ in
                await gate.pause()
            })
        }
        await gate.waitUntilPaused()
        let pausedRoot = try schema5HeadroomReadRoot(root)
        let candidateNames = try schema5HeadroomSegmentNames(root).filter {
            $0.hasPrefix("base-compaction-")
        }
        guard pausedRoot.runs.count == startingRuns, candidateNames.count == 1 else {
            await gate.release()
            _ = try await compaction.value
            throw SegmentedManifestShadowError.invariantViolation
        }
        let candidateName = candidateNames[0]

        let identities = try schema5IntegrationIdentities(
            prefix: "headroom-\(startingRuns)",
            count: 1_024
        )
        for index in 0..<512 {
            _ = try await store.commit(
                data: identities[index].data,
                digest: identities[index].digest,
                partition: identities[index].partition
            )
        }
        let afterFirstRoot = try schema5HeadroomReadRoot(root)
        let firstCheckpointPublished = afterFirstRoot.runs.count == startingRuns + 1
        var maximumObservedRunCount = afterFirstRoot.runs.count
        var candidatePreserved = try schema5HeadroomSegmentNames(root).contains(candidateName)

        var secondCheckpointPublished = false
        var hardCeilingRejectedBeforeSegment = false
        var rejectedKeyAbsent = false
        var active511Preserved = false
        var rejectedIdentity: MigrationIdentity?

        if startingRuns < 63 {
            for index in 512..<1_024 {
                _ = try await store.commit(
                    data: identities[index].data,
                    digest: identities[index].digest,
                    partition: identities[index].partition
                )
            }
            let rootAfterSecond = try schema5HeadroomReadRoot(root)
            maximumObservedRunCount = max(maximumObservedRunCount, rootAfterSecond.runs.count)
            secondCheckpointPublished = rootAfterSecond.runs.count == startingRuns + 2
            let candidateStillPresent = try schema5HeadroomSegmentNames(root).contains(candidateName)
            candidatePreserved = candidatePreserved && candidateStillPresent
        } else {
            for index in 512..<1_023 {
                _ = try await store.commit(
                    data: identities[index].data,
                    digest: identities[index].digest,
                    partition: identities[index].partition
                )
            }
            let beforeRejectRoot = try schema5HeadroomReadRoot(root)
            let beforeRejectSegments = try schema5HeadroomSegmentNames(root)
            let beforeRejectSnapshot = await store.resourceProbeManifestShadowSnapshot()
            let beforeRejectHead = try await store.resourceProbeDirectoryHeadEpochSnapshot()
            let identity = identities[1_023]
            rejectedIdentity = identity
            do {
                _ = try await store.commit(
                    data: identity.data,
                    digest: identity.digest,
                    partition: identity.partition
                )
            } catch AkashicError.limitExceeded {
                let afterRejectRoot = try schema5HeadroomReadRoot(root)
                let afterRejectSegments = try schema5HeadroomSegmentNames(root)
                let afterRejectSnapshot = await store.resourceProbeManifestShadowSnapshot()
                let afterRejectHead = try await store.resourceProbeDirectoryHeadEpochSnapshot()
                hardCeilingRejectedBeforeSegment = beforeRejectRoot.runs.count == 64
                    && afterRejectRoot == beforeRejectRoot
                    && afterRejectSegments == beforeRejectSegments
                rejectedKeyAbsent = beforeRejectSnapshot.entries[identity.key] == nil
                    && afterRejectSnapshot.entries[identity.key] == nil
                    && afterRejectSnapshot.entries == beforeRejectSnapshot.entries
                active511Preserved = beforeRejectHead.distinctKeyCount == 511
                    && afterRejectHead.distinctKeyCount == 511
                    && afterRejectHead.activeSequence == beforeRejectHead.activeSequence
            }
            let candidateStillPresent = try schema5HeadroomSegmentNames(root).contains(candidateName)
            candidatePreserved = candidatePreserved && candidateStillPresent
            maximumObservedRunCount = max(maximumObservedRunCount, 64)
        }

        await gate.release()
        let compactionPublished = try await compaction.value
        let rootAfterCompaction = try schema5HeadroomReadRoot(root)
        let suffixCountAfterCompaction = rootAfterCompaction.runs.count
        var retrySucceeded = startingRuns < 63

        if let rejectedIdentity {
            _ = try await store.commit(
                data: rejectedIdentity.data,
                digest: rejectedIdentity.digest,
                partition: rejectedIdentity.partition
            )
            let afterRetryRoot = try schema5HeadroomReadRoot(root)
            let afterRetryHead = try await store.resourceProbeDirectoryHeadEpochSnapshot()
            retrySucceeded = afterRetryRoot.runs.count == 2
                && afterRetryHead.distinctKeyCount == 0
        }

        let finalActor = await store.resourceProbeManifestShadowSnapshot()
        let finalCommitment = try schema5IdentityCommitment(finalActor.entries)
        let finalRoot = try schema5HeadroomReadRoot(root)
        let finalHead = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let finalNames = try schema5HeadroomSegmentNames(root)
        let expectedNames = Set([finalRoot.base.fileName] + finalRoot.runs.map(\.fileName))
        let finalSegmentSetExact = Set(finalNames) == expectedNames
            && finalNames.count == expectedNames.count
        return Schema5HeadroomLiveResult(
            startingRuns: startingRuns,
            firstCheckpointPublished: firstCheckpointPublished,
            secondCheckpointPublished: secondCheckpointPublished,
            hardCeilingRejectedBeforeSegment: hardCeilingRejectedBeforeSegment,
            rejectedKeyAbsent: rejectedKeyAbsent,
            active511Preserved: active511Preserved,
            candidatePreserved: candidatePreserved,
            compactionPublished: compactionPublished,
            suffixCountAfterCompaction: suffixCountAfterCompaction,
            retrySucceeded: retrySucceeded,
            finalRunCount: finalRoot.runs.count,
            finalActiveDistinctKeys: finalHead.distinctKeyCount,
            finalCommitment: finalCommitment,
            finalEntries: finalActor.entries,
            finalSegmentSetExact: finalSegmentSetExact,
            maximumObservedRunCount: maximumObservedRunCount
        )
    }

    private static func schema5HeadroomSeed(root: URL, runCount: Int) async throws -> FileBlobStore {
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(root.appendingPathComponent("blobs", isDirectory: true))
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(directory)
        let generation: UInt64 = 10
        let baseData = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: generation,
            entries: [:]
        )
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: 0,
            fileName: "base-migration-\(UUID().uuidString.lowercased()).json",
            directory: directory
        )
        let identities = try schema5IntegrationIdentities(prefix: "headroom-history-\(runCount)", count: runCount)
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(runCount)
        for index in 0..<runCount {
            runs.append(
                try SegmentedManifestPrototypeV1.writeRun(
                    [.tombstone(key: identities[index].key)],
                    fileName: "run-g\(generation)-\(UUID().uuidString.lowercased()).seg",
                    directory: directory
                )
            )
        }
        let rootValue = try SegmentedManifestPrototypeV1.makeRoot(
            generation: generation,
            base: base,
            runs: runs
        )
        try SegmentedManifestPrototypeV1.writeRoot(
            rootValue,
            to: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        return try await FileBlobStore.open(root: root)
    }

    private static func schema5HeadroomOpen(_ root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do { return try await FileBlobStore.open(root: root) }
            catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.transactionConflict {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    private static func schema5HeadroomReadRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func schema5HeadroomSegmentNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        return try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).sorted()
    }
}
