import AkashicCore
import AkashicDisk
import Darwin
import Foundation

struct Schema5CompactionResourceLogicalEntry: Sendable {
    let index: Int
    let key: String
    let partition: CachePartitionID
    let digest: BlobDigest
    let byteCount: Int
}

struct Schema5CompactionResourceSeedResult: Sendable {
    let store: FileBlobStore
    let root: SegmentedManifestRootV1
    let logicalEntries: [Schema5CompactionResourceLogicalEntry]
    let frozenState: [String: SegmentedManifestEntry]
    let expectedCommitment: String
    let baseBytes: Int
    let runBytes: Int
    let replayRecords: Int
}

extension SegmentedManifestShadowProbe {
    static let schema5CompactionResourceSeedPayload = Data([0x5a])

    static func schema5CompactionResourceSeed(
        root: URL,
        profile: Schema5CompactionResourceProfile,
        liveCount: Int,
        runCount: Int,
        recordsPerRun: Int,
        history: String
    ) async throws -> Schema5CompactionResourceSeedResult {
        guard liveCount > 0,
            liveCount <= FileBlobStore.resourceProbeMaximumManifestEntryCount,
            runCount > 0,
            runCount <= SegmentedManifestPrototypeV1.maximumRunDescriptors,
            recordsPerRun > 0,
            recordsPerRun <= FileBlobStore.resourceProbeManifestCheckpointRecordLimit,
            recordsPerRun <= liveCount,
            ["wide", "hot", "tombstone-recreate"].contains(history),
            history != "tombstone-recreate" || runCount.isMultiple(of: 2)
        else { throw SegmentedManifestShadowError.invalidArguments }

        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(blobs)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let payload = schema5CompactionResourceSeedPayload
        let digest = BlobDigest.sha256(of: payload)
        var logicalEntries: [Schema5CompactionResourceLogicalEntry] = []
        logicalEntries.reserveCapacity(liveCount)
        var baseState: [String: SegmentedManifestEntry] = [:]
        baseState.reserveCapacity(liveCount)
        for index in 0..<liveCount {
            let partition = try schema5CompactionResourcePartition(index)
            let key = FileBlobStore.resourceProbeManifestKey(
                digest: digest,
                partition: partition
            )
            let logical = Schema5CompactionResourceLogicalEntry(
                index: index,
                key: key,
                partition: partition,
                digest: digest,
                byteCount: payload.count
            )
            logicalEntries.append(logical)
            baseState[key] = schema5CompactionResourceEntry(logical, version: 0)
        }
        logicalEntries.sort { $0.key < $1.key }

        let base: SegmentedManifestDescriptorV1
        switch profile {
        case .v1JSON:
            let baseSnapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
                generation: 1,
                entries: schema5DepthShadow(baseState)
            )
            base = try SegmentedManifestPrototypeV1.writeBaseJSON(
                baseSnapshot,
                entryCount: baseState.count,
                fileName: "base-migration-\(UUID().uuidString.lowercased()).json",
                directory: segments
            )
        case .v2Binary:
            base = try SegmentedManifestPrototypeV1.writeBaseBinary(
                baseState,
                fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
                directory: segments
            )
        case .v3CompactBinary:
            base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
                baseState,
                fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
                directory: segments
            )
        }

        var expected = baseState
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(runCount)
        var runBytes = 0
        var replayRecords = 0
        for runIndex in 0..<runCount {
            let mutations = try schema5CompactionResourceMutations(
                logicalEntries: logicalEntries,
                current: expected,
                runIndex: runIndex,
                recordsPerRun: recordsPerRun,
                history: history
            )
            expected = try SegmentedManifestPrototypeV1.apply(mutations, to: expected)
            let run = try SegmentedManifestPrototypeV1.writeRun(
                mutations,
                fileName: "run-g2-\(UUID().uuidString.lowercased()).seg",
                directory: segments
            )
            runs.append(run)
            runBytes += run.byteCount
            replayRecords += run.recordCount
        }
        guard expected.count == liveCount else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let manifestRoot: SegmentedManifestRootV1
        switch profile {
        case .v1JSON:
            manifestRoot = try SegmentedManifestPrototypeV1.makeRoot(
                generation: 2,
                base: base,
                runs: runs
            )
        case .v2Binary:
            manifestRoot = try SegmentedManifestPrototypeV1.makeRootV2(
                generation: 2,
                base: base,
                runs: runs
            )
        case .v3CompactBinary:
            manifestRoot = try SegmentedManifestPrototypeV1.makeRootV3(
                generation: 2,
                base: base,
                runs: runs
            )
        }
        try SegmentedManifestPrototypeV1.writeRoot(
            manifestRoot,
            to: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try schema5CompactionResourceMaterializeFinalBlobs(
            state: expected,
            payload: payload,
            directory: blobs
        )

        let limits = FileBlobStoreLimits(
            softTotalBytes: 256 * 1024 * 1024,
            maximumBlobBytes: 64 * 1024 * 1024,
            maximumDirectoryEntryCount: 201_024
        )
        let store: FileBlobStore
        switch profile {
        case .v1JSON:
            store = try await FileBlobStore.open(root: root, limits: limits)
        case .v2Binary:
            store = try await FileBlobStore.openSegmentedV2Candidate(root: root, limits: limits)
        case .v3CompactBinary:
            store = try await FileBlobStore.openSegmentedV3Candidate(root: root, limits: limits)
        }
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let expectedShadow = schema5DepthShadow(expected)
        let expectedCommitment = try schema5IdentityCommitment(expectedShadow)
        let actorCommitment = try schema5IdentityCommitment(snapshot.entries)
        guard snapshot.entries.count == liveCount,
            snapshot.entries == expectedShadow,
            actorCommitment == expectedCommitment,
            active.generation == manifestRoot.generation,
            active.activeSequence == 0,
            active.distinctKeyCount == 0
        else { throw SegmentedManifestShadowError.invariantViolation }

        return Schema5CompactionResourceSeedResult(
            store: store,
            root: manifestRoot,
            logicalEntries: logicalEntries,
            frozenState: expected,
            expectedCommitment: expectedCommitment,
            baseBytes: base.byteCount,
            runBytes: runBytes,
            replayRecords: replayRecords
        )
    }

    private static func schema5CompactionResourceMutations(
        logicalEntries: [Schema5CompactionResourceLogicalEntry],
        current: [String: SegmentedManifestEntry],
        runIndex: Int,
        recordsPerRun: Int,
        history: String
    ) throws -> [SegmentedManifestMutation] {
        let start: Int
        switch history {
        case "hot":
            start = 0
        case "tombstone-recreate":
            start = ((runIndex / 2) * recordsPerRun) % logicalEntries.count
        default:
            start = (runIndex * recordsPerRun) % logicalEntries.count
        }
        let selected = (0..<recordsPerRun).map { offset in
            logicalEntries[(start + offset) % logicalEntries.count]
        }
        let mutations: [SegmentedManifestMutation]
        if history == "tombstone-recreate", runIndex.isMultiple(of: 2) {
            mutations = selected.map { .tombstone(key: $0.key) }
        } else {
            mutations = try selected.map { logical in
                if history != "tombstone-recreate" {
                    guard current[logical.key] != nil else {
                        throw SegmentedManifestShadowError.invariantViolation
                    }
                }
                return .upsert(
                    schema5CompactionResourceEntry(logical, version: runIndex + 1)
                )
            }
        }
        return mutations.sorted { $0.key < $1.key }
    }

    static func schema5CompactionResourceEntry(
        _ logical: Schema5CompactionResourceLogicalEntry,
        version: Int
    ) -> SegmentedManifestEntry {
        SegmentedManifestEntry(
            key: logical.key,
            physicalID: schema5CompactionResourcePhysicalID(index: logical.index, version: version),
            partition: logical.partition,
            digest: logical.digest,
            byteCount: logical.byteCount,
            lastAccess: Date(timeIntervalSinceReferenceDate: Double(version))
        )
    }

    static func schema5CompactionResourcePartition(_ index: Int) throws -> CachePartitionID {
        guard index >= 0 else { throw SegmentedManifestShadowError.invalidArguments }
        var bytes = Data(repeating: 0, count: 32)
        var value = UInt64(index + 1).bigEndian
        withUnsafeBytes(of: &value) { source in
            bytes.replaceSubrange(24..<32, with: source)
        }
        return try CachePartitionID(bytes: bytes)
    }

    static func schema5CompactionResourcePhysicalID(index: Int, version: Int) -> PhysicalBlobID {
        let a = UInt32(truncatingIfNeeded: index + 1)
        let b = UInt16(truncatingIfNeeded: version)
        let c = UInt16(truncatingIfNeeded: (index >> 16) ^ version)
        let d = UInt16(0x8000) | UInt16(truncatingIfNeeded: version)
        let e = (UInt64(version) << 32 | UInt64(index + 1)) & 0x0000_ffff_ffff_ffff
        let text = String(format: "%08x-%04x-%04x-%04x-%012llx", a, b, c, d, e)
        return PhysicalBlobID(rawValue: UUID(uuidString: text)!)
    }

    private static func schema5CompactionResourceMaterializeFinalBlobs(
        state: [String: SegmentedManifestEntry],
        payload: Data,
        directory: URL
    ) throws {
        let oldMask = Darwin.umask(S_IRWXG | S_IRWXO)
        defer { _ = Darwin.umask(oldMask) }
        for entry in state.values {
            let url = directory.appendingPathComponent(
                entry.physicalID.rawValue.uuidString.lowercased(),
                isDirectory: false
            )
            try schema5CompactionResourceWriteBlob(payload, to: url)
        }
    }

    private static func schema5CompactionResourceWriteBlob(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
    }
}
