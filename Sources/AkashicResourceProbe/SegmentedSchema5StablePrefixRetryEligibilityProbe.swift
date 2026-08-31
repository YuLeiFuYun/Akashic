import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5StablePrefixRetryEligibilityIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    let key: String
}

private struct Schema5StablePrefixRetryEligibilityReport: Codable {
    let schemaVersion: Int
    let triggerRunCount: Int
    let seededRunCount: Int
    let frozen48InputRunCount: Int
    let frozen48OutputRunCount: Int
    let frozen48InputRunBytes: Int
    let frozen48OutputRunBytes: Int
    let frozen48BytesNonexpanding: Bool
    let frozen48SpeculativeAdmission: Bool
    let mathematicallyNextDescriptorEligibleRunCount: Int
    let automaticAttemptCountAt48: Int
    let automaticPreparedCountAt48: Int
    let automaticAdoptedCountAt48: Int
    let automaticNilCountAt48: Int
    let automaticDescriptorFloorCountAt48: Int
    let automaticNextRetryRunCountAt48: Int?
    let runCountAfterFirstExtraCheckpoint: Int
    let automaticAttemptCountAt49: Int
    let automaticNextRetryRunCountAt49: Int?
    let automaticAttemptCountAfterRetry: Int
    let automaticPreparedCountAfterRetry: Int
    let automaticAdoptedCountAfterRetry: Int
    let automaticNilCountAfterRetry: Int
    let automaticLastTriggerRunCountAfterRetry: Int?
    let automaticNextRetryRunCountAfterRetry: Int?
    let finalRunCountAfterAutomaticRetry: Int
    let authorityUnchangedByAutomaticRejection: Bool
    let authorityExactAfterAutomaticRetry: Bool
    let physicalOwnershipExact: Bool
    let finalAuthorityCount: Int
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenExact: Bool
    let sampleReadable: Bool
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum SegmentedSchema5StablePrefixRetryEligibilityProbe {
    private static let triggerRunCount = 48
    private static let seededRunCount = 47
    private static let tombstoneGroupCount = 24
    private static let recordsPerGroup = 512

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let identities = try await prepareRoot(root: root)
        var store: FileBlobStore? = try await openAutomatic(root)
        let initialSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let initialRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        guard initialRoot.runs.count == seededRunCount,
            initialSnapshot.entries.count == recordsPerGroup
        else { throw ProbeError.resourceSampleFailed }

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_300_000_000
        )
        let authorityAtTrigger = await store!.resourceProbeManifestShadowSnapshot()
        let automatic48 = try await waitForAutomaticIdle(store: store!, minimumAttemptCount: 1)
        let root48 = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let snapshot48 = await store!.resourceProbeManifestShadowSnapshot()
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        guard let plan48 = try SegmentedManifestRunCollapseV1.plan(
            frozenRoot: root48,
            segmentDirectory: segmentDirectory
        ) else { throw ProbeError.resourceSampleFailed }
        let admission48 =
            FileBlobStoreSegmentedRunPrefixPreparationAdmission.speculativeAutomatic.accepts(
                inputRunCount: plan48.inputRunCount,
                outputRunCount: plan48.outputRunCount,
                inputRunBytes: plan48.inputRunBytes,
                outputRunBytes: plan48.outputRunBytes
            )
        let nextEligible = plan48.outputRunCount.multipliedReportingOverflow(by: 2)
        guard !nextEligible.overflow else { throw ProbeError.resourceSampleFailed }

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_301_000_000
        )
        let root49 = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let automatic49 = await store!.resourceProbeSegmentedStablePrefixAutomaticSnapshot()
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_302_000_000
        )
        let automaticAfterRetry = try await waitForAutomaticIdle(
            store: store!,
            minimumAttemptCount: 2
        )
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
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

        let report = Schema5StablePrefixRetryEligibilityReport(
            schemaVersion: 2,
            triggerRunCount: triggerRunCount,
            seededRunCount: seededRunCount,
            frozen48InputRunCount: plan48.inputRunCount,
            frozen48OutputRunCount: plan48.outputRunCount,
            frozen48InputRunBytes: plan48.inputRunBytes,
            frozen48OutputRunBytes: plan48.outputRunBytes,
            frozen48BytesNonexpanding: plan48.outputRunBytes <= plan48.inputRunBytes,
            frozen48SpeculativeAdmission: admission48,
            mathematicallyNextDescriptorEligibleRunCount: nextEligible.partialValue,
            automaticAttemptCountAt48: automatic48.attemptCount,
            automaticPreparedCountAt48: automatic48.preparedCount,
            automaticAdoptedCountAt48: automatic48.adoptedCount,
            automaticNilCountAt48: automatic48.nilCount,
            automaticDescriptorFloorCountAt48: automatic48.frozenDescriptorFloorCount,
            automaticNextRetryRunCountAt48: automatic48.nextRetryRunCount,
            runCountAfterFirstExtraCheckpoint: root49.runs.count,
            automaticAttemptCountAt49: automatic49.attemptCount,
            automaticNextRetryRunCountAt49: automatic49.nextRetryRunCount,
            automaticAttemptCountAfterRetry: automaticAfterRetry.attemptCount,
            automaticPreparedCountAfterRetry: automaticAfterRetry.preparedCount,
            automaticAdoptedCountAfterRetry: automaticAfterRetry.adoptedCount,
            automaticNilCountAfterRetry: automaticAfterRetry.nilCount,
            automaticLastTriggerRunCountAfterRetry: automaticAfterRetry.lastTriggerRunCount,
            automaticNextRetryRunCountAfterRetry: automaticAfterRetry.nextRetryRunCount,
            finalRunCountAfterAutomaticRetry: finalRoot.runs.count,
            authorityUnchangedByAutomaticRejection: authorityAtTrigger == snapshot48,
            authorityExactAfterAutomaticRetry: finalSnapshot.entries.count == recordsPerGroup,
            physicalOwnershipExact: physicalExact,
            finalAuthorityCount: finalSnapshot.entries.count,
            finalSegmentSetExactlyReferenced: segmentExact,
            finalReopenExact: reopenExact,
            sampleReadable: sampleReadable,
            observations: [
                "descriptor-floor-alone-rejects-48-to-25":
                    plan48.inputRunCount == 48
                        && plan48.outputRunCount == 25
                        && plan48.outputRunBytes <= plan48.inputRunBytes
                        && !admission48,
                "descriptor-rejection-produces-exact-retry-hint-50":
                    nextEligible.partialValue == 50
                        && automatic48.frozenDescriptorFloorCount == 1
                        && automatic48.nextRetryRunCount == 50,
                "scheduler-does-not-retry-before-hint":
                    automatic48.attemptCount == 1
                        && automatic49.attemptCount == 1
                        && automatic49.nextRetryRunCount == 50,
                "scheduler-retries-at-50-and-adopts-beneficial-plan":
                    automaticAfterRetry.attemptCount == 2
                        && automaticAfterRetry.preparedCount == 1
                        && automaticAfterRetry.adoptedCount == 1
                        && automaticAfterRetry.nilCount == 1
                        && automaticAfterRetry.lastTriggerRunCount == 50
                        && automaticAfterRetry.nextRetryRunCount == nil
                        && finalRoot.runs.count == 25,
            ],
            claims: [
                "typedDescriptorRetryHint": true,
                "perCheckpointRetryRecommended": false,
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
            report.authorityExactAfterAutomaticRetry,
            report.physicalOwnershipExact,
            report.finalAuthorityCount == recordsPerGroup,
            report.finalSegmentSetExactlyReferenced,
            report.finalReopenExact,
            report.sampleReadable,
            automatic48.preparedCount == 0,
            automatic48.adoptedCount == 0,
            automatic48.nilCount == 1,
            automatic48.errorCount == 0
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func prepareRoot(
        root: URL
    ) async throws -> [Schema5StablePrefixRetryEligibilityIdentity] {
        try? FileManager.default.removeItem(at: root)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        var identities: [Schema5StablePrefixRetryEligibilityIdentity] = []
        identities.reserveCapacity(recordsPerGroup)
        for index in 0..<recordsPerGroup {
            let partition = try CachePartitionID.derive(
                domain: "schema5-stable-prefix-retry-eligibility-v1",
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
        for groupIndex in 1...22 {
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
        let liveUpserts = try baseSnapshot.entries.keys.sorted().map { key -> SegmentedManifestMutation in
            guard let entry = baseSnapshot.entries[key] else { throw ProbeError.resourceSampleFailed }
            return .upsert(
                SegmentedManifestEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: 1_299_000_000)
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
                    domain: "schema5-stable-prefix-retry-eligibility-absent-v1",
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
        identities: [Schema5StablePrefixRetryEligibilityIdentity],
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
        _ identities: [Schema5StablePrefixRetryEligibilityIdentity]
    ) throws -> Schema5StablePrefixRetryEligibilityIdentity {
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
