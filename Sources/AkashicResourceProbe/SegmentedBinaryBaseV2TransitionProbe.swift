import AkashicCore
import AkashicDisk
import Foundation

private struct BinaryBaseV2TransitionScenarioReport: Codable {
    let name: String
    let liveCount: Int
    let frozenRunCount: Int
    let rootBytesUnchangedBeforePublish: Bool
    let generationUnchanged: Bool
    let recoveredExact: Bool
    let physicalOwnershipExact: Bool
    let oldTopologyBytes: Int
    let binaryBaseBytes: Int
    let retiredSegmentCount: Int
    let remainingDebtCount: Int
}

private struct BinaryBaseV2TransitionReport: Codable {
    struct Claims: Codable {
        let researchOnly: Bool
        let fileBlobStoreIntegration: Bool
        let automaticMigration: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let processCrash: Bool
    }

    let schemaVersion: Int
    let scenarios: [BinaryBaseV2TransitionScenarioReport]
    let allCasesPass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func binaryBaseV2TransitionShadow() throws {
        let scenarios: [(String, Int, Int)] = [
            ("empty", 0, 0),
            ("small-one-run", 8, 1),
            ("replay-heavy", 256, 64),
            ("live-heavy", 16_384, 8),
        ]
        var reports: [BinaryBaseV2TransitionScenarioReport] = []
        for (index, scenario) in scenarios.enumerated() {
            reports.append(
                try binaryBaseV2TransitionScenario(
                    name: scenario.0,
                    liveCount: scenario.1,
                    runCount: scenario.2,
                    seed: 70_000 + index
                )
            )
        }
        let allPass = reports.allSatisfy {
            $0.rootBytesUnchangedBeforePublish
                && $0.generationUnchanged
                && $0.recoveredExact
                && $0.physicalOwnershipExact
                && $0.retiredSegmentCount == 1 + $0.frozenRunCount
                && $0.remainingDebtCount == 0
        }
        guard allPass else { throw SegmentedManifestShadowError.invariantViolation }
        let report = BinaryBaseV2TransitionReport(
            schemaVersion: 1,
            scenarios: reports,
            allCasesPass: allPass,
            claims: .init(
                researchOnly: true,
                fileBlobStoreIntegration: false,
                automaticMigration: false,
                formalPerformance: false,
                physicalDevice: false,
                processCrash: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func binaryBaseV2TransitionScenario(
        name: String,
        liveCount: Int,
        runCount: Int,
        seed: Int
    ) throws -> BinaryBaseV2TransitionScenarioReport {
        guard liveCount > 0 || runCount == 0 else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let rootDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-binary-v2-transition-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        try StorageDirectorySecurity.prepareDirectory(rootDirectory)
        let segments = rootDirectory.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let generation = UInt64(100 + seed)
        let initial = try binaryBaseCandidateState(count: liveCount, seed: seed)
        let baseData = try SegmentedManifestPrototypeV1.encodeCompactionBaseSnapshot(
            generation: generation,
            state: initial
        )
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: initial.count,
            fileName: "base-compaction-\(UUID().uuidString.lowercased()).json",
            directory: segments
        )

        var expected = initial
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(runCount)
        if runCount > 0 {
            let key = try requireTransitionValue(expected.keys.sorted().first)
            for runIndex in 0..<runCount {
                let current = try requireTransitionValue(expected[key])
                let replacement = SegmentedManifestEntry(
                    key: key,
                    physicalID: schema5CompactionResourcePhysicalID(
                        index: seed * 1_000 + runIndex,
                        version: 40_000 + runIndex
                    ),
                    partition: current.partition,
                    digest: current.digest,
                    byteCount: current.byteCount,
                    lastAccess: current.lastAccess.addingTimeInterval(Double(runIndex + 1))
                )
                let run = try SegmentedManifestPrototypeV1.writeRun(
                    [.upsert(replacement)],
                    fileName: "run-g\(generation)-\(UUID().uuidString.lowercased()).seg",
                    directory: segments
                )
                runs.append(run)
                expected[key] = replacement
            }
        }

        let v1Root = try SegmentedManifestPrototypeV1.makeRoot(
            generation: generation,
            base: base,
            runs: runs
        )
        let rootURL = rootDirectory.appendingPathComponent("manifest.json")
        try SegmentedManifestPrototypeV1.writeRoot(v1Root, to: rootURL)
        let rootBytesBefore = try Data(contentsOf: rootURL)

        let candidate = try SegmentedManifestBinaryBaseTransitionV2.prepare(
            frozenRoot: v1Root,
            segmentDirectory: segments,
            candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
        )
        let rootBytesAfterPrepare = try Data(contentsOf: rootURL)
        let recoveredCandidate = try SegmentedManifestPrototypeV1.recover(
            root: candidate.root,
            segmentDirectory: segments
        )
        let expectedPhysical = Dictionary(
            uniqueKeysWithValues: expected.map { ($0.key, $0.value.physicalID) }
        )
        let candidatePhysical = Dictionary(
            uniqueKeysWithValues: recoveredCandidate.map { ($0.key, $0.value.physicalID) }
        )
        try SegmentedManifestPrototypeV1.writeRoot(candidate.root, to: rootURL)
        let published = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let recoveredPublished = try SegmentedManifestPrototypeV1.recover(
            root: published,
            segmentDirectory: segments
        )
        guard recoveredPublished == expected else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: published,
            directory: segments
        )
        let oldTopologyBytes = runs.reduce(base.byteCount) { partial, run in
            partial + run.byteCount
        }

        return BinaryBaseV2TransitionScenarioReport(
            name: name,
            liveCount: liveCount,
            frozenRunCount: runCount,
            rootBytesUnchangedBeforePublish: rootBytesBefore == rootBytesAfterPrepare,
            generationUnchanged: candidate.root.generation == v1Root.generation,
            recoveredExact: recoveredCandidate == expected && recoveredPublished == expected,
            physicalOwnershipExact: candidatePhysical == expectedPhysical,
            oldTopologyBytes: oldTopologyBytes,
            binaryBaseBytes: candidate.base.byteCount,
            retiredSegmentCount: cleanup.deletedCount,
            remainingDebtCount: cleanup.remainingDebtCount
        )
    }

    private static func requireTransitionValue<T>(_ value: T?) throws -> T {
        guard let value else { throw SegmentedManifestShadowError.invariantViolation }
        return value
    }
}
