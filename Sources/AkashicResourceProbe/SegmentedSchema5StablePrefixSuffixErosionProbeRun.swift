import AkashicCore
import AkashicDisk
import Foundation

enum SegmentedSchema5StablePrefixSuffixErosionProbe {
    private static let triggerRunCount = 48
    private static let seededRunCount = 47
    private static let tombstoneGroupCount = 23
    private static let recordsPerGroup = 512
    private static let suffixCheckpointsBeforeResume = 16

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let planning = try await runCase(
            root: root.appendingPathComponent("planning-lag", isDirectory: true),
            stage: .planning,
            epochOffset: 0
        )
        let materialization = try await runCase(
            root: root.appendingPathComponent("materialization-lag", isDirectory: true),
            stage: .materialization,
            epochOffset: 100_000_000
        )
        let common: (Schema5StablePrefixSuffixAdmissionCase) -> Bool = { row in
            row.seededRunCount == 47
                && row.triggerRunCount == 48
                && row.frozenPlanInputRunCount == 48
                && row.frozenPlanOutputRunCount == 24
                && row.frozenPlanInputRunBytes == 3_345_408
                && row.frozenPlanOutputRunBytes == 1_672_704
                && row.frozenStaticAdmissionAccepted
                && !row.suffixAwareAdmissionAtSixteenAccepted
                && row.suffixCheckpointsBeforeResume == 16
                && row.runCountBeforeResume == 64
                && row.runCountAfterAutomaticRejection == 64
                && row.automaticAttemptCount == 1
                && row.automaticPreparedCount == 0
                && row.automaticAdoptedCount == 0
                && row.automaticNilCount == 1
                && row.automaticErrorCount == 0
                && row.automaticHardCapCancellationCount == 0
                && row.automaticNextRetryRunCount == nil
                && row.authorityUnchangedByAutomaticRejection
                && row.backgroundStateClearedAfterRejection
                && row.segmentSetExactlyReferencedAfterRejection
                && row.hardBoundaryCommitSucceeded
                && row.runCountAfterHardBoundary == 25
                && row.physicalOwnershipExact
                && row.finalAuthorityCount == recordsPerGroup
                && row.finalSegmentSetExactlyReferenced
                && row.finalReopenExact
                && row.sampleReadable
        }
        let all = common(planning)
            && planning.sourceReadLeaseCountWhilePaused == 48
            && planning.reservedOutputNameCountWhilePaused == 0
            && planning.materializedOutputNameCountWhilePaused == 0
            && planning.planningTaskActiveWhilePaused
            && !planning.materializationTaskActiveWhilePaused
            && planning.automaticSuffixBeforeMaterializationCount == 1
            && planning.automaticSuffixAfterMaterializationCount == 0
            && common(materialization)
            && materialization.sourceReadLeaseCountWhilePaused == 0
            && materialization.reservedOutputNameCountWhilePaused == 24
            && materialization.materializedOutputNameCountWhilePaused == 0
            && !materialization.planningTaskActiveWhilePaused
            && materialization.materializationTaskActiveWhilePaused
            && materialization.automaticSuffixBeforeMaterializationCount == 0
            && materialization.automaticSuffixAfterMaterializationCount == 1

        let report = Schema5StablePrefixSuffixAdmissionReport(
            schemaVersion: 2,
            planningLag: planning,
            materializationLag: materialization,
            allChecksPass: all,
            claims: [
                "suffixAwareSpeculativeAdmission": true,
                "planningLagRejectedBeforeMaterialization": true,
                "materializationLagRejectedBeforeAuthorityPublication": true,
                "hardCapProgressIndependentOfSpeculativeAdmission": true,
                "formalPerformance": false,
                "physicalDeviceIO": false,
                "powerLoss": false,
                "publicDefault": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        root: URL,
        stage: Schema5StablePrefixSuffixAdmissionStage,
        epochOffset: Double
    ) async throws -> Schema5StablePrefixSuffixAdmissionCase {
        let identities = try await prepareRoot(root: root)
        var store: FileBlobStore? = try await openAutomatic(root)
        let initialSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let initialRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        guard initialRoot.runs.count == seededRunCount,
            initialSnapshot.entries.count == recordsPerGroup
        else { throw ProbeError.resourceSampleFailed }

        let gate = Schema5StablePrefixSuffixAdmissionGate()
        switch stage {
        case .planning:
            await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers(
                preparation: { await gate.reachAndPause() }
            )
        case .materialization:
            await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers(
                materialization: { await gate.reachAndPause() }
            )
        }
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_200_000_000 + epochOffset
        )
        await gate.waitUntilReached()
        await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers()

        let pausedBackground = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        let triggerRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        guard let frozenPlan = try SegmentedManifestRunCollapseV1.plan(
            frozenRoot: triggerRoot,
            segmentDirectory: segmentDirectory
        ) else { throw ProbeError.resourceSampleFailed }
        let frozenStaticAdmission =
            FileBlobStoreSegmentedRunPrefixPreparationAdmission.speculativeAutomatic.accepts(
                inputRunCount: frozenPlan.inputRunCount,
                outputRunCount: frozenPlan.outputRunCount,
                inputRunBytes: frozenPlan.inputRunBytes,
                outputRunBytes: frozenPlan.outputRunBytes
            )
        let suffixAwareAtSixteen =
            FileBlobStoreSegmentedRunPrefixPreparationAdmission.speculativeAutomatic
                .acceptsObservedSuffix(
                    inputRunCount: frozenPlan.inputRunCount,
                    outputRunCount: frozenPlan.outputRunCount,
                    suffixRunCount: suffixCheckpointsBeforeResume,
                    inputRunBytes: frozenPlan.inputRunBytes,
                    outputRunBytes: frozenPlan.outputRunBytes
                )

        for epoch in 0..<suffixCheckpointsBeforeResume {
            try await republishEpoch(
                store: store!,
                identities: identities,
                epochBase: 1_201_000_000 + epochOffset + Double(epoch * recordsPerGroup)
            )
        }
        let beforeResumeRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        await gate.release()
        let automatic = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let rejectedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let rejectedSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let rejectedBackground = await store!.resourceProbeSegmentedRunPrefixBackgroundSnapshot()
        let segmentExactAfterRejection = try segmentSetExactlyReferenced(
            root: root,
            manifestRoot: rejectedRoot
        )
        let backgroundStateCleared = rejectedBackground.sourceReadLeaseCount == 0
            && rejectedBackground.materializationReservedNameCount == 0
            && rejectedBackground.materializedReservedNameCount == 0
            && !rejectedBackground.planningTaskActive
            && !rejectedBackground.materializationTaskActive

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_220_000_000 + epochOffset
        )
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalSegmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        let physicalExact = initialSnapshot.entries.allSatisfy { key, entry in
            finalSnapshot.entries[key]?.physicalID == entry.physicalID
        }
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        let reopened = try await openAutomatic(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot

        return .init(
            stage: stage,
            seededRunCount: initialRoot.runs.count,
            triggerRunCount: triggerRoot.runs.count,
            frozenPlanInputRunCount: frozenPlan.inputRunCount,
            frozenPlanOutputRunCount: frozenPlan.outputRunCount,
            frozenPlanInputRunBytes: frozenPlan.inputRunBytes,
            frozenPlanOutputRunBytes: frozenPlan.outputRunBytes,
            frozenStaticAdmissionAccepted: frozenStaticAdmission,
            suffixAwareAdmissionAtSixteenAccepted: suffixAwareAtSixteen,
            suffixCheckpointsBeforeResume: suffixCheckpointsBeforeResume,
            runCountBeforeResume: beforeResumeRoot.runs.count,
            sourceReadLeaseCountWhilePaused: pausedBackground.sourceReadLeaseCount,
            reservedOutputNameCountWhilePaused: pausedBackground.materializationReservedNameCount,
            materializedOutputNameCountWhilePaused: pausedBackground.materializedReservedNameCount,
            planningTaskActiveWhilePaused: pausedBackground.planningTaskActive,
            materializationTaskActiveWhilePaused: pausedBackground.materializationTaskActive,
            runCountAfterAutomaticRejection: rejectedRoot.runs.count,
            automaticAttemptCount: automatic.attemptCount,
            automaticPreparedCount: automatic.preparedCount,
            automaticAdoptedCount: automatic.adoptedCount,
            automaticNilCount: automatic.nilCount,
            automaticErrorCount: automatic.errorCount,
            automaticHardCapCancellationCount: automatic.hardCapCancellationCount,
            automaticSuffixBeforeMaterializationCount:
                automatic.suffixBeforeMaterializationCount,
            automaticSuffixAfterMaterializationCount:
                automatic.suffixAfterMaterializationCount,
            automaticNextRetryRunCount: automatic.nextRetryRunCount,
            authorityUnchangedByAutomaticRejection: beforeResumeSnapshot == rejectedSnapshot,
            backgroundStateClearedAfterRejection: backgroundStateCleared,
            segmentSetExactlyReferencedAfterRejection: segmentExactAfterRejection,
            hardBoundaryCommitSucceeded: true,
            runCountAfterHardBoundary: finalRoot.runs.count,
            physicalOwnershipExact: physicalExact,
            finalAuthorityCount: finalSnapshot.entries.count,
            finalSegmentSetExactlyReferenced: finalSegmentExact,
            finalReopenExact: reopenExact,
            sampleReadable: sampleReadable
        )
    }

    private static func prepareRoot(
        root: URL
    ) async throws -> [Schema5StablePrefixSuffixAdmissionIdentity] {
        try? FileManager.default.removeItem(at: root)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        var identities: [Schema5StablePrefixSuffixAdmissionIdentity] = []
        identities.reserveCapacity(recordsPerGroup)
        for index in 0..<recordsPerGroup {
            let partition = try CachePartitionID.derive(
                domain: "schema5-stable-prefix-suffix-erosion-v1",
                material: Data("live-partition-\(index)".utf8)
            )
            let data = Data("live-payload-\(index)".utf8)
            let digest = BlobDigest.sha256(of: data)
            _ = try await store!.commit(data: data, digest: digest, partition: partition)
            identities.append(
                .init(
                    partition: partition,
                    digest: digest,
                    data: data,
                    key: FileBlobStore.resourceProbeManifestKey(
                        digest: digest,
                        partition: partition
                    )
                )
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw ProbeError.resourceSampleFailed
        }
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        let baseSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        try await SegmentedSchema5StablePrefixCollapseProbe.waitForRelease(root)

        let rootURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let v1 = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let v3 = try SegmentedManifestBinaryBaseTransitionV3.prepare(
            frozenRoot: v1,
            segmentDirectory: migration.segmentDirectory,
            candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        )
        try SegmentedManifestPrototypeV1.writeRoot(v3.root, to: rootURL)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: v3.root,
            directory: migration.segmentDirectory
        )
        store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        _ = try await store!.resourceProbeMigrateSegmentedV3ToCompoundV4()
        store = nil
        try await SegmentedSchema5StablePrefixCollapseProbe.waitForRelease(root)

        let v4 = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let groups = try makeTombstoneGroups(liveKeys: baseSnapshot.entries.keys.sorted())
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(seededRunCount)
        for group in groups {
            runs.append(
                try writeRun(
                    mutations: group.map { .tombstone(key: $0) },
                    generation: v4.generation,
                    directory: migration.segmentDirectory
                )
            )
        }
        for groupIndex in 1..<tombstoneGroupCount {
            let source = groups[groupIndex]
            var variant = Array(source.dropLast())
            variant.append(groups[(groupIndex + 1) % tombstoneGroupCount][0])
            variant.sort()
            runs.append(
                try writeRun(
                    mutations: variant.map { .tombstone(key: $0) },
                    generation: v4.generation,
                    directory: migration.segmentDirectory
                )
            )
        }
        var liveVariant = Array(groups[0].dropLast(2))
        liveVariant.append(groups[1][1])
        liveVariant.append(groups[2][1])
        liveVariant.sort()
        runs.append(
            try writeRun(
                mutations: liveVariant.map { .tombstone(key: $0) },
                generation: v4.generation,
                directory: migration.segmentDirectory
            )
        )
        let liveUpserts = try baseSnapshot.entries.keys.sorted().map { key -> SegmentedManifestMutation in
            guard let entry = baseSnapshot.entries[key] else { throw ProbeError.resourceSampleFailed }
            return .upsert(
                SegmentedManifestEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: 1_199_000_000)
                )
            )
        }
        runs.append(
            try writeRun(
                mutations: liveUpserts,
                generation: v4.generation,
                directory: migration.segmentDirectory
            )
        )
        guard runs.count == seededRunCount else { throw ProbeError.resourceSampleFailed }
        let seeded = try SegmentedManifestPrototypeV1.makeRootV4(
            generation: v4.generation,
            base: v4.base,
            runs: runs
        )
        _ = try SegmentedManifestPrototypeV1.recover(
            root: seeded,
            segmentDirectory: migration.segmentDirectory
        )
        try SegmentedManifestPrototypeV1.writeRoot(seeded, to: rootURL)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: seeded,
            directory: migration.segmentDirectory
        )
        return identities
    }

    private static func makeTombstoneGroups(liveKeys: [String]) throws -> [[String]] {
        guard liveKeys.count == recordsPerGroup else { throw ProbeError.resourceSampleFailed }
        var groups: [[String]] = [liveKeys]
        groups.reserveCapacity(tombstoneGroupCount)
        for groupIndex in 1..<tombstoneGroupCount {
            var keys: [String] = []
            keys.reserveCapacity(recordsPerGroup)
            for index in 0..<recordsPerGroup {
                let partition = try CachePartitionID.derive(
                    domain: "schema5-stable-prefix-suffix-erosion-absent-v1",
                    material: Data("partition-\(groupIndex)-\(index)".utf8)
                )
                let data = Data("absent-payload-\(groupIndex)-\(index)".utf8)
                let digest = BlobDigest.sha256(of: data)
                keys.append(
                    FileBlobStore.resourceProbeManifestKey(
                        digest: digest,
                        partition: partition
                    )
                )
            }
            keys.sort()
            groups.append(keys)
        }
        let unique = Set(groups.flatMap { $0 })
        guard groups.count == tombstoneGroupCount,
            unique.count == tombstoneGroupCount * recordsPerGroup
        else { throw ProbeError.resourceSampleFailed }
        return groups
    }

    private static func writeRun(
        mutations: [SegmentedManifestMutation],
        generation: UInt64,
        directory: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        try SegmentedManifestPrototypeV1.writeRun(
            mutations,
            fileName: "run-g\(generation)-\(UUID().uuidString.lowercased()).seg",
            directory: directory
        )
    }

    private static func republishEpoch(
        store: FileBlobStore,
        identities: [Schema5StablePrefixSuffixAdmissionIdentity],
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

    private static func sampleIdentity(
        _ identities: [Schema5StablePrefixSuffixAdmissionIdentity]
    ) throws -> Schema5StablePrefixSuffixAdmissionIdentity {
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
