import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func schema5RunCollapsePrepareV3Base(
        root: URL,
        identities: [Schema5RunCollapseIdentity]
    ) async throws -> FileBlobStoreManifestShadowSnapshot {
        try? FileManager.default.removeItem(at: root)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        let expected = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        try schema5RunCollapseTransitionV1ToV3(root: root)
        store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let rootValue = try schema5RunCollapseReadRoot(root)
        // schema4 -> segmented V1 deliberately advances the manifest generation. The pre-migration
        // actor snapshot therefore cannot be compared as a whole to the reopened V3 snapshot.
        // Run-collapse qualification cares about exact logical/physical entry authority across the
        // format transition, while the reopened generation must agree with the published V3 root.
        guard reopened.entries == expected.entries,
            reopened.generation == rootValue.generation,
            rootValue.profile == SegmentedManifestPrototypeV1.profileV3,
            rootValue.base.kind == .baseBinaryV2,
            rootValue.runs.isEmpty
        else { throw SegmentedManifestShadowError.invariantViolation }
        store = nil
        return reopened
    }

    static func schema5RunCollapseTransitionV1ToV3(root: URL) throws {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let frozen = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let candidate = try SegmentedManifestBinaryBaseTransitionV3.prepare(
            frozenRoot: frozen,
            segmentDirectory: segmentDirectory,
            candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        )
        try SegmentedManifestPrototypeV1.writeRoot(candidate.root, to: manifestURL)
        let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: candidate.root,
            directory: segmentDirectory
        )
        guard cleanup.remainingDebtCount == 0 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
    }

    static func schema5RunCollapseInstallRuns(
        root: URL,
        runs: [[SegmentedManifestMutation]]
    ) throws -> SegmentedManifestRootV1 {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let baseRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard baseRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            baseRoot.runs.isEmpty
        else { throw SegmentedManifestShadowError.invariantViolation }
        try SegmentedManifestSegmentCleanupV1.ensureMaterializationCapacity(
            directory: segmentDirectory,
            additionalEntries: runs.count
        )
        var descriptors: [SegmentedManifestDescriptorV1] = []
        descriptors.reserveCapacity(runs.count)
        for mutations in runs {
            descriptors.append(
                try SegmentedManifestPrototypeV1.writeRun(
                    mutations,
                    fileName: "run-g\(baseRoot.generation)-\(UUID().uuidString.lowercased()).seg",
                    directory: segmentDirectory
                )
            )
        }
        let next = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: baseRoot.generation,
            base: baseRoot.base,
            runs: descriptors
        )
        try SegmentedManifestPrototypeV1.writeRoot(next, to: manifestURL)
        return next
    }

    static func schema5RunCollapseUpserts(
        keys: [String],
        snapshot: FileBlobStoreManifestShadowSnapshot
    ) throws -> [SegmentedManifestMutation] {
        try keys.sorted().map { key in
            guard let entry = snapshot.entries[key] else {
                throw SegmentedManifestShadowError.invariantViolation
            }
            return .upsert(
                SegmentedManifestEntry(
                    key: key,
                    physicalID: entry.physicalID,
                    partition: entry.partition,
                    digest: entry.digest,
                    byteCount: entry.byteCount,
                    lastAccess: entry.lastAccess
                )
            )
        }
    }

    static func schema5RunCollapseHotRuns(
        identities: [Schema5RunCollapseIdentity],
        baseline: FileBlobStoreManifestShadowSnapshot
    ) throws -> [[SegmentedManifestMutation]] {
        guard identities.count >= 512 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        // V3 rejects duplicate descriptor hashes, so byte-identical repeated runs are not a valid
        // source topology. Use a high-overlap history: 496 common keys plus one distinct satellite
        // per run. The union remains exactly 512 keys, preserving the intended 16 -> 2 geometry.
        let commonKeys = Array(identities.prefix(496)).map(\.key)
        var runs: [[SegmentedManifestMutation]] = []
        runs.reserveCapacity(16)
        for runIndex in 0..<16 {
            runs.append(
                try schema5RunCollapseUpserts(
                    keys: commonKeys + [identities[496 + runIndex].key],
                    snapshot: baseline
                )
            )
        }
        return runs
    }

    static func schema5RunCollapseReadRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    static func schema5RunCollapseSegmentNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        return try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).sorted()
    }

    static func schema5RunCollapseBlobNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("blobs", isDirectory: true)
        return try BoundedDirectoryReader.names(in: directory, maximumCount: 4_096).filter { name in
            guard let uuid = UUID(uuidString: name) else { return false }
            return uuid.uuidString.lowercased() == name
        }.sorted()
    }

    static func schema5RunCollapseCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    static func schema5RunCollapseResourceArguments(
        _ arguments: [String]
    ) throws -> (
        root: URL,
        method: String,
        liveEntries: Int,
        barrier: Schema5CompactionResourceBarrier
    ) {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let root = values["--root"],
            let method = values["--method"],
            method == "collapse" || method == "full",
            let liveEntries = values["--live"].flatMap(Int.init),
            liveEntries >= 512,
            liveEntries <= FileBlobStore.resourceProbeMaximumManifestEntryCount,
            let ready = values["--ready-fd"].flatMap(Int32.init),
            let go = values["--go-fd"].flatMap(Int32.init),
            let done = values["--done-fd"].flatMap(Int32.init),
            let release = values["--release-fd"].flatMap(Int32.init)
        else { throw SegmentedManifestShadowError.invalidArguments }
        return (
            root: URL(fileURLWithPath: root, isDirectory: true),
            method: method,
            liveEntries: liveEntries,
            barrier: Schema5CompactionResourceBarrier(
                readyFD: ready,
                goFD: go,
                doneFD: done,
                releaseFD: release
            )
        )
    }

    static func schema5RunCollapseWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func schema5RunCollapseIdentities(
        domain: String,
        count: Int
    ) throws -> [Schema5RunCollapseIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: domain,
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("payload-\(domain)-\(index)".utf8)
            return Schema5RunCollapseIdentity(
                partition: partition,
                digest: BlobDigest.sha256(of: data),
                data: data
            )
        }
    }
}
