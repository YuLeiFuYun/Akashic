import AkashicCore
import AkashicDisk
import Foundation

private actor Schema5StablePrefixAutomaticGate {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func reachAndPause() async {
        reached = true
        let current = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in current { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
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

private struct Schema5StablePrefixAutomaticDelayedSuccess: Codable {
    let delayedSuffixCheckpointCount: Int
    let rootRunCountBeforeResume: Int
    let finalRunCountAfterAdoption: Int
    let recordedLastPreparedSuffixRunCount: Int?
    let recordedMaximumPreparedSuffixRunCount: Int
    let attemptCount: Int
    let preparedCount: Int
    let adoptedCount: Int
    let nilCount: Int
    let hardCapCancellationCount: Int
    let authorityUnchangedByAdoption: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let reopenExact: Bool
}

private struct Schema5StablePrefixAutomaticDeadlineMiss: Codable {
    let stage: String
    let foregroundCheckpointsBeforeHardBoundary: Int
    let runCountAtHardCap: Int
    let runCountAfterHardBoundary: Int
    let backgroundSourceReadLeaseCountBeforeResume: Int
    let backgroundReservedOutputNameCountBeforeResume: Int
    let backgroundMaterializedOutputNameCountBeforeResume: Int
    let backgroundPlanningTaskActiveBeforeResume: Bool
    let backgroundMaterializationTaskActiveBeforeResume: Bool
    let attemptCount: Int
    let preparedCount: Int
    let adoptedCount: Int
    let nilCount: Int
    let errorCount: Int
    let hardCapCancellationCount: Int
    let authorityUnchangedByBackgroundExit: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let reopenExact: Bool
    let sampleReadable: Bool
}

private struct Schema5StablePrefixAutomaticDeadlineReport: Codable {
    struct Claims: Codable {
        let checkpointDistanceLagObservable: Bool
        let planningDeadlineMissDoesNotBlockHardProgress: Bool
        let materializationDeadlineMissDoesNotBlockHardProgress: Bool
        let adaptiveThresholdSelected: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let triggerRunCount: Int
    let hardRunLimit: Int
    let triggerSlack: Int
    let delayedSuccess: Schema5StablePrefixAutomaticDelayedSuccess
    let planningMiss: Schema5StablePrefixAutomaticDeadlineMiss
    let materializationMiss: Schema5StablePrefixAutomaticDeadlineMiss
    let allChecksPass: Bool
    let claims: Claims
}

enum SegmentedSchema5StablePrefixAutomaticDeadlineProbe {
    private static let defaultTriggerRunCount = 48
    private static let defaultDelayedSuffixCheckpoints = 6

    static func run(arguments: [String]) async throws {
        let configuration = try parse(arguments)
        let root = configuration.root
        let triggerRunCount = configuration.triggerRunCount
        let delayedSuffixCheckpoints = configuration.delayedSuffixCheckpoints
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let delayed = try await delayedSuccessCase(
            root: root.appendingPathComponent("delayed-success", isDirectory: true),
            triggerRunCount: triggerRunCount,
            suffixCheckpoints: delayedSuffixCheckpoints
        )
        let planningMiss = try await deadlineMissCase(
            root: root.appendingPathComponent("planning-miss", isDirectory: true),
            stage: "planning",
            triggerRunCount: triggerRunCount
        )
        let materializationMiss = try await deadlineMissCase(
            root: root.appendingPathComponent("materialization-miss", isDirectory: true),
            stage: "materialization",
            triggerRunCount: triggerRunCount
        )

        let slack = SegmentedManifestPrototypeV1.maximumRunDescriptors - triggerRunCount
        let all = delayed.delayedSuffixCheckpointCount == delayedSuffixCheckpoints
            && delayed.rootRunCountBeforeResume == triggerRunCount + delayedSuffixCheckpoints
            && delayed.finalRunCountAfterAdoption == 2 + delayedSuffixCheckpoints
            && delayed.recordedLastPreparedSuffixRunCount == delayedSuffixCheckpoints
            && delayed.recordedMaximumPreparedSuffixRunCount == delayedSuffixCheckpoints
            && delayed.attemptCount == 1
            && delayed.preparedCount == 1
            && delayed.adoptedCount == 1
            && delayed.nilCount == 0
            && delayed.hardCapCancellationCount == 0
            && delayed.authorityUnchangedByAdoption
            && delayed.finalSegmentSetExactlyReferenced
            && delayed.reopenExact
            && [planningMiss, materializationMiss].allSatisfy { row in
                row.foregroundCheckpointsBeforeHardBoundary == slack
                    && row.runCountAtHardCap == 64
                    && row.runCountAfterHardBoundary == 3
                    && row.attemptCount == 1
                    && row.preparedCount == 0
                    && row.adoptedCount == 0
                    && row.nilCount == 1
                    && row.errorCount == 0
                    && row.hardCapCancellationCount == 1
                    && row.authorityUnchangedByBackgroundExit
                    && row.finalSegmentSetExactlyReferenced
                    && row.reopenExact
                    && row.sampleReadable
            }
            && planningMiss.backgroundSourceReadLeaseCountBeforeResume == triggerRunCount
            && planningMiss.backgroundReservedOutputNameCountBeforeResume == 0
            && planningMiss.backgroundMaterializedOutputNameCountBeforeResume == 0
            && planningMiss.backgroundPlanningTaskActiveBeforeResume
            && !planningMiss.backgroundMaterializationTaskActiveBeforeResume
            && materializationMiss.backgroundSourceReadLeaseCountBeforeResume == 0
            && materializationMiss.backgroundReservedOutputNameCountBeforeResume == 2
            && materializationMiss.backgroundMaterializedOutputNameCountBeforeResume == 0
            && !materializationMiss.backgroundPlanningTaskActiveBeforeResume
            && materializationMiss.backgroundMaterializationTaskActiveBeforeResume

        let report = Schema5StablePrefixAutomaticDeadlineReport(
            schemaVersion: 2,
            triggerRunCount: triggerRunCount,
            hardRunLimit: SegmentedManifestPrototypeV1.maximumRunDescriptors,
            triggerSlack: slack,
            delayedSuccess: delayed,
            planningMiss: planningMiss,
            materializationMiss: materializationMiss,
            allChecksPass: all,
            claims: .init(
                checkpointDistanceLagObservable: true,
                planningDeadlineMissDoesNotBlockHardProgress: true,
                materializationDeadlineMissDoesNotBlockHardProgress: true,
                adaptiveThresholdSelected: false,
                formalLatency: false,
                physicalDeviceIO: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw ProbeError.resourceSampleFailed }
    }

    private static func delayedSuccessCase(
        root: URL,
        triggerRunCount: Int,
        suffixCheckpoints: Int
    ) async throws -> Schema5StablePrefixAutomaticDelayedSuccess {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: triggerRunCount - 1
        )
        var store: FileBlobStore? = try await openAutomatic(
            root,
            triggerRunCount: triggerRunCount
        )
        let gate = Schema5StablePrefixAutomaticGate()
        await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers(
            preparation: { await gate.reachAndPause() }
        )
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_010_000_000
        )
        await gate.waitUntilReached()
        await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers()
        for epoch in 0..<suffixCheckpoints {
            try await republishEpoch(
                store: store!,
                identities: identities,
                epochBase: 1_011_000_000 + Double(epoch * identities.count)
            )
        }
        let beforeResumeRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        await gate.release()
        let automatic = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        store = nil
        let reopened = try await openAutomatic(root, triggerRunCount: triggerRunCount)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot

        return .init(
            delayedSuffixCheckpointCount: suffixCheckpoints,
            rootRunCountBeforeResume: beforeResumeRoot.runs.count,
            finalRunCountAfterAdoption: finalRoot.runs.count,
            recordedLastPreparedSuffixRunCount: automatic.lastPreparedSuffixRunCount,
            recordedMaximumPreparedSuffixRunCount: automatic.maximumPreparedSuffixRunCount,
            attemptCount: automatic.attemptCount,
            preparedCount: automatic.preparedCount,
            adoptedCount: automatic.adoptedCount,
            nilCount: automatic.nilCount,
            hardCapCancellationCount: automatic.hardCapCancellationCount,
            authorityUnchangedByAdoption: beforeResumeSnapshot == finalSnapshot,
            finalSegmentSetExactlyReferenced: segmentExact,
            reopenExact: reopenExact
        )
    }

    private static func deadlineMissCase(
        root: URL,
        stage: String,
        triggerRunCount: Int
    ) async throws -> Schema5StablePrefixAutomaticDeadlineMiss {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: triggerRunCount - 1
        )
        var store: FileBlobStore? = try await openAutomatic(
            root,
            triggerRunCount: triggerRunCount
        )
        let gate = Schema5StablePrefixAutomaticGate()
        if stage == "planning" {
            await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers(
                preparation: { await gate.reachAndPause() }
            )
        } else {
            await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers(
                materialization: { await gate.reachAndPause() }
            )
        }
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: stage == "planning" ? 1_020_000_000 : 1_030_000_000
        )
        await gate.waitUntilReached()
        await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers()

        let slack = SegmentedManifestPrototypeV1.maximumRunDescriptors - triggerRunCount
        for epoch in 0..<slack {
            try await republishEpoch(
                store: store!,
                identities: identities,
                epochBase: (stage == "planning" ? 1_021_000_000 : 1_031_000_000)
                    + Double(epoch * identities.count)
            )
        }
        let hardCapRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: stage == "planning" ? 1_022_000_000 : 1_032_000_000
        )
        let beforeResumeRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let background = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        await gate.release()
        let automatic = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil
        let reopened = try await openAutomatic(root, triggerRunCount: triggerRunCount)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot

        return .init(
            stage: stage,
            foregroundCheckpointsBeforeHardBoundary: slack,
            runCountAtHardCap: hardCapRoot.runs.count,
            runCountAfterHardBoundary: beforeResumeRoot.runs.count,
            backgroundSourceReadLeaseCountBeforeResume: background.sourceReadLeaseCount,
            backgroundReservedOutputNameCountBeforeResume:
                background.materializationReservedNameCount,
            backgroundMaterializedOutputNameCountBeforeResume:
                background.materializedReservedNameCount,
            backgroundPlanningTaskActiveBeforeResume: background.planningTaskActive,
            backgroundMaterializationTaskActiveBeforeResume: background.materializationTaskActive,
            attemptCount: automatic.attemptCount,
            preparedCount: automatic.preparedCount,
            adoptedCount: automatic.adoptedCount,
            nilCount: automatic.nilCount,
            errorCount: automatic.errorCount,
            hardCapCancellationCount: automatic.hardCapCancellationCount,
            authorityUnchangedByBackgroundExit: beforeResumeSnapshot == finalSnapshot,
            finalSegmentSetExactlyReferenced: segmentExact,
            reopenExact: reopenExact,
            sampleReadable: sampleReadable
        )
    }

    private static func waitForAutomaticIdle(
        store: FileBlobStore,
        minimumAttemptCount: Int
    ) async throws -> FileBlobStoreSegmentedStablePrefixAutomaticSnapshot {
        for _ in 0..<10_000 {
            let snapshot = await store.resourceProbeSegmentedStablePrefixAutomaticSnapshot()
            if snapshot.attemptCount >= minimumAttemptCount && !snapshot.inFlight {
                return snapshot
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ProbeError.resourceSampleFailed
    }

    private static func openAutomatic(
        _ root: URL,
        triggerRunCount: Int
    ) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.openSegmentedV4Candidate(
                    root: root,
                    runCapacityPolicy: .backgroundV4StablePrefixAtRunCount(
                        prefixRunCount: triggerRunCount
                    )
                )
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw ProbeError.resourceSampleFailed
    }

    private struct Configuration {
        let root: URL
        let triggerRunCount: Int
        let delayedSuffixCheckpoints: Int
    }

    private static func parse(_ arguments: [String]) throws -> Configuration {
        guard arguments.count >= 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        var triggerRunCount = defaultTriggerRunCount
        var delayedSuffixCheckpoints = defaultDelayedSuffixCheckpoints
        var index = 2
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw ProbeError.invalidArguments }
            switch arguments[index] {
            case "--trigger":
                guard let parsed = Int(arguments[index + 1]) else {
                    throw ProbeError.invalidArguments
                }
                triggerRunCount = parsed
            case "--delayed-suffix":
                guard let parsed = Int(arguments[index + 1]) else {
                    throw ProbeError.invalidArguments
                }
                delayedSuffixCheckpoints = parsed
            default:
                throw ProbeError.invalidArguments
            }
            index += 2
        }
        let hardLimit = SegmentedManifestPrototypeV1.maximumRunDescriptors
        guard (2...(hardLimit - 2)).contains(triggerRunCount),
            delayedSuffixCheckpoints >= 0,
            delayedSuffixCheckpoints <= hardLimit - triggerRunCount
        else { throw ProbeError.invalidArguments }
        return .init(
            root: URL(fileURLWithPath: arguments[1], isDirectory: true),
            triggerRunCount: triggerRunCount,
            delayedSuffixCheckpoints: delayedSuffixCheckpoints
        )
    }

    private static func republishEpoch(
        store: FileBlobStore,
        identities: [Schema5StablePrefixIdentity],
        epochBase: Double
    ) async throws {
        for (index, identity) in identities.enumerated() {
            try await store.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(timeIntervalSinceReferenceDate: epochBase + Double(index))
            )
        }
    }

    private static func sampleIdentity(
        _ identities: [Schema5StablePrefixIdentity]
    ) throws -> Schema5StablePrefixIdentity {
        guard let first = identities.first else { throw ProbeError.resourceSampleFailed }
        return first
    }

    private static func segmentSetExactlyReferenced(
        root: URL,
        manifestRoot: SegmentedManifestRootV1
    ) throws -> Bool {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referenced = Set([manifestRoot.base.fileName] + manifestRoot.runs.map(\.fileName))
        return Set(names) == referenced && names.count == referenced.count
    }
}
