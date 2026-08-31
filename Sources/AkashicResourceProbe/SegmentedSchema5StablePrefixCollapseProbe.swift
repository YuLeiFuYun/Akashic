import AkashicCore
import AkashicDisk
import Foundation

struct Schema5StablePrefixIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    let key: String
}

private struct Schema5StablePrefixCollapseReport: Codable {
    struct Claims: Codable {
        let immutablePrefixPreparation: Bool
        let foregroundSuffixCompatibility: Bool
        let hardCapLiveness: Bool
        let formalPerformance: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
        let productionSchedulingRecommendation: Bool
    }

    let schemaVersion: Int
    let seededRunCount: Int
    let preparedPrefixRunCount: Int
    let preparedReplacementRunCount: Int
    let preparedInputRunBytes: Int
    let preparedOutputRunBytes: Int
    let appendedSuffixRunCount: Int
    let runCountAtHardCap: Int
    let expectedRunCountAfterPreparedAdoptionAndBoundary: Int
    let actualRunCountAfterBoundary: Int
    let generationBeforeSuffix: UInt64
    let generationAtHardCap: UInt64
    let generationAfterBoundary: UInt64
    let authorityExactAtHardCap: Bool
    let finalAuthorityEmpty: Bool
    let finalReopenEmpty: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let finalBlobSetExactlyAuthoritative: Bool
    let checks: [String: Bool]
    let claims: Claims
}

private enum Schema5StablePrefixCollapseError: Error {
    case invalidArguments
    case writerLeaseDidNotRelease
}

enum SegmentedSchema5StablePrefixCollapseProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw Schema5StablePrefixCollapseError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        let identities = try await prepareV4Root(root: root, runCount: 48)
        log("seeded-v4-48")
        var store: FileBlobStore? = try await openV4(root)
        let rootBefore = try readRoot(root)
        let prepared = try await store!.resourceProbePrepareSegmentedRunPrefixCollapseV4(
            prefixRunCount: 48
        )
        guard let prepared else { throw AkashicError.limitExceeded }
        log("prepared-prefix-48-to-\(prepared.replacementRunCount)")

        // Append sixteen real checkpoint runs while the prepared replacement remains
        // non-authoritative. These foreground mutations exercise the same cleanup/headroom paths
        // that could otherwise accidentally reclaim or invalidate the candidate.
        for epoch in 0..<16 {
            if epoch.isMultiple(of: 2) {
                try await removeEpoch(store: store!, identities: identities)
            } else {
                try await addEpoch(store: store!, identities: identities)
            }
            log("suffix-epoch-\(epoch + 1)-root-runs-\(try readRoot(root).runs.count)")
        }

        let atHardCap = try readRoot(root)
        let hardSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let expectedHardKeys = Set(identities.map(\.key))
        let authorityExactAtHardCap = Set(hardSnapshot.entries.keys) == expectedHardKeys
            && hardSnapshot.entries.count == identities.count

        // The seventeenth suffix epoch crosses the 64-run hard boundary. The V4 liveness chain
        // should adopt the prepared 48->2 prefix first, preserve the sixteen untouched suffix runs,
        // then publish this boundary epoch as one new run: 2 + 16 + 1 = 19.
        try await removeEpoch(store: store!, identities: identities)
        log("boundary-remove-complete")
        let afterBoundary = try readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalAuthorityEmpty = finalSnapshot.entries.isEmpty
        store = nil

        store = try await openV4(root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let finalReopenEmpty = reopened.entries.isEmpty
        let finalRoot = try readRoot(root)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let segmentNames = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referencedNames = Set([finalRoot.base.fileName] + finalRoot.runs.map(\.fileName))
        let finalSegmentSetExactlyReferenced = Set(segmentNames) == referencedNames
            && segmentNames.count == referencedNames.count

        let blobDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        let blobNames = try BoundedDirectoryReader.names(
            in: blobDirectory,
            maximumCount: 4_096
        ).filter { UUID(uuidString: $0) != nil }
        let authoritativeBlobNames = Set(
            reopened.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
        )
        let finalBlobSetExactlyAuthoritative = Set(blobNames) == authoritativeBlobNames
            && blobNames.count == authoritativeBlobNames.count

        let expectedFinalRuns = prepared.replacementRunCount + 16 + 1
        let checks: [String: Bool] = [
            "seeded-v4-48-runs": rootBefore.profile == SegmentedManifestPrototypeV1.profileV4
                && rootBefore.runs.count == 48,
            "prepared-prefix-strictly-collapses": prepared.sourcePrefixRunCount == 48
                && prepared.replacementRunCount == 2,
            "foreground-suffix-reaches-hard-cap": atHardCap.runs.count == 64,
            "foreground-suffix-advances-generation-exactly-once-per-checkpoint":
                atHardCap.generation == rootBefore.generation + 16,
            "hard-cap-authority-exact": authorityExactAtHardCap,
            "prepared-prefix-adopted-at-boundary": afterBoundary.runs.count == expectedFinalRuns,
            "boundary-advances-generation-once": afterBoundary.generation == atHardCap.generation + 1,
            "final-authority-empty": finalAuthorityEmpty,
            "fresh-reopen-empty": finalReopenEmpty,
            "segment-set-exact": finalSegmentSetExactlyReferenced,
            "blob-set-exact": finalBlobSetExactlyAuthoritative,
        ]
        let report = Schema5StablePrefixCollapseReport(
            schemaVersion: 1,
            seededRunCount: rootBefore.runs.count,
            preparedPrefixRunCount: prepared.sourcePrefixRunCount,
            preparedReplacementRunCount: prepared.replacementRunCount,
            preparedInputRunBytes: prepared.inputRunBytes,
            preparedOutputRunBytes: prepared.outputRunBytes,
            appendedSuffixRunCount: 16,
            runCountAtHardCap: atHardCap.runs.count,
            expectedRunCountAfterPreparedAdoptionAndBoundary: expectedFinalRuns,
            actualRunCountAfterBoundary: afterBoundary.runs.count,
            generationBeforeSuffix: rootBefore.generation,
            generationAtHardCap: atHardCap.generation,
            generationAfterBoundary: afterBoundary.generation,
            authorityExactAtHardCap: authorityExactAtHardCap,
            finalAuthorityEmpty: finalAuthorityEmpty,
            finalReopenEmpty: finalReopenEmpty,
            finalSegmentSetExactlyReferenced: finalSegmentSetExactlyReferenced,
            finalBlobSetExactlyAuthoritative: finalBlobSetExactlyAuthoritative,
            checks: checks,
            claims: .init(
                immutablePrefixPreparation: true,
                foregroundSuffixCompatibility: true,
                hardCapLiveness: true,
                formalPerformance: false,
                physicalDeviceIO: false,
                powerLoss: false,
                productionSchedulingRecommendation: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        store = nil
        guard checks.values.allSatisfy({ $0 }) else {
            throw AkashicError.storageUnavailable
        }
    }

    static func prepareV4Root(
        root: URL,
        runCount: Int
    ) async throws -> [Schema5StablePrefixIdentity] {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        var identities: [Schema5StablePrefixIdentity] = []
        identities.reserveCapacity(512)
        for index in 0..<512 {
            let partition = try CachePartitionID.derive(
                domain: "schema5-stable-prefix-collapse-v1",
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("payload-\(index)".utf8)
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
            throw AkashicError.storageUnavailable
        }
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        try await waitForRelease(root)

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
        try await waitForRelease(root)

        let v4 = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(runCount)
        for runIndex in 0..<runCount {
            let mutations = try snapshot.entries.keys.sorted().map { key -> SegmentedManifestMutation in
                guard let entry = snapshot.entries[key] else { throw AkashicError.invalidManifest }
                return .upsert(
                    SegmentedManifestEntry(
                        key: key,
                        physicalID: entry.physicalID,
                        partition: entry.partition,
                        digest: entry.digest,
                        byteCount: entry.byteCount,
                        lastAccess: Date(
                            timeIntervalSinceReferenceDate: 950_000_000 + Double(runIndex)
                        )
                    )
                )
            }
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

    private static func removeEpoch(
        store: FileBlobStore,
        identities: [Schema5StablePrefixIdentity]
    ) async throws {
        for (index, identity) in identities.enumerated() {
            try await store.remove(digest: identity.digest, partition: identity.partition)
            if (index + 1).isMultiple(of: 64) { log("remove-progress-\(index + 1)") }
        }
    }

    private static func addEpoch(
        store: FileBlobStore,
        identities: [Schema5StablePrefixIdentity]
    ) async throws {
        for (index, identity) in identities.enumerated() {
            _ = try await store.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
            if (index + 1).isMultiple(of: 64) { log("add-progress-\(index + 1)") }
        }
    }

    static func openV4(_ root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.openSegmentedV4Candidate(
                    root: root,
                    runCapacityPolicy: .synchronousV4RunCollapseThenCompactionAtHardLimit
                )
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5StablePrefixCollapseError.writerLeaseDidNotRelease
    }

    static func waitForRelease(_ root: URL) async throws {
        for _ in 0..<250 {
            do {
                let probe = try await FileBlobStore.openSegmentedV3Candidate(root: root)
                _ = probe
                return
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.invalidManifest {
                return
            }
        }
        throw Schema5StablePrefixCollapseError.writerLeaseDidNotRelease
    }

    static func readRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("stable-prefix: \(message)\n".utf8))
    }
}
