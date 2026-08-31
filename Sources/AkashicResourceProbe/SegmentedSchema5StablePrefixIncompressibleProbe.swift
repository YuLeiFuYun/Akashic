import AkashicCore
import AkashicDisk
import Foundation

private actor Schema5StablePrefixIncompressibleGate {
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

private struct Schema5StablePrefixIncompressibleReport: Codable {
    struct Claims: Codable {
        let incompressiblePrefixRejectedWithoutAuthorityChange: Bool
        let hardProgressIndependentOfRejectedPreparation: Bool
        let physicalReadLeaseDebtRepaid: Bool
        let automaticSchedulingSelected: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let directIncompressiblePreparationReturnedCandidate: Bool
    let directIncompressibleRunCountAfterPreparation: Int
    let directIncompressibleSegmentSetExactlyReferenced: Bool
    let syntheticStartingRunCount: Int
    let syntheticPrefixRunCount: Int
    let distinctSyntheticKeysInPrefix: Int
    let runCountAfterCommitCheckpoint: Int
    let hardBoundaryRemoveSucceededWhilePreparationPaused: Bool
    let runCountBeforeBackgroundResume: Int
    let unreferencedReadLeasedRunCountBeforeResume: Int
    let backgroundPreparationReturnedCandidate: Bool
    let runCountAfterBackgroundResume: Int
    let finalAuthorityEmpty: Bool
    let finalReopenEmpty: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let finalBlobSetExactlyAuthoritative: Bool
    let allChecksPass: Bool
    let claims: Claims
}

enum SegmentedSchema5StablePrefixIncompressibleProbe {
    private static let startingRuns = 63
    private static let prefixRuns = 48
    private static let recordsPerRun = 512

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        let directRoot = root.appendingPathComponent("direct-nil", isDirectory: true)
        try await prepareIncompressibleV4(root: directRoot, runCount: prefixRuns)
        var directStore: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(
            directRoot
        )
        let directPrepared = try await directStore!.resourceProbePrepareSegmentedRunPrefixCollapseV4(
            prefixRunCount: prefixRuns
        )
        let directManifestRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(directRoot)
        let directSegmentExact = try segmentSetExactlyReferenced(
            root: directRoot,
            manifestRoot: directManifestRoot
        )
        directStore = nil

        let hardCapRoot = root.appendingPathComponent("hardcap", isDirectory: true)
        try await prepareIncompressibleV4(root: hardCapRoot, runCount: startingRuns)
        let identities = try makeForegroundIdentities(count: recordsPerRun)
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(
            hardCapRoot
        )
        let startingRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(hardCapRoot)
        let gate = Schema5StablePrefixIncompressibleGate()
        let background = Task { [store, gate] in
            guard let store else { throw AkashicError.storageUnavailable }
            return try await store.resourceProbePrepareSegmentedRunPrefixCollapseV4(
                prefixRunCount: prefixRuns,
                preparationObserver: { await gate.reachAndPause() }
            )
        }
        await gate.waitUntilReached()

        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let afterCommit = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(hardCapRoot)
        for identity in identities {
            try await store!.remove(digest: identity.digest, partition: identity.partition)
        }
        let beforeResumeRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(hardCapRoot)
        let beforeResumeSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let namesBeforeResume = try segmentNames(hardCapRoot)
        let referencedBeforeResume = Set(
            [beforeResumeRoot.base.fileName] + beforeResumeRoot.runs.map(\.fileName)
        )
        let unreferencedReadLeasedRuns = namesBeforeResume.filter {
            !referencedBeforeResume.contains($0) && $0.hasPrefix("run-")
        }.count

        await gate.release()
        let prepared = try await background.value
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(hardCapRoot)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalAuthorityEmpty = finalSnapshot.entries.isEmpty
        let segmentExact = try segmentSetExactlyReferenced(
            root: hardCapRoot,
            manifestRoot: finalRoot
        )
        let blobExact = try blobSetExactlyAuthoritative(root: hardCapRoot, snapshot: finalSnapshot)
        store = nil

        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(hardCapRoot)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(hardCapRoot)
        let finalReopenEmpty = reopenedSnapshot.entries.isEmpty
            && reopenedSnapshot == finalSnapshot
            && reopenedRoot == finalRoot

        let all = directPrepared == nil
            && directManifestRoot.runs.count == prefixRuns
            && directSegmentExact
            && startingRoot.runs.count == startingRuns
            && afterCommit.runs.count == 64
            && beforeResumeRoot.runs.count == 1
            && beforeResumeSnapshot.entries.isEmpty
            && unreferencedReadLeasedRuns == prefixRuns
            && prepared == nil
            && finalRoot.runs.count == 1
            && finalAuthorityEmpty
            && finalReopenEmpty
            && segmentExact
            && blobExact

        let report = Schema5StablePrefixIncompressibleReport(
            schemaVersion: 1,
            directIncompressiblePreparationReturnedCandidate: directPrepared != nil,
            directIncompressibleRunCountAfterPreparation: directManifestRoot.runs.count,
            directIncompressibleSegmentSetExactlyReferenced: directSegmentExact,
            syntheticStartingRunCount: startingRoot.runs.count,
            syntheticPrefixRunCount: prefixRuns,
            distinctSyntheticKeysInPrefix: prefixRuns * recordsPerRun,
            runCountAfterCommitCheckpoint: afterCommit.runs.count,
            hardBoundaryRemoveSucceededWhilePreparationPaused: true,
            runCountBeforeBackgroundResume: beforeResumeRoot.runs.count,
            unreferencedReadLeasedRunCountBeforeResume: unreferencedReadLeasedRuns,
            backgroundPreparationReturnedCandidate: prepared != nil,
            runCountAfterBackgroundResume: finalRoot.runs.count,
            finalAuthorityEmpty: finalAuthorityEmpty,
            finalReopenEmpty: finalReopenEmpty,
            finalSegmentSetExactlyReferenced: segmentExact,
            finalBlobSetExactlyAuthoritative: blobExact,
            allChecksPass: all,
            claims: .init(
                incompressiblePrefixRejectedWithoutAuthorityChange: true,
                hardProgressIndependentOfRejectedPreparation: true,
                physicalReadLeaseDebtRepaid: true,
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

    static func prepareIncompressibleV4(root: URL, runCount: Int) async throws {
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
        runs.reserveCapacity(runCount)
        for runIndex in 0..<runCount {
            let start = runIndex * recordsPerRun
            let keys = try (0..<recordsPerRun)
                .map { offset in try syntheticManifestKey(index: start + offset) }
                .sorted()
            let mutations = keys.map { SegmentedManifestMutation.tombstone(key: $0) }
            runs.append(
                try SegmentedManifestPrototypeV1.writeRun(
                    mutations,
                    fileName: "run-g\(v4.generation)-\(UUID().uuidString.lowercased()).seg",
                    directory: migration.segmentDirectory
                )
            )
        }
        let seeded = try SegmentedManifestPrototypeV1.makeRootV4(
            generation: v4.generation,
            base: v4.base,
            runs: runs
        )
        let recovered = try SegmentedManifestPrototypeV1.recover(
            root: seeded,
            segmentDirectory: migration.segmentDirectory
        )
        guard recovered.isEmpty else { throw ProbeError.resourceSampleFailed }
        try SegmentedManifestPrototypeV1.writeRoot(seeded, to: rootURL)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: seeded,
            directory: migration.segmentDirectory
        )
    }

    private static func syntheticManifestKey(index: Int) throws -> String {
        let partition = try CachePartitionID.derive(
            domain: "schema5-incompressible-prefix-v1",
            material: Data("partition-\(index)".utf8)
        )
        let data = Data("synthetic-key-\(index)".utf8)
        return FileBlobStore.resourceProbeManifestKey(
            digest: BlobDigest.sha256(of: data),
            partition: partition
        )
    }

    static func makeForegroundIdentities(count: Int) throws -> [Schema5StablePrefixIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-incompressible-foreground-v1",
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("foreground-payload-\(index)".utf8)
            let digest = BlobDigest.sha256(of: data)
            return .init(
                partition: partition,
                digest: digest,
                data: data,
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: digest,
                    partition: partition
                )
            )
        }
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

    private static func blobSetExactlyAuthoritative(
        root: URL,
        snapshot: FileBlobStoreManifestShadowSnapshot
    ) throws -> Bool {
        let directory = root.appendingPathComponent("blobs", isDirectory: true)
        let names = try BoundedDirectoryReader.names(in: directory, maximumCount: 4_096)
            .filter { UUID(uuidString: $0) != nil }
        let referenced = Set(
            snapshot.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
        )
        return Set(names) == referenced && names.count == referenced.count
    }
}
