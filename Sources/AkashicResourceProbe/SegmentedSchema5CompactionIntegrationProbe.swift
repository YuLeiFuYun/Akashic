import AkashicCore
import AkashicDisk
import Foundation

private actor Schema5CompactionPauseGate {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct Schema5CompactionSuffixLiveResult: Sendable {
    let secondRejected: Bool
    let checkpointPublished: Bool
    let candidatePreserved: Bool
    let published: Bool
    let generationPreserved: Bool
    let runPreserved: Bool
    let postCheckpoint: FileBlobStoreManifestShadowSnapshot
    let postCheckpointCommitment: String
    let actorExact: Bool
    let rootAfter: SegmentedManifestRootV1
    let namesAfter: [String]
}

private struct Schema5CompactionIntegrationReport: Codable {
    struct Claims: Codable {
        let automaticTrigger: Bool
        let formalPerformance: Bool
        let powerLoss: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let simplePublished: Bool
    let simpleGenerationStable: Bool
    let simpleActiveHeadStable: Bool
    let simpleFreshReopenExact: Bool
    let simpleRetiredSegmentsRepaid: Bool
    let noRunReturnedFalse: Bool
    let noRunNoMaterialization: Bool
    let suffixSecondCompactionRejected: Bool
    let suffixCheckpointPublished: Bool
    let suffixCandidatePreservedAcrossCheckpoint: Bool
    let suffixPublished: Bool
    let suffixNewerGenerationPreserved: Bool
    let suffixRunPreserved: Bool
    let suffixFreshReopenExact: Bool
    let suffixRetiredSegmentsRepaid: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5CompactionIntegration(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let simple = try await schema5CompactionSimpleCase(
            root: root.appendingPathComponent("simple", isDirectory: true)
        )
        let noRun = try await schema5CompactionNoRunCase(
            root: root.appendingPathComponent("no-run", isDirectory: true)
        )
        let suffix = try await schema5CompactionSuffixCase(
            root: root.appendingPathComponent("suffix", isDirectory: true)
        )

        let report = Schema5CompactionIntegrationReport(
            schemaVersion: 1,
            simplePublished: simple.published,
            simpleGenerationStable: simple.generationStable,
            simpleActiveHeadStable: simple.activeHeadStable,
            simpleFreshReopenExact: simple.reopenExact,
            simpleRetiredSegmentsRepaid: simple.retiredRepaid,
            noRunReturnedFalse: noRun.returnedFalse,
            noRunNoMaterialization: noRun.noMaterialization,
            suffixSecondCompactionRejected: suffix.secondRejected,
            suffixCheckpointPublished: suffix.checkpointPublished,
            suffixCandidatePreservedAcrossCheckpoint: suffix.candidatePreserved,
            suffixPublished: suffix.published,
            suffixNewerGenerationPreserved: suffix.generationPreserved,
            suffixRunPreserved: suffix.runPreserved,
            suffixFreshReopenExact: suffix.reopenExact,
            suffixRetiredSegmentsRepaid: suffix.retiredRepaid,
            claims: .init(
                automaticTrigger: false,
                formalPerformance: false,
                powerLoss: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))

        let checks = [
            simple.published, simple.generationStable, simple.activeHeadStable,
            simple.reopenExact, simple.retiredRepaid,
            noRun.returnedFalse, noRun.noMaterialization,
            suffix.secondRejected, suffix.checkpointPublished, suffix.candidatePreserved,
            suffix.published, suffix.generationPreserved, suffix.runPreserved,
            suffix.reopenExact, suffix.retiredRepaid,
        ]
        guard checks.allSatisfy({ $0 }) else {
            throw SegmentedManifestShadowError.invariantViolation
        }
    }

    private static func schema5CompactionSimpleCase(
        root: URL
    ) async throws -> (
        published: Bool,
        generationStable: Bool,
        activeHeadStable: Bool,
        reopenExact: Bool,
        retiredRepaid: Bool
    ) {
        var store: FileBlobStore? = try await schema5CompactionOneRunStore(root: root)
        let extra = try schema5IntegrationIdentities(prefix: "compact-active", count: 1)[0]
        _ = try await store!.commit(
            data: extra.data,
            digest: extra.digest,
            partition: extra.partition
        )
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        let activeBefore = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let rootBefore = try schema5CompactionReadRoot(root)
        let segmentDirectory = schema5CompactionSegmentDirectory(root)
        let beforeNames = try schema5CompactionSegmentNames(segmentDirectory)

        let published = try await store!.resourceProbeCompactSegmentedManifestV1()
        let rootAfter = try schema5CompactionReadRoot(root)
        let activeAfter = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterNames = try schema5CompactionSegmentNames(segmentDirectory)
        let actorExact = try schema5IdentityCommitment(after.entries) == beforeCommitment
            && after.entries == before.entries

        store = nil
        store = try await schema5CompactionOpen(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let activeReopened = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let reopenedCommitment = try schema5IdentityCommitment(reopened.entries)
        let reopenExact = actorExact
            && reopenedCommitment == beforeCommitment
            && reopened.entries == before.entries
            && activeReopened.distinctKeyCount == activeBefore.distinctKeyCount
            && activeReopened.activeSequence == activeBefore.activeSequence

        return (
            published: published,
            generationStable: rootBefore.runs.count == 1
                && rootAfter.generation == rootBefore.generation
                && rootAfter.runs.isEmpty
                && rootAfter.base.fileName.hasPrefix("base-compaction-"),
            activeHeadStable: activeBefore.distinctKeyCount == 1
                && activeAfter.distinctKeyCount == activeBefore.distinctKeyCount
                && activeAfter.activeSequence == activeBefore.activeSequence,
            reopenExact: reopenExact,
            retiredRepaid: beforeNames.count == 2
                && afterNames.count == 1
                && afterNames.first == rootAfter.base.fileName
        )
    }

    private static func schema5CompactionNoRunCase(
        root: URL
    ) async throws -> (returnedFalse: Bool, noMaterialization: Bool) {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        let identity = try schema5IntegrationIdentities(prefix: "compact-no-run", count: 1)[0]
        _ = try await store!.commit(
            data: identity.data,
            digest: identity.digest,
            partition: identity.partition
        )
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
        store = try await schema5CompactionOpen(root: root)
        let rootBefore = try schema5CompactionReadRoot(root)
        let directory = schema5CompactionSegmentDirectory(root)
        let namesBefore = try schema5CompactionSegmentNames(directory)
        let result = try await store!.resourceProbeCompactSegmentedManifestV1()
        let rootAfter = try schema5CompactionReadRoot(root)
        let namesAfter = try schema5CompactionSegmentNames(directory)
        return (
            returnedFalse: !result,
            noMaterialization: rootBefore == rootAfter
                && namesBefore == namesAfter
                && rootAfter.runs.isEmpty
        )
    }

    private static func schema5CompactionSuffixCase(
        root: URL
    ) async throws -> (
        secondRejected: Bool,
        checkpointPublished: Bool,
        candidatePreserved: Bool,
        published: Bool,
        generationPreserved: Bool,
        runPreserved: Bool,
        reopenExact: Bool,
        retiredRepaid: Bool
    ) {
        let live = try await schema5CompactionSuffixLivePhase(root: root)
        let reopenedStore = try await schema5CompactionOpen(root: root)
        let reopened = await reopenedStore.resourceProbeManifestShadowSnapshot()
        let activeReopened = try await reopenedStore.resourceProbeDirectoryHeadEpochSnapshot()
        let reopenedCommitment = try schema5IdentityCommitment(reopened.entries)
        let reopenExact = live.actorExact
            && reopenedCommitment == live.postCheckpointCommitment
            && reopened.entries == live.postCheckpoint.entries
            && activeReopened.distinctKeyCount == 0
        return (
            secondRejected: live.secondRejected,
            checkpointPublished: live.checkpointPublished,
            candidatePreserved: live.candidatePreserved,
            published: live.published,
            generationPreserved: live.generationPreserved,
            runPreserved: live.runPreserved,
            reopenExact: reopenExact,
            retiredRepaid: live.namesAfter.count == 2
                && live.namesAfter.contains(live.rootAfter.base.fileName)
                && live.rootAfter.runs.count == 1
                && live.namesAfter.contains(live.rootAfter.runs[0].fileName)
        )
    }

    private static func schema5CompactionSuffixLivePhase(
        root: URL
    ) async throws -> Schema5CompactionSuffixLiveResult {
        let store = try await schema5CompactionOneRunStore(root: root)
        let suffix = try schema5IntegrationIdentities(prefix: "compact-suffix", count: 512)
        for index in 0...510 {
            _ = try await store.commit(
                data: suffix[index].data,
                digest: suffix[index].digest,
                partition: suffix[index].partition
            )
        }
        let rootFrozen = try schema5CompactionReadRoot(root)
        let activeBefore = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard rootFrozen.runs.count == 1, activeBefore.distinctKeyCount == 511 else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let gate = Schema5CompactionPauseGate()
        let compaction = Task { [store, gate] in
            try await store.resourceProbeCompactSegmentedManifestV1(observer: { _ in
                await gate.pause()
            })
        }
        await gate.waitUntilPaused()
        let directory = schema5CompactionSegmentDirectory(root)
        let pausedNames = try schema5CompactionSegmentNames(directory)
        guard let candidateName = pausedNames.first(where: { $0.hasPrefix("base-compaction-") }) else {
            await gate.release()
            _ = try await compaction.value
            throw SegmentedManifestShadowError.invariantViolation
        }

        let secondRejected: Bool
        do {
            _ = try await store.resourceProbeCompactSegmentedManifestV1()
            secondRejected = false
        } catch AkashicError.transactionConflict {
            secondRejected = true
        }

        _ = try await store.commit(
            data: suffix[511].data,
            digest: suffix[511].digest,
            partition: suffix[511].partition
        )
        let postCheckpoint = await store.resourceProbeManifestShadowSnapshot()
        let postCheckpointCommitment = try schema5IdentityCommitment(postCheckpoint.entries)
        let rootWithSuffix = try schema5CompactionReadRoot(root)
        let activeAfterCheckpoint = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let afterCheckpointNames = try schema5CompactionSegmentNames(directory)
        let checkpointPublished = rootWithSuffix.generation == rootFrozen.generation + 1
            && rootWithSuffix.runs.count == 2
            && activeAfterCheckpoint.distinctKeyCount == 0

        await gate.release()
        let published = try await compaction.value
        let rootAfter = try schema5CompactionReadRoot(root)
        let actorAfter = await store.resourceProbeManifestShadowSnapshot()
        let namesAfter = try schema5CompactionSegmentNames(directory)
        let actorCommitment = try schema5IdentityCommitment(actorAfter.entries)
        return Schema5CompactionSuffixLiveResult(
            secondRejected: secondRejected,
            checkpointPublished: checkpointPublished,
            candidatePreserved: afterCheckpointNames.contains(candidateName)
                && rootAfter.base.fileName == candidateName,
            published: published,
            generationPreserved: rootAfter.generation == rootWithSuffix.generation,
            runPreserved: rootAfter.runs.count == 1
                && rootAfter.runs.first == rootWithSuffix.runs.last,
            postCheckpoint: postCheckpoint,
            postCheckpointCommitment: postCheckpointCommitment,
            actorExact: actorCommitment == postCheckpointCommitment
                && actorAfter.entries == postCheckpoint.entries,
            rootAfter: rootAfter,
            namesAfter: namesAfter
        )
    }

    private static func schema5CompactionOneRunStore(root: URL) async throws -> FileBlobStore {
        let store = try await schema5PrepareCheckpointSeed(root: root).store
        let target = try schema5IntegrationIdentities(prefix: "hot", count: 512)[511]
        _ = try await store.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        let rootValue = try schema5CompactionReadRoot(root)
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard rootValue.runs.count == 1,
            rootValue.runs[0].recordCount == 512,
            active.distinctKeyCount == 0
        else { throw SegmentedManifestShadowError.invariantViolation }
        return store
    }

    private static func schema5CompactionReadRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func schema5CompactionSegmentDirectory(_ root: URL) -> URL {
        root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
    }

    private static func schema5CompactionSegmentNames(_ directory: URL) throws -> [String] {
        try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).sorted()
    }

    private static func schema5CompactionOpen(root: URL) async throws -> FileBlobStore {
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
}
