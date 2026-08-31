import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5StablePrefixAutomaticCycleCase: Codable {
    let triggerRunCount: Int
    let firstTriggerRootRunCountBeforeBackgroundCompletion: Int
    let firstCycleFinalRunCount: Int
    let secondCycleCheckpointCount: Int
    let secondCycleFinalRunCount: Int
    let attemptCount: Int
    let preparedCount: Int
    let adoptedCount: Int
    let nilCount: Int
    let errorCount: Int
    let hardCapCancellationCount: Int
    let authorityExactAcrossFirstAdoption: Bool
    let authorityExactAcrossSecondAdoption: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenExact: Bool
    let sampleReadable: Bool
}

private struct Schema5StablePrefixAutomaticIncompressibleCase: Codable {
    let triggerRunCount: Int
    let syntheticPrefixRunCount: Int
    let runCountAfterTriggeredAttempt: Int
    let runCountAfterNextCheckpoint: Int
    let attemptCountAfterTriggeredAttempt: Int
    let attemptCountAfterNextCheckpoint: Int
    let preparedCount: Int
    let adoptedCount: Int
    let nilCount: Int
    let errorCount: Int
    let hardCapCancellationCount: Int
    let plannerNoCandidateCount: Int
    let nextRetryRunCount: Int?
    let authorityExactAfterRejectedAttempt: Bool
    let finalAuthorityEmpty: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenExact: Bool
}

private struct Schema5StablePrefixAutomaticReport: Codable {
    struct Claims: Codable {
        let fixedTriggerAutomaticMechanism: Bool
        let repeatedCycleMechanism: Bool
        let incompressibleRetrySuppression: Bool
        let adaptiveThresholdSelected: Bool
        let publicDefaultSelected: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let validTriggerRange: String
    let invalidLowTriggerRejected: Bool
    let invalidHighTriggerRejected: Bool
    let repeatedCompressible: Schema5StablePrefixAutomaticCycleCase
    let incompressible: Schema5StablePrefixAutomaticIncompressibleCase
    let allChecksPass: Bool
    let claims: Claims
}

private enum Schema5StablePrefixAutomaticError: Error {
    case automaticAttemptDidNotFinish
}

enum SegmentedSchema5StablePrefixAutomaticProbe {
    private static let triggerRunCount = 48

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let invalidLow = await invalidTriggerRejected(
            root: root.appendingPathComponent("invalid-low", isDirectory: true),
            trigger: 1
        )
        let invalidHigh = await invalidTriggerRejected(
            root: root.appendingPathComponent("invalid-high", isDirectory: true),
            trigger: 63
        )
        let repeated = try await repeatedCompressibleCase(
            root: root.appendingPathComponent("repeated-compressible", isDirectory: true)
        )
        let incompressible = try await incompressibleCase(
            root: root.appendingPathComponent("incompressible", isDirectory: true)
        )

        let all = invalidLow
            && invalidHigh
            && repeated.triggerRunCount == triggerRunCount
            && repeated.firstTriggerRootRunCountBeforeBackgroundCompletion == triggerRunCount
            && repeated.firstCycleFinalRunCount == 2
            && repeated.secondCycleCheckpointCount == triggerRunCount - 2
            && repeated.secondCycleFinalRunCount == 2
            && repeated.attemptCount == 2
            && repeated.preparedCount == 2
            && repeated.adoptedCount == 2
            && repeated.nilCount == 0
            && repeated.errorCount == 0
            && repeated.hardCapCancellationCount == 0
            && repeated.authorityExactAcrossFirstAdoption
            && repeated.authorityExactAcrossSecondAdoption
            && repeated.finalSegmentSetExactlyReferenced
            && repeated.finalReopenExact
            && repeated.sampleReadable
            && incompressible.triggerRunCount == triggerRunCount
            && incompressible.syntheticPrefixRunCount == triggerRunCount - 1
            && incompressible.runCountAfterTriggeredAttempt == triggerRunCount
            && incompressible.runCountAfterNextCheckpoint == triggerRunCount + 1
            && incompressible.attemptCountAfterTriggeredAttempt == 1
            && incompressible.attemptCountAfterNextCheckpoint == 1
            && incompressible.preparedCount == 0
            && incompressible.adoptedCount == 0
            && incompressible.nilCount == 1
            && incompressible.errorCount == 0
            && incompressible.hardCapCancellationCount == 0
            && incompressible.plannerNoCandidateCount == 1
            && incompressible.nextRetryRunCount == nil
            && incompressible.authorityExactAfterRejectedAttempt
            && incompressible.finalAuthorityEmpty
            && incompressible.finalSegmentSetExactlyReferenced
            && incompressible.finalReopenExact

        let report = Schema5StablePrefixAutomaticReport(
            schemaVersion: 1,
            validTriggerRange: "2...62",
            invalidLowTriggerRejected: invalidLow,
            invalidHighTriggerRejected: invalidHigh,
            repeatedCompressible: repeated,
            incompressible: incompressible,
            allChecksPass: all,
            claims: .init(
                fixedTriggerAutomaticMechanism: true,
                repeatedCycleMechanism: true,
                incompressibleRetrySuppression: true,
                adaptiveThresholdSelected: false,
                publicDefaultSelected: false,
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

    private static func repeatedCompressibleCase(
        root: URL
    ) async throws -> Schema5StablePrefixAutomaticCycleCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: triggerRunCount - 1
        )
        var store: FileBlobStore? = try await openAutomatic(root)

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_000_000_000
        )
        let firstTriggeredRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let firstBefore = await store!.resourceProbeManifestShadowSnapshot()
        let firstAuto = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let firstFinalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let firstAfter = await store!.resourceProbeManifestShadowSnapshot()

        let secondCycleCheckpoints = triggerRunCount - firstFinalRoot.runs.count
        for epoch in 0..<secondCycleCheckpoints {
            try await republishEpoch(
                store: store!,
                identities: identities,
                epochBase: 1_001_000_000 + Double(epoch * identities.count)
            )
        }
        let secondBefore = await store!.resourceProbeManifestShadowSnapshot()
        let finalAuto = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 2)
        let secondFinalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let secondAfter = await store!.resourceProbeManifestShadowSnapshot()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: secondFinalRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        let reopened = try await openAutomatic(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == secondAfter && reopenedRoot == secondFinalRoot

        return .init(
            triggerRunCount: triggerRunCount,
            firstTriggerRootRunCountBeforeBackgroundCompletion: firstTriggeredRoot.runs.count,
            firstCycleFinalRunCount: firstFinalRoot.runs.count,
            secondCycleCheckpointCount: secondCycleCheckpoints,
            secondCycleFinalRunCount: secondFinalRoot.runs.count,
            attemptCount: finalAuto.attemptCount,
            preparedCount: finalAuto.preparedCount,
            adoptedCount: finalAuto.adoptedCount,
            nilCount: finalAuto.nilCount,
            errorCount: finalAuto.errorCount,
            hardCapCancellationCount: finalAuto.hardCapCancellationCount,
            authorityExactAcrossFirstAdoption: firstBefore == firstAfter
                && firstAuto.adoptedCount == 1,
            authorityExactAcrossSecondAdoption: secondBefore == secondAfter,
            finalSegmentSetExactlyReferenced: segmentExact,
            finalReopenExact: reopenExact,
            sampleReadable: sampleReadable
        )
    }

    private static func incompressibleCase(
        root: URL
    ) async throws -> Schema5StablePrefixAutomaticIncompressibleCase {
        try await SegmentedSchema5StablePrefixIncompressibleProbe.prepareIncompressibleV4(
            root: root,
            runCount: triggerRunCount - 1
        )
        let identities = try SegmentedSchema5StablePrefixIncompressibleProbe.makeForegroundIdentities(
            count: 512
        )
        var store: FileBlobStore? = try await openAutomatic(root)
        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let triggeredAuthority = await store!.resourceProbeManifestShadowSnapshot()
        let firstAuto = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let triggeredRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let afterRejectedAuthority = await store!.resourceProbeManifestShadowSnapshot()

        for identity in identities {
            try await store!.remove(digest: identity.digest, partition: identity.partition)
        }
        let nextRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalAuthority = await store!.resourceProbeManifestShadowSnapshot()
        let afterNext = await store!.resourceProbeSegmentedStablePrefixAutomaticSnapshot()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: nextRoot)
        store = nil

        let reopened = try await openAutomatic(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalAuthority && reopenedRoot == nextRoot

        return .init(
            triggerRunCount: triggerRunCount,
            syntheticPrefixRunCount: triggerRunCount - 1,
            runCountAfterTriggeredAttempt: triggeredRoot.runs.count,
            runCountAfterNextCheckpoint: nextRoot.runs.count,
            attemptCountAfterTriggeredAttempt: firstAuto.attemptCount,
            attemptCountAfterNextCheckpoint: afterNext.attemptCount,
            preparedCount: afterNext.preparedCount,
            adoptedCount: afterNext.adoptedCount,
            nilCount: afterNext.nilCount,
            errorCount: afterNext.errorCount,
            hardCapCancellationCount: afterNext.hardCapCancellationCount,
            plannerNoCandidateCount: afterNext.plannerNoCandidateCount,
            nextRetryRunCount: afterNext.nextRetryRunCount,
            authorityExactAfterRejectedAttempt: triggeredAuthority == afterRejectedAuthority,
            finalAuthorityEmpty: finalAuthority.entries.isEmpty,
            finalSegmentSetExactlyReferenced: segmentExact,
            finalReopenExact: reopenExact
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
        throw Schema5StablePrefixAutomaticError.automaticAttemptDidNotFinish
    }

    private static func openAutomatic(_ root: URL) async throws -> FileBlobStore {
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

    private static func invalidTriggerRejected(root: URL, trigger: Int) async -> Bool {
        do {
            _ = try await FileBlobStore.openSegmentedV4Candidate(
                root: root,
                runCapacityPolicy: .backgroundV4StablePrefixAtRunCount(prefixRunCount: trigger)
            )
            return false
        } catch AkashicError.limitExceeded {
            return true
        } catch {
            return false
        }
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
