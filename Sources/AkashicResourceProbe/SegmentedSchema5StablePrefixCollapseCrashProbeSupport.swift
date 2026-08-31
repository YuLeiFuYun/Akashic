import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedSchema5StablePrefixCollapseCrashProbe {
    static func prepareV4Root(
        root: URL,
        runCount: Int
    ) async throws -> [Schema5StablePrefixCrashIdentity] {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        var identities: [Schema5StablePrefixCrashIdentity] = []
        identities.reserveCapacity(512)
        for index in 0..<512 {
            let partition = try CachePartitionID.derive(
                domain: "schema5-stable-prefix-crash-v1",
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
                            timeIntervalSinceReferenceDate: 960_000_000 + Double(runIndex)
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

    static func republishEpoch(
        store: FileBlobStore,
        identities: [Schema5StablePrefixCrashIdentity],
        epoch: Int
    ) async throws {
        for (index, identity) in identities.enumerated() {
            try await store.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(
                    timeIntervalSinceReferenceDate:
                        970_000_000 + Double(epoch * identities.count + index)
                )
            )
        }
    }

    static func openV4(
        _ root: URL,
        faultInjector: @escaping FileBlobStoreFaultInjector
    ) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.openSegmentedV4Candidate(
                    root: root,
                    faultInjector: faultInjector
                )
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5StablePrefixCrashError.writerLeaseDidNotRelease
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
        throw Schema5StablePrefixCrashError.writerLeaseDidNotRelease
    }

    static func identityCommitment(
        _ entries: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> String {
        let canonical = Dictionary(uniqueKeysWithValues: entries.map { key, entry in
            (
                key,
                SegmentedManifestEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: entry.lastAccess
                )
            )
        })
        return try SegmentedManifestPrototypeV1.semanticStateCommitment(canonical)
    }

    static func makeSampleIdentity(
        seed: Schema5StablePrefixCrashSeedReport,
        snapshot: FileBlobStoreManifestShadowSnapshot
    ) throws -> (partition: CachePartitionID, digest: BlobDigest, data: Data) {
        guard let entry = snapshot.entries[seed.sampleKey] else {
            throw AkashicError.invalidManifest
        }
        for index in 0..<512 {
            let data = Data("payload-\(index)".utf8)
            if BlobDigest.sha256(of: data).bytes == entry.digest.bytes {
                return (entry.partition, entry.digest, data)
            }
        }
        throw AkashicError.invalidManifest
    }

    static func makeMaterializationSampleIdentity(
        seed: Schema5StablePrefixMaterializationCrashSeedReport,
        snapshot: FileBlobStoreManifestShadowSnapshot
    ) throws -> (partition: CachePartitionID, digest: BlobDigest, data: Data) {
        guard let entry = snapshot.entries[seed.sampleKey] else {
            throw AkashicError.invalidManifest
        }
        for index in 0..<512 {
            let data = Data("payload-\(index)".utf8)
            if BlobDigest.sha256(of: data).bytes == entry.digest.bytes {
                return (entry.partition, entry.digest, data)
            }
        }
        throw AkashicError.invalidManifest
    }

    static func readRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    static func parseCrash(
        _ arguments: [String]
    ) throws -> (root: URL, point: Schema5StablePrefixCrashPoint, seedReport: URL) {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--point",
            arguments[4] == "--seed-report",
            arguments[1].hasPrefix("/"),
            arguments[5].hasPrefix("/"),
            let point = Schema5StablePrefixCrashPoint(rawValue: arguments[3])
        else { throw Schema5StablePrefixCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            point,
            URL(fileURLWithPath: arguments[5], isDirectory: false)
        )
    }

    static func parseMaterializationCrash(
        _ arguments: [String]
    ) throws -> (
        root: URL,
        point: Schema5StablePrefixMaterializationCrashPoint,
        seedReport: URL
    ) {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--point",
            arguments[4] == "--seed-report",
            arguments[1].hasPrefix("/"),
            arguments[5].hasPrefix("/"),
            let point = Schema5StablePrefixMaterializationCrashPoint(rawValue: arguments[3])
        else { throw Schema5StablePrefixCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            point,
            URL(fileURLWithPath: arguments[5], isDirectory: false)
        )
    }

    static func parseInspect(
        _ arguments: [String]
    ) throws -> (root: URL, seedReport: URL) {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--seed-report",
            arguments[1].hasPrefix("/"),
            arguments[3].hasPrefix("/")
        else { throw Schema5StablePrefixCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            URL(fileURLWithPath: arguments[3], isDirectory: false)
        )
    }

    static func parseMaterializationInspect(
        _ arguments: [String]
    ) throws -> (root: URL, seedReport: URL) {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--seed-report",
            arguments[1].hasPrefix("/"),
            arguments[3].hasPrefix("/")
        else { throw Schema5StablePrefixCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            URL(fileURLWithPath: arguments[3], isDirectory: false)
        )
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
