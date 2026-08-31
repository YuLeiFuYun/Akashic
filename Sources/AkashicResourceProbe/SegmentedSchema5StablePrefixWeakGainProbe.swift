import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5StablePrefixWeakGainReport: Codable {
    let schemaVersion: Int
    let triggerRunCount: Int
    let syntheticDistinctRunCount: Int
    let overlappingForegroundRunCount: Int
    let runCountAfterRejectedAttempt: Int
    let runCountAfterNextCheckpoint: Int
    let plannedRecoveredRunSlots: Int
    let plannedReplacementRunCount: Int
    let replacementRunsPerRecoveredSlot: Double
    let foregroundCheckpointCount: Int
    let automaticAttemptCount: Int
    let automaticPreparedCount: Int
    let automaticAdoptedCount: Int
    let automaticNilCount: Int
    let automaticErrorCount: Int
    let automaticMaterializationObserverCount: Int
    let authorityExactAcrossRejectedAttempt: Bool
    let authorityExactAfterNextCheckpoint: Bool
    let finalAuthorityCount: Int
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenExact: Bool
    let observations: [String: Bool]
    let claims: [String: Bool]
}

private actor Schema5StablePrefixWeakGainMaterializationCounter {
    private var count = 0

    func record() { count += 1 }
    func value() -> Int { count }
}

enum SegmentedSchema5StablePrefixWeakGainProbe {
    private static let triggerRunCount = 48
    private static let recordsPerRun = 512

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        let identities = try SegmentedSchema5StablePrefixIncompressibleProbe.makeForegroundIdentities(
            count: recordsPerRun
        )
        try await prepareWeakGainV4(root: root, foreground: identities)
        var store: FileBlobStore? = try await openAutomatic(root)
        let materializationCounter = Schema5StablePrefixWeakGainMaterializationCounter()
        await store!.resourceProbeSetSegmentedStablePrefixAutomaticObservers(
            materialization: {
                await materializationCounter.record()
            }
        )

        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let firstBefore = await store!.resourceProbeManifestShadowSnapshot()
        let firstAuto = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let firstRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let firstAfter = await store!.resourceProbeManifestShadowSnapshot()
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        guard let weakPlan = try SegmentedManifestRunCollapseV1.plan(
            frozenRoot: firstRoot,
            segmentDirectory: segmentDirectory
        ) else { throw ProbeError.resourceSampleFailed }

        for (index, identity) in identities.enumerated() {
            try await store!.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(
                    timeIntervalSinceReferenceDate: 1_100_000_000 + Double(index)
                )
            )
        }
        let secondBefore = await store!.resourceProbeManifestShadowSnapshot()
        let secondAuto = await store!.resourceProbeSegmentedStablePrefixAutomaticSnapshot()
        let secondRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let secondAfter = await store!.resourceProbeManifestShadowSnapshot()
        let materializationObserverCount = await materializationCounter.value()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: secondRoot)
        store = nil

        let reopened = try await openAutomatic(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == secondAfter && reopenedRoot == secondRoot

        let replacementRuns = weakPlan.outputRunCount
        let recoveredSlots = weakPlan.inputRunCount - replacementRuns
        let report = Schema5StablePrefixWeakGainReport(
            schemaVersion: 2,
            triggerRunCount: triggerRunCount,
            syntheticDistinctRunCount: triggerRunCount - 3,
            overlappingForegroundRunCount: 2,
            runCountAfterRejectedAttempt: firstRoot.runs.count,
            runCountAfterNextCheckpoint: secondRoot.runs.count,
            plannedRecoveredRunSlots: recoveredSlots,
            plannedReplacementRunCount: replacementRuns,
            replacementRunsPerRecoveredSlot: Double(replacementRuns) / Double(recoveredSlots),
            foregroundCheckpointCount: 2,
            automaticAttemptCount: secondAuto.attemptCount,
            automaticPreparedCount: secondAuto.preparedCount,
            automaticAdoptedCount: secondAuto.adoptedCount,
            automaticNilCount: secondAuto.nilCount,
            automaticErrorCount: secondAuto.errorCount,
            automaticMaterializationObserverCount: materializationObserverCount,
            authorityExactAcrossRejectedAttempt: firstBefore == firstAfter,
            authorityExactAfterNextCheckpoint: secondBefore == secondAfter,
            finalAuthorityCount: secondAfter.entries.count,
            finalSegmentSetExactlyReferenced: segmentExact,
            finalReopenExact: reopenExact,
            observations: [
                "weak-gain-preparation-recovers-only-one-run-slot": recoveredSlots == 1,
                "weak-gain-plan-would-publish-47-replacements-per-recovered-slot":
                    replacementRuns == 47 && recoveredSlots == 1,
                "automatic-benefit-floor-rejects-before-materialization":
                    firstAuto.attemptCount == 1
                        && firstAuto.preparedCount == 0
                        && firstAuto.adoptedCount == 0
                        && firstAuto.nilCount == 1
                        && firstAuto.frozenDescriptorFloorCount == 1
                        && firstAuto.nextRetryRunCount == nil
                        && firstRoot.runs.count == triggerRunCount
                        && materializationObserverCount == 0,
                "next-checkpoint-does-not-retry-exact-trigger":
                    secondAuto.attemptCount == 1
                        && secondAuto.preparedCount == 0
                        && secondAuto.adoptedCount == 0
                        && secondAuto.nilCount == 1
                        && secondAuto.frozenDescriptorFloorCount == 1
                        && secondAuto.nextRetryRunCount == nil
                        && secondRoot.runs.count == triggerRunCount + 1,
            ],
            claims: [
                "automaticSelfAmortizingDescriptorAdmission": true,
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
        guard report.observations.values.allSatisfy({ $0 }),
            report.authorityExactAcrossRejectedAttempt,
            report.authorityExactAfterNextCheckpoint,
            report.finalAuthorityCount == recordsPerRun,
            report.finalSegmentSetExactlyReferenced,
            report.finalReopenExact
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func prepareWeakGainV4(
        root: URL,
        foreground: [Schema5StablePrefixIdentity]
    ) async throws {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw ProbeError.resourceSampleFailed
        }
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
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
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(triggerRunCount - 1)
        for runIndex in 0..<(triggerRunCount - 3) {
            let start = runIndex * recordsPerRun
            let keys = try (0..<recordsPerRun)
                .map { offset in try syntheticManifestKey(index: start + offset) }
                .sorted()
            runs.append(
                try SegmentedManifestPrototypeV1.writeRun(
                    keys.map { .tombstone(key: $0) },
                    fileName: "run-g\(v4.generation)-\(UUID().uuidString.lowercased()).seg",
                    directory: migration.segmentDirectory
                )
            )
        }
        let foregroundKeys = foreground.map(\.key).sorted()
        runs.append(
            try SegmentedManifestPrototypeV1.writeRun(
                foregroundKeys.map { .tombstone(key: $0) },
                fileName: "run-g\(v4.generation)-\(UUID().uuidString.lowercased()).seg",
                directory: migration.segmentDirectory
            )
        )
        // A second descriptor repeats the same foreground tombstones. It increases prefix depth
        // without increasing the touched-key set, creating the exact weak-gain geometry: the
        // subsequent foreground upsert checkpoint reaches 48 source runs while replay-safe
        // collapse still needs 46 release runs + 1 upsert run = 47 replacements.
        runs.append(
            try SegmentedManifestPrototypeV1.writeRun(
                foregroundKeys.map { .tombstone(key: $0) },
                fileName: "run-g\(v4.generation)-\(UUID().uuidString.lowercased()).seg",
                directory: migration.segmentDirectory
            )
        )
        let seeded = try SegmentedManifestPrototypeV1.makeRootV4(
            generation: v4.generation,
            base: v4.base,
            runs: runs
        )
        guard try SegmentedManifestPrototypeV1.recover(
            root: seeded,
            segmentDirectory: migration.segmentDirectory
        ).isEmpty else { throw ProbeError.resourceSampleFailed }
        try SegmentedManifestPrototypeV1.writeRoot(seeded, to: rootURL)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: seeded,
            directory: migration.segmentDirectory
        )
    }

    private static func syntheticManifestKey(index: Int) throws -> String {
        let partition = try CachePartitionID.derive(
            domain: "schema5-weak-gain-v1",
            material: Data("partition-\(index)".utf8)
        )
        let data = Data("synthetic-key-\(index)".utf8)
        return FileBlobStore.resourceProbeManifestKey(
            digest: BlobDigest.sha256(of: data),
            partition: partition
        )
    }

    private static func waitForAutomaticIdle(
        store: FileBlobStore,
        minimumAttemptCount: Int
    ) async throws -> FileBlobStoreSegmentedStablePrefixAutomaticSnapshot {
        for _ in 0..<20_000 {
            let snapshot = await store.resourceProbeSegmentedStablePrefixAutomaticSnapshot()
            if snapshot.attemptCount >= minimumAttemptCount && !snapshot.inFlight {
                return snapshot
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ProbeError.resourceSampleFailed
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
