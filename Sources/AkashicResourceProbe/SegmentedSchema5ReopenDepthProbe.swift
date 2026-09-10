import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5ReopenDepthSample: Codable {
    let depth: Int
    let repetition: Int
    let liveEntries: Int
    let replayedMutations: Int
    let baseBytes: Int
    let runBytes: Int
    let rootBytes: Int
    let referencedBytes: Int
    let segmentedRecoverNanoseconds: UInt64
    let fullSnapshotBytes: Int
    let fullSnapshotDecodeNanoseconds: UInt64
    let exactState: Bool
}

private enum Schema5ReopenProfile: String {
    case v1JSON = "v1-json"
    case v2Binary = "v2-binary"
    case v3CompactBinary = "v3-binary-compact"
    case v4Compound = "v4-compound"
}

private struct Schema5ReopenDepthReport: Codable {
    struct Claims: Codable {
        let formalPerformance: Bool
        let productionFormat: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let profile: String
    let liveEntries: Int
    let recordsPerRun: Int
    let depths: [Int]
    let repetitions: Int
    let samples: [Schema5ReopenDepthSample]
    let medians: [String: UInt64]
    let allExact: Bool
    let unaffectedOwnershipConflictRejected: Bool
    let sameRunOwnershipSwapAccepted: Bool
    let corruptRunRejectedBeforeIndexedApply: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5ReopenDepth(arguments: [String]) throws {
        let (root, profile) = try schema5ReopenArguments(arguments)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        let liveCount = 16_384
        let recordsPerRun = 512
        let depths = [0, 1, 4, 16, 64]
        let repetitions = 3
        let baseEntries = try makeBaseEntries(count: liveCount)
        let initialState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, schema5DepthEntry($0)) })
        let initialShadow = schema5DepthShadow(initialState)
        let baseSnapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: initialShadow
        )

        var samples: [Schema5ReopenDepthSample] = []
        for depth in depths {
            for repetition in 0..<repetitions {
                let caseRoot = root.appendingPathComponent(
                    "depth-\(depth)-rep-\(repetition)",
                    isDirectory: true
                )
                let segments = caseRoot.appendingPathComponent("segments", isDirectory: true)
                try StorageDirectorySecurity.prepareDirectory(caseRoot)
                try StorageDirectorySecurity.prepareDirectory(segments)
                let base = try schema5WriteDepthBase(
                    profile: profile,
                    initialState: initialState,
                    baseSnapshot: baseSnapshot,
                    liveCount: liveCount,
                    segments: segments
                )

                var expected = initialState
                var runDescriptors: [SegmentedManifestDescriptorV1] = []
                runDescriptors.reserveCapacity(depth)
                var runBytes = 0
                for runIndex in 0..<depth {
                    let mutations = try schema5DepthMutations(
                        runIndex: runIndex,
                        baseEntries: baseEntries,
                        expected: expected,
                        count: recordsPerRun
                    )
                    expected = try SegmentedManifestPrototypeV1.apply(mutations, to: expected)
                    let descriptor = try SegmentedManifestPrototypeV1.writeRun(
                        mutations,
                        fileName: String(format: "run-depth-%03d.seg", runIndex),
                        directory: segments
                    )
                    runDescriptors.append(descriptor)
                    runBytes += descriptor.byteCount
                }
                let manifestRoot = try schema5MakeDepthRoot(
                    profile: profile,
                    generation: UInt64(depth + 1),
                    base: base,
                    runs: runDescriptors
                )
                let rootURL = caseRoot.appendingPathComponent("manifest.json")
                try SegmentedManifestPrototypeV1.writeRoot(manifestRoot, to: rootURL)
                let rootBytes = try SegmentedManifestPrototypeV1.encodeRoot(manifestRoot).count
                let expectedCommitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(expected)

                let recoverStart = DispatchTime.now().uptimeNanoseconds
                let recovered = try SegmentedManifestPrototypeV1.recover(
                    rootURL: rootURL,
                    segmentDirectory: segments
                )
                let recoverElapsed = DispatchTime.now().uptimeNanoseconds &- recoverStart
                let exact = try SegmentedManifestPrototypeV1.semanticStateCommitment(recovered)
                    == expectedCommitment
                guard exact, recovered == expected, recovered.count == liveCount else {
                    throw SegmentedManifestShadowError.invariantViolation
                }

                let finalSnapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
                    generation: 1,
                    entries: schema5DepthShadow(expected)
                )
                let fullStart = DispatchTime.now().uptimeNanoseconds
                let decoded = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(finalSnapshot)
                let fullElapsed = DispatchTime.now().uptimeNanoseconds &- fullStart
                guard decoded.count == liveCount else {
                    throw SegmentedManifestShadowError.invariantViolation
                }

                samples.append(
                    Schema5ReopenDepthSample(
                        depth: depth,
                        repetition: repetition,
                        liveEntries: liveCount,
                        replayedMutations: depth * recordsPerRun,
                        baseBytes: base.byteCount,
                        runBytes: runBytes,
                        rootBytes: rootBytes,
                        referencedBytes: base.byteCount + runBytes + rootBytes,
                        segmentedRecoverNanoseconds: recoverElapsed,
                        fullSnapshotBytes: finalSnapshot.count,
                        fullSnapshotDecodeNanoseconds: fullElapsed,
                        exactState: true
                    )
                )
            }
        }

        var medians: [String: UInt64] = [:]
        for depth in depths {
            let rows = samples.filter { $0.depth == depth }
            medians["depth-\(depth)-segmented"] = median(rows.map(\.segmentedRecoverNanoseconds))
            medians["depth-\(depth)-full"] = median(rows.map(\.fullSnapshotDecodeNanoseconds))
        }
        let controls = try schema5IndexedRecoveryControls(root: root)
        let allExact = samples.allSatisfy(\.exactState)
        guard allExact,
            controls.unaffectedConflictRejected,
            controls.sameRunSwapAccepted,
            controls.corruptRunRejected
        else { throw SegmentedManifestShadowError.invariantViolation }
        let report = Schema5ReopenDepthReport(
            schemaVersion: 2,
            profile: profile.rawValue,
            liveEntries: liveCount,
            recordsPerRun: recordsPerRun,
            depths: depths,
            repetitions: repetitions,
            samples: samples,
            medians: medians,
            allExact: allExact,
            unaffectedOwnershipConflictRejected: controls.unaffectedConflictRejected,
            sameRunOwnershipSwapAccepted: controls.sameRunSwapAccepted,
            corruptRunRejectedBeforeIndexedApply: controls.corruptRunRejected,
            claims: .init(
                formalPerformance: false,
                productionFormat: false,
                physicalIOBytes: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }


    private static func schema5ReopenArguments(
        _ arguments: [String]
    ) throws -> (root: URL, profile: Schema5ReopenProfile) {
        guard arguments.count == 2 || arguments.count == 4,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw SegmentedManifestShadowError.invalidArguments }
        let profile: Schema5ReopenProfile
        if arguments.count == 2 {
            profile = .v1JSON
        } else {
            guard arguments[2] == "--profile",
                let parsed = Schema5ReopenProfile(rawValue: arguments[3])
            else { throw SegmentedManifestShadowError.invalidArguments }
            profile = parsed
        }
        return (URL(fileURLWithPath: arguments[1], isDirectory: true), profile)
    }

    private static func schema5WriteDepthBase(
        profile: Schema5ReopenProfile,
        initialState: [String: SegmentedManifestEntry],
        baseSnapshot: Data,
        liveCount: Int,
        segments: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        switch profile {
        case .v1JSON:
            return try SegmentedManifestPrototypeV1.writeBaseJSON(
                baseSnapshot,
                entryCount: liveCount,
                fileName: "base-depth.json",
                directory: segments
            )
        case .v2Binary:
            return try SegmentedManifestPrototypeV1.writeBaseBinary(
                initialState,
                fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
                directory: segments
            )
        case .v3CompactBinary, .v4Compound:
            return try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
                initialState,
                fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
                directory: segments
            )
        }
    }

    private static func schema5MakeDepthRoot(
        profile: Schema5ReopenProfile,
        generation: UInt64,
        base: SegmentedManifestDescriptorV1,
        runs: [SegmentedManifestDescriptorV1]
    ) throws -> SegmentedManifestRootV1 {
        switch profile {
        case .v1JSON:
            return try SegmentedManifestPrototypeV1.makeRoot(
                generation: generation,
                base: base,
                runs: runs
            )
        case .v2Binary:
            return try SegmentedManifestPrototypeV1.makeRootV2(
                generation: generation,
                base: base,
                runs: runs
            )
        case .v3CompactBinary:
            return try SegmentedManifestPrototypeV1.makeRootV3(
                generation: generation,
                base: base,
                runs: runs
            )
        case .v4Compound:
            return try SegmentedManifestPrototypeV1.makeRootV4(
                generation: generation,
                base: base,
                runs: runs
            )
        }
    }

    static func schema5DepthMutations(
        runIndex: Int,
        baseEntries: [SegmentedShadowEntry],
        expected: [String: SegmentedManifestEntry],
        count: Int
    ) throws -> [SegmentedManifestMutation] {
        var mutations: [SegmentedManifestMutation] = []
        mutations.reserveCapacity(count)
        let start = (runIndex * count) % baseEntries.count
        for offset in 0..<count {
            let source = baseEntries[(start + offset) % baseEntries.count]
            guard let current = expected[source.key] else {
                throw SegmentedManifestShadowError.invariantViolation
            }
            mutations.append(
                .upsert(
                    SegmentedManifestEntry(
                        key: current.key,
                        physicalID: PhysicalBlobID(),
                        partition: current.partition,
                        digest: current.digest,
                        byteCount: current.byteCount,
                        lastAccess: Date(
                            timeIntervalSinceReferenceDate:
                                current.lastAccess.timeIntervalSinceReferenceDate
                                + Double(runIndex + 1) / 1000
                        )
                    )
                )
            )
        }
        return mutations.sorted { $0.key < $1.key }
    }

    static func schema5DepthEntry(_ entry: SegmentedShadowEntry) -> SegmentedManifestEntry {
        SegmentedManifestEntry(
            key: entry.key,
            physicalID: entry.physicalID,
            partition: entry.partition,
            digest: entry.digest,
            byteCount: entry.byteCount,
            lastAccess: entry.lastAccess
        )
    }

    static func schema5DepthShadow(
        _ state: [String: SegmentedManifestEntry]
    ) -> [String: FileBlobStoreRecordShadowEntry] {
        state.mapValues { entry in
            FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}
