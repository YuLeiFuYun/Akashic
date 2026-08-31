import AkashicCore
import AkashicDisk
import Foundation

private enum Schema5RunCapacityBackgroundPause: String, CaseIterable, Codable, Sendable {
    case beforePreparation = "before-preparation"
    case candidateVerified = "candidate-verified"
}

private enum Schema5RunCapacityBackgroundPolicy: String, CaseIterable, Codable, Sendable {
    case fullBase = "full-base"
    case collapseFirst = "collapse-first"

    var storePolicy: FileBlobStoreSegmentedRunCapacityPolicy {
        switch self {
        case .fullBase: .synchronousV3CompactionAtHardLimit
        case .collapseFirst: .synchronousV3RunCollapseThenCompactionAtHardLimit
        }
    }
}

private actor Schema5RunCapacityBackgroundGate {
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

private struct Schema5RunCapacityBackgroundCase: Codable {
    let pause: Schema5RunCapacityBackgroundPause
    let policy: Schema5RunCapacityBackgroundPolicy
    let startingRunCount: Int
    let runCountAfterFirstCheckpoint: Int
    let activeDistinctBeforeHardBoundary: Int
    let finalBoundaryCommitSucceededWithoutRetry: Bool
    let finalRunCountBeforeBackgroundResume: Int
    let finalActiveDistinctBeforeBackgroundResume: Int
    let finalEntryCountBeforeBackgroundResume: Int
    let materializedUnreferencedV3BaseCountBeforeResume: Int
    let backgroundCompactionPublishedAfterResume: Bool
    let finalRunCountAfterBackgroundResume: Int
    let finalActiveDistinctAfterBackgroundResume: Int
    let finalSegmentSetExactlyReferenced: Bool
    let finalEntryCount: Int
    let finalAuthorityExact: Bool
    let reopenExact: Bool
    let finalTargetReadable: Bool
}

private struct Schema5RunCapacityBackgroundReport: Codable {
    struct Claims: Codable {
        let hardProgressIndependentOfBackgroundCompletion: Bool
        let automaticTriggerSelected: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let cases: [Schema5RunCapacityBackgroundCase]
    let allChecksPass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5RunCapacityBackgroundComposition(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rows: [Schema5RunCapacityBackgroundCase] = []
        for policy in Schema5RunCapacityBackgroundPolicy.allCases {
            for pause in Schema5RunCapacityBackgroundPause.allCases {
                rows.append(
                    try await schema5RunCapacityBackgroundCase(
                        root: root.appendingPathComponent(
                            "\(policy.rawValue)-\(pause.rawValue)",
                            isDirectory: true
                        ),
                        pause: pause,
                        policy: policy
                    )
                )
            }
        }
        let all = rows.allSatisfy { row in
            let expectedRuns = row.policy == .fullBase ? 1 : 4
            let expectedUnreferencedBases: Int
            switch (row.policy, row.pause) {
            case (.fullBase, .beforePreparation): expectedUnreferencedBases = 1
            case (.fullBase, .candidateVerified): expectedUnreferencedBases = 2
            case (.collapseFirst, .beforePreparation): expectedUnreferencedBases = 0
            case (.collapseFirst, .candidateVerified): expectedUnreferencedBases = 1
            }
            return row.startingRunCount == 63
                && row.runCountAfterFirstCheckpoint == 64
                && row.activeDistinctBeforeHardBoundary == 511
                && row.finalBoundaryCommitSucceededWithoutRetry
                && row.finalRunCountBeforeBackgroundResume == expectedRuns
                && row.finalActiveDistinctBeforeBackgroundResume == 0
                && row.finalEntryCountBeforeBackgroundResume == 1_024
                && row.materializedUnreferencedV3BaseCountBeforeResume
                    == expectedUnreferencedBases
                && !row.backgroundCompactionPublishedAfterResume
                && row.finalRunCountAfterBackgroundResume == expectedRuns
                && row.finalActiveDistinctAfterBackgroundResume == 0
                && row.finalSegmentSetExactlyReferenced
                && row.finalEntryCount == 1_024
                && row.finalAuthorityExact
                && row.reopenExact
                && row.finalTargetReadable
        }
        let report = Schema5RunCapacityBackgroundReport(
            schemaVersion: 2,
            cases: rows,
            allChecksPass: all,
            claims: .init(
                hardProgressIndependentOfBackgroundCompletion: true,
                automaticTriggerSelected: false,
                formalLatency: false,
                physicalDeviceIO: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5RunCapacityBackgroundCase(
        root: URL,
        pause: Schema5RunCapacityBackgroundPause,
        policy: Schema5RunCapacityBackgroundPolicy
    ) async throws -> Schema5RunCapacityBackgroundCase {
        var store: FileBlobStore? = try await schema5RunCapacitySeed(
            root: root,
            policy: policy.storePolicy,
            runCount: 63
        )
        let gate = Schema5RunCapacityBackgroundGate()
        let background = Task { [weak store, gate] in
            guard let store else { throw AkashicError.storageUnavailable }
            return try await store.resourceProbeCompactSegmentedManifestV3(
                observer: { _ in
                    if pause == .candidateVerified { await gate.reachAndPause() }
                },
                preparationObserver: {
                    if pause == .beforePreparation { await gate.reachAndPause() }
                }
            )
        }
        await gate.waitUntilReached()

        let startingRoot = try schema5RunCapacityReadRoot(root)
        let identities = try schema5MigrationIdentities(
            labels: (0..<1_024).map { "run-cap-background-\(pause.rawValue)-\($0)" }
        )
        for identity in identities.prefix(512) {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let afterFirstRoot = try schema5RunCapacityReadRoot(root)
        for identity in identities[512..<1_023] {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let headBeforeBoundary = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let target = identities[1_023]
        _ = try await store!.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        let beforeResumeRoot = try schema5RunCapacityReadRoot(root)
        let beforeResumeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let beforeResumeNames = try schema5RunCapacitySegmentNames(root)
        let referencedBeforeResume = Set(
            [beforeResumeRoot.base.fileName] + beforeResumeRoot.runs.map(\.fileName)
        )
        // While the detached reader is paused, the old frozen base itself is intentionally
        // unreferenced by the new authoritative root but retained by the physical read lease.
        // A candidate-verified pause adds the detached candidate as a second unreferenced V3 base.
        let materializedUnreferencedV3BaseCount = beforeResumeNames.filter {
            !referencedBeforeResume.contains($0) && $0.hasPrefix("base-binary-v2-")
        }.count

        await gate.release()
        let backgroundPublished = try await background.value
        let finalRoot = try schema5RunCapacityReadRoot(root)
        let finalHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalNames = try schema5RunCapacitySegmentNames(root)
        let finalReferenced = Set([finalRoot.base.fileName] + finalRoot.runs.map(\.fileName))
        let expectedKeys = Set(identities.map(\.key))
        let finalAuthorityExact = finalSnapshot.entries.count == identities.count
            && Set(finalSnapshot.entries.keys) == expectedKeys
            && identities.allSatisfy { identity in
                guard let entry = finalSnapshot.entries[identity.key] else { return false }
                return entry.partition == identity.partition
                    && entry.digest == identity.digest
                    && entry.byteCount == identity.data.count
            }

        let finalCommitment = try schema5IdentityCommitment(finalSnapshot.entries)
        let targetRead = try await store!.read(digest: target.digest, partition: target.partition)
        store = nil
        let reopened = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            runCapacityPolicy: policy.storePolicy
        )
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5RunCapacityReadRoot(root)
        let reopenedHead = try await reopened.resourceProbeDirectoryHeadEpochSnapshot()
        let reopenedCommitment = try schema5IdentityCommitment(reopenedSnapshot.entries)
        let reopenExact = reopenedSnapshot.entries == finalSnapshot.entries
            && reopenedCommitment == finalCommitment
            && reopenedRoot == finalRoot
            && reopenedHead.distinctKeyCount == finalHead.distinctKeyCount

        return .init(
            pause: pause,
            policy: policy,
            startingRunCount: startingRoot.runs.count,
            runCountAfterFirstCheckpoint: afterFirstRoot.runs.count,
            activeDistinctBeforeHardBoundary: headBeforeBoundary.distinctKeyCount,
            finalBoundaryCommitSucceededWithoutRetry: true,
            finalRunCountBeforeBackgroundResume: beforeResumeRoot.runs.count,
            finalActiveDistinctBeforeBackgroundResume: beforeResumeHead.distinctKeyCount,
            finalEntryCountBeforeBackgroundResume: beforeResumeSnapshot.entries.count,
            materializedUnreferencedV3BaseCountBeforeResume: materializedUnreferencedV3BaseCount,
            backgroundCompactionPublishedAfterResume: backgroundPublished,
            finalRunCountAfterBackgroundResume: finalRoot.runs.count,
            finalActiveDistinctAfterBackgroundResume: finalHead.distinctKeyCount,
            finalSegmentSetExactlyReferenced: Set(finalNames) == finalReferenced
                && finalNames.count == finalReferenced.count,
            finalEntryCount: finalSnapshot.entries.count,
            finalAuthorityExact: finalAuthorityExact,
            reopenExact: reopenExact,
            finalTargetReadable: targetRead == target.data
        )
    }
}
