import AkashicCore
import AkashicDisk
import Foundation

enum SegmentedSchema5StablePrefixConcurrencyProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let overlap = try await suffixOverlapCase(
            root: root.appendingPathComponent("suffix-overlap", isDirectory: true)
        )
        let hardCap = try await hardCapIndependenceCase(
            root: root.appendingPathComponent("hardcap-independence", isDirectory: true)
        )
        let materializationOverlap = try await materializationOverlapCase(
            root: root.appendingPathComponent("materialization-overlap", isDirectory: true)
        )
        let materializationHardCap = try await materializationHardCapCase(
            root: root.appendingPathComponent("materialization-hardcap", isDirectory: true)
        )
        let all = overlap.startingRunCount == 48
            && overlap.runCountWhilePreparationPaused == 49
            && overlap.backgroundPrepared
            && overlap.preparedPrefixRunCount == 48
            && overlap.preparedReplacementRunCount == 2
            && overlap.preparedObservedSuffixRunCount == 1
            && overlap.finalRunCountAfterAdoption == 3
            && overlap.authorityUnchangedByAdoption
            && overlap.segmentSetExactlyReferenced
            && overlap.reopenExact
            && overlap.sampleReadable
            && hardCap.startingRunCount == 63
            && hardCap.runCountAfterFirstForegroundCheckpoint == 64
            && hardCap.finalBoundaryCommitSucceededWhilePreparationPaused
            && hardCap.runCountBeforeBackgroundResume == 3
            && hardCap.activeDistinctBeforeBackgroundResume == 0
            && hardCap.unreferencedReadLeasedRunCountBeforeResume == 48
            && !hardCap.backgroundCandidatePublishedAfterResume
            && hardCap.runCountAfterBackgroundResume == 3
            && hardCap.authorityUnchangedByBackgroundResume
            && hardCap.finalSegmentSetExactlyReferenced
            && hardCap.reopenExact
            && hardCap.sampleReadable
            && materializationOverlap.startingRunCount == 48
            && materializationOverlap.sourceReadLeaseCountWhileMaterializationPaused == 0
            && materializationOverlap.reservedOutputNameCountWhilePaused == 2
            && materializationOverlap.materializedOutputNameCountWhilePaused == 0
            && materializationOverlap.materializationTaskActiveWhilePaused
            && materializationOverlap.runCountAfterForegroundCheckpointWhilePaused == 49
            && materializationOverlap.preparedObservedSuffixRunCount == 1
            && materializationOverlap.finalRunCountAfterAdoption == 3
            && materializationOverlap.authorityUnchangedByAdoption
            && materializationOverlap.finalSegmentSetExactlyReferenced
            && materializationOverlap.reopenExact
            && materializationOverlap.sampleReadable
            && materializationHardCap.startingRunCount == 63
            && materializationHardCap.reservedOutputNameCountWhilePaused == 2
            && materializationHardCap.materializedOutputNameCountWhilePaused == 0
            && materializationHardCap.runCountAfterFirstForegroundCheckpoint == 64
            && materializationHardCap.runCountAfterHardCapRescue == 3
            && materializationHardCap.sourceReadLeaseCountAfterHardCapBeforeResume == 0
            && materializationHardCap.reservedOutputNameCountAfterHardCapBeforeResume == 2
            && materializationHardCap.materializedOutputNameCountAfterHardCapBeforeResume == 0
            && materializationHardCap.materializationTaskActiveAfterHardCapBeforeResume
            && materializationHardCap.segmentSetExactlyReferencedBeforeBackgroundResume
            && !materializationHardCap.backgroundCandidatePublishedAfterResume
            && materializationHardCap.backgroundStateClearedAfterResume
            && materializationHardCap.authorityUnchangedByBackgroundResume
            && materializationHardCap.finalSegmentSetExactlyReferenced
            && materializationHardCap.reopenExact
            && materializationHardCap.sampleReadable

        let report = Schema5StablePrefixConcurrencyReport(
            schemaVersion: 1,
            suffixOverlap: overlap,
            hardCapIndependence: hardCap,
            materializationOverlap: materializationOverlap,
            materializationHardCapIndependence: materializationHardCap,
            allChecksPass: all,
            claims: .init(
                foregroundProgressDuringDetachedPreparation: true,
                hardProgressIndependentOfBackgroundCompletion: true,
                automaticSchedulingSelected: false,
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

    private static func suffixOverlapCase(root: URL) async throws -> Schema5StablePrefixOverlapCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: 48
        )
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let startingRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let gate = Schema5StablePrefixPreparationGate()
        let background = Task { [store, gate] in
            guard let store else { throw AkashicError.storageUnavailable }
            return try await store.resourceProbePrepareSegmentedRunPrefixCollapseV4(
                prefixRunCount: 48,
                preparationObserver: { await gate.reachAndPause() }
            )
        }
        await gate.waitUntilReached()

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 980_000_000
        )
        let pausedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let pausedSnapshot = await store!.resourceProbeManifestShadowSnapshot()

        await gate.release()
        let prepared = try await background.value
        guard let prepared else { throw ProbeError.resourceSampleFailed }
        let adopted = try await store!.resourceProbeAdoptSegmentedRunPrefixCollapseV4()
        guard let adopted else { throw ProbeError.resourceSampleFailed }
        let adoptedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let adoptedSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: adoptedRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == adoptedSnapshot && reopenedRoot == adoptedRoot

        return .init(
            startingRunCount: startingRoot.runs.count,
            runCountWhilePreparationPaused: pausedRoot.runs.count,
            backgroundPrepared: true,
            preparedPrefixRunCount: prepared.sourcePrefixRunCount,
            preparedReplacementRunCount: prepared.replacementRunCount,
            preparedObservedSuffixRunCount: prepared.suffixRunCount,
            finalRunCountAfterAdoption: adopted.finalRunCount,
            authorityUnchangedByAdoption: pausedSnapshot == adoptedSnapshot,
            segmentSetExactlyReferenced: segmentExact,
            reopenExact: reopenExact,
            sampleReadable: sampleReadable
        )
    }

    private static func hardCapIndependenceCase(
        root: URL
    ) async throws -> Schema5StablePrefixHardCapCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: 63
        )
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let startingRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let gate = Schema5StablePrefixPreparationGate()
        let background = Task { [store, gate] in
            guard let store else { throw AkashicError.storageUnavailable }
            return try await store.resourceProbePrepareSegmentedRunPrefixCollapseV4(
                prefixRunCount: 48,
                preparationObserver: { await gate.reachAndPause() }
            )
        }
        await gate.waitUntilReached()

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 981_000_000
        )
        let afterFirst = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 982_000_000
        )
        let beforeResumeRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let beforeResumeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let namesBeforeResume = try segmentNames(root)
        let referencedBeforeResume = Set(
            [beforeResumeRoot.base.fileName] + beforeResumeRoot.runs.map(\.fileName)
        )
        let unreferencedReadLeasedRuns = namesBeforeResume.filter {
            !referencedBeforeResume.contains($0) && $0.hasPrefix("run-")
        }.count

        await gate.release()
        let backgroundResult = try await background.value
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalSegmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot

        return .init(
            startingRunCount: startingRoot.runs.count,
            runCountAfterFirstForegroundCheckpoint: afterFirst.runs.count,
            finalBoundaryCommitSucceededWhilePreparationPaused: true,
            runCountBeforeBackgroundResume: beforeResumeRoot.runs.count,
            activeDistinctBeforeBackgroundResume: beforeResumeHead.distinctKeyCount,
            unreferencedReadLeasedRunCountBeforeResume: unreferencedReadLeasedRuns,
            backgroundCandidatePublishedAfterResume: backgroundResult != nil,
            runCountAfterBackgroundResume: finalRoot.runs.count,
            authorityUnchangedByBackgroundResume: beforeResumeSnapshot == finalSnapshot,
            finalSegmentSetExactlyReferenced: finalSegmentExact,
            reopenExact: reopenExact,
            sampleReadable: sampleReadable
        )
    }

    private static func materializationOverlapCase(
        root: URL
    ) async throws -> Schema5StablePrefixMaterializationOverlapCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: 48
        )
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let startingRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let gate = Schema5StablePrefixPreparationGate()
        let background = Task { [store, gate] in
            guard let store else { throw AkashicError.storageUnavailable }
            return try await store.resourceProbePrepareSegmentedRunPrefixCollapseV4(
                prefixRunCount: 48,
                materializationObserver: { await gate.reachAndPause() }
            )
        }
        await gate.waitUntilReached()

        let pausedBackground = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 983_000_000
        )
        let pausedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let pausedSnapshot = await store!.resourceProbeManifestShadowSnapshot()

        await gate.release()
        let prepared = try await background.value
        guard let prepared else { throw ProbeError.resourceSampleFailed }
        let adopted = try await store!.resourceProbeAdoptSegmentedRunPrefixCollapseV4()
        guard let adopted else { throw ProbeError.resourceSampleFailed }
        let adoptedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let adoptedSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalSegmentExact = try segmentSetExactlyReferenced(
            root: root,
            manifestRoot: adoptedRoot
        )
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == adoptedSnapshot && reopenedRoot == adoptedRoot

        return .init(
            startingRunCount: startingRoot.runs.count,
            sourceReadLeaseCountWhileMaterializationPaused: pausedBackground.sourceReadLeaseCount,
            reservedOutputNameCountWhilePaused: pausedBackground.materializationReservedNameCount,
            materializedOutputNameCountWhilePaused: pausedBackground.materializedReservedNameCount,
            materializationTaskActiveWhilePaused: pausedBackground.materializationTaskActive,
            runCountAfterForegroundCheckpointWhilePaused: pausedRoot.runs.count,
            preparedObservedSuffixRunCount: prepared.suffixRunCount,
            finalRunCountAfterAdoption: adopted.finalRunCount,
            authorityUnchangedByAdoption: pausedSnapshot == adoptedSnapshot,
            finalSegmentSetExactlyReferenced: finalSegmentExact,
            reopenExact: reopenExact,
            sampleReadable: sampleReadable
        )
    }

    private static func materializationHardCapCase(
        root: URL
    ) async throws -> Schema5StablePrefixMaterializationHardCapCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: 63
        )
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let startingRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let gate = Schema5StablePrefixPreparationGate()
        let background = Task { [store, gate] in
            guard let store else { throw AkashicError.storageUnavailable }
            return try await store.resourceProbePrepareSegmentedRunPrefixCollapseV4(
                prefixRunCount: 48,
                materializationObserver: { await gate.reachAndPause() }
            )
        }
        await gate.waitUntilReached()
        let pausedBackground = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 984_000_000
        )
        let afterFirst = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 985_000_000
        )
        let beforeResumeRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let beforeResumeBackground = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        let segmentExactBeforeResume = try segmentSetExactlyReferenced(
            root: root,
            manifestRoot: beforeResumeRoot
        )

        await gate.release()
        let backgroundResult = try await background.value
        let finalBackground = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalSegmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot
        let backgroundStateCleared = finalBackground.sourceReadLeaseCount == 0
            && finalBackground.materializationReservedNameCount == 0
            && finalBackground.materializedReservedNameCount == 0
            && !finalBackground.planningTaskActive
            && !finalBackground.materializationTaskActive

        return .init(
            startingRunCount: startingRoot.runs.count,
            reservedOutputNameCountWhilePaused: pausedBackground.materializationReservedNameCount,
            materializedOutputNameCountWhilePaused: pausedBackground.materializedReservedNameCount,
            runCountAfterFirstForegroundCheckpoint: afterFirst.runs.count,
            runCountAfterHardCapRescue: beforeResumeRoot.runs.count,
            sourceReadLeaseCountAfterHardCapBeforeResume: beforeResumeBackground.sourceReadLeaseCount,
            reservedOutputNameCountAfterHardCapBeforeResume:
                beforeResumeBackground.materializationReservedNameCount,
            materializedOutputNameCountAfterHardCapBeforeResume:
                beforeResumeBackground.materializedReservedNameCount,
            materializationTaskActiveAfterHardCapBeforeResume:
                beforeResumeBackground.materializationTaskActive,
            segmentSetExactlyReferencedBeforeBackgroundResume: segmentExactBeforeResume,
            backgroundCandidatePublishedAfterResume: backgroundResult != nil,
            backgroundStateClearedAfterResume: backgroundStateCleared,
            authorityUnchangedByBackgroundResume: beforeResumeSnapshot == finalSnapshot,
            finalSegmentSetExactlyReferenced: finalSegmentExact,
            reopenExact: reopenExact,
            sampleReadable: sampleReadable
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

    private static func segmentNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        return try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
    }

    private static func segmentSetExactlyReferenced(
        root: URL,
        manifestRoot: SegmentedManifestRootV1
    ) throws -> Bool {
        let names = try segmentNames(root)
        let referenced = Set([manifestRoot.base.fileName] + manifestRoot.runs.map(\.fileName))
        return Set(names) == referenced && names.count == referenced.count
    }
}
