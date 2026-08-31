import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct BinaryBaseV2TransitionCrashSeedReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let entryCount: Int
    let runCount: Int
    let stateCommitment: String
    let profile: String
}

private struct BinaryBaseV2TransitionCrashInspectReport: Codable {
    struct Claims: Codable {
        let processCrash: Bool
        let powerLoss: Bool
        let fileBlobStoreIntegration: Bool
        let automaticMigration: Bool
    }

    let schemaVersion: Int
    let point: String
    let generation: UInt64
    let profile: String
    let recoveredExact: Bool
    let physicalOwnershipExact: Bool
    let stateCommitment: String
    let retiredSegmentCount: Int
    let remainingDebtCount: Int
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    private static let binaryBaseV2TransitionCrashExitCode: Int32 = 91
    private static let binaryBaseV2TransitionCrashGeneration: UInt64 = 7_001
    private static let binaryBaseV2TransitionCrashSeedValue = 80_000

    static func binaryBaseV2TransitionCrashSeed(arguments: [String]) throws {
        let root = try binaryBaseV2TransitionCrashRoot(arguments)
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let fixture = try binaryBaseV2TransitionCrashFixture(root: root)
        try binaryBaseV2TransitionCrashWriteJSON(
            BinaryBaseV2TransitionCrashSeedReport(
                schemaVersion: 1,
                generation: fixture.root.generation,
                entryCount: fixture.expected.count,
                runCount: fixture.root.runs.count,
                stateCommitment: try SegmentedManifestPrototypeV1.semanticStateCommitment(
                    fixture.expected
                ),
                profile: fixture.root.profile
            )
        )
    }

    static func binaryBaseV2TransitionCrash(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = DurableFileWriteSwitchPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let rootURL = root.appendingPathComponent("manifest.json")
        let v1Root = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        guard v1Root.profile == SegmentedManifestPrototypeV1.profileV1 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let candidate = try SegmentedManifestBinaryBaseTransitionV2.prepare(
            frozenRoot: v1Root,
            segmentDirectory: segments,
            candidateFileName: "base-binary-\(UUID().uuidString.lowercased()).akb"
        )
        try SegmentedManifestPrototypeV1.writeRoot(
            candidate.root,
            to: rootURL,
            faultInjector: { observed in
                if observed == point { Darwin._exit(binaryBaseV2TransitionCrashExitCode) }
            }
        )
        throw SegmentedManifestShadowError.invariantViolation
    }

    static func binaryBaseV2TransitionCrashInspect(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = DurableFileWriteSwitchPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let rootURL = root.appendingPathComponent("manifest.json")
        let onDiskRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let expected = try binaryBaseV2TransitionCrashExpectedState()
        let recovered = try SegmentedManifestPrototypeV1.recover(
            root: onDiskRoot,
            segmentDirectory: segments
        )
        let expectedProfile: String
        let expectedRetiredSegments: Int
        switch point {
        case .afterDataWritten, .afterFileSynced:
            expectedProfile = SegmentedManifestPrototypeV1.profileV1
            expectedRetiredSegments = 1
        case .afterRename, .afterDirectorySynced:
            expectedProfile = SegmentedManifestPrototypeV1.profileV2
            expectedRetiredSegments = 2
        }
        let expectedPhysical = Dictionary(
            uniqueKeysWithValues: expected.map { ($0.key, $0.value.physicalID) }
        )
        let recoveredPhysical = Dictionary(
            uniqueKeysWithValues: recovered.map { ($0.key, $0.value.physicalID) }
        )
        guard onDiskRoot.profile == expectedProfile,
            onDiskRoot.generation == binaryBaseV2TransitionCrashGeneration,
            recovered == expected,
            recoveredPhysical == expectedPhysical
        else { throw SegmentedManifestShadowError.invariantViolation }
        let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: onDiskRoot,
            directory: segments
        )
        guard cleanup.deletedCount == expectedRetiredSegments,
            cleanup.remainingDebtCount == 0
        else { throw SegmentedManifestShadowError.invariantViolation }
        try binaryBaseV2TransitionCrashWriteJSON(
            BinaryBaseV2TransitionCrashInspectReport(
                schemaVersion: 1,
                point: point.rawValue,
                generation: onDiskRoot.generation,
                profile: onDiskRoot.profile,
                recoveredExact: true,
                physicalOwnershipExact: true,
                stateCommitment: try SegmentedManifestPrototypeV1.semanticStateCommitment(
                    recovered
                ),
                retiredSegmentCount: cleanup.deletedCount,
                remainingDebtCount: cleanup.remainingDebtCount,
                claims: .init(
                    processCrash: true,
                    powerLoss: false,
                    fileBlobStoreIntegration: false,
                    automaticMigration: false
                )
            )
        )
    }

    private struct BinaryBaseV2TransitionCrashFixture {
        let root: SegmentedManifestRootV1
        let expected: [String: SegmentedManifestEntry]
    }

    private static func binaryBaseV2TransitionCrashFixture(
        root: URL
    ) throws -> BinaryBaseV2TransitionCrashFixture {
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let initial = try binaryBaseCandidateState(
            count: 8,
            seed: binaryBaseV2TransitionCrashSeedValue
        )
        let expected = try binaryBaseV2TransitionCrashExpectedState(initial: initial)
        let baseData = try SegmentedManifestPrototypeV1.encodeCompactionBaseSnapshot(
            generation: binaryBaseV2TransitionCrashGeneration,
            state: initial
        )
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: initial.count,
            fileName: "base-compaction-\(UUID().uuidString.lowercased()).json",
            directory: segments
        )
        let firstKey = try binaryBaseV2TransitionRequire(initial.keys.sorted().first)
        let runEntry = try binaryBaseV2TransitionRequire(expected[firstKey])
        let run = try SegmentedManifestPrototypeV1.writeRun(
            [.upsert(runEntry)],
            fileName: "run-g\(binaryBaseV2TransitionCrashGeneration)-\(UUID().uuidString.lowercased()).seg",
            directory: segments
        )
        let segmentedRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: binaryBaseV2TransitionCrashGeneration,
            base: base,
            runs: [run]
        )
        try SegmentedManifestPrototypeV1.writeRoot(
            segmentedRoot,
            to: root.appendingPathComponent("manifest.json")
        )
        guard try SegmentedManifestPrototypeV1.recover(
            root: segmentedRoot,
            segmentDirectory: segments
        ) == expected else { throw SegmentedManifestShadowError.invariantViolation }
        return BinaryBaseV2TransitionCrashFixture(root: segmentedRoot, expected: expected)
    }

    private static func binaryBaseV2TransitionCrashExpectedState()
        throws -> [String: SegmentedManifestEntry]
    {
        try binaryBaseV2TransitionCrashExpectedState(
            initial: binaryBaseCandidateState(
                count: 8,
                seed: binaryBaseV2TransitionCrashSeedValue
            )
        )
    }

    private static func binaryBaseV2TransitionCrashExpectedState(
        initial: [String: SegmentedManifestEntry]
    ) throws -> [String: SegmentedManifestEntry] {
        var expected = initial
        let firstKey = try binaryBaseV2TransitionRequire(initial.keys.sorted().first)
        let current = try binaryBaseV2TransitionRequire(initial[firstKey])
        expected[firstKey] = SegmentedManifestEntry(
            key: firstKey,
            physicalID: schema5CompactionResourcePhysicalID(index: 88_888, version: 55_555),
            partition: current.partition,
            digest: current.digest,
            byteCount: current.byteCount,
            lastAccess: current.lastAccess.addingTimeInterval(1)
        )
        return expected
    }

    private static func binaryBaseV2TransitionCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func binaryBaseV2TransitionRequire<T>(_ value: T?) throws -> T {
        guard let value else { throw SegmentedManifestShadowError.invariantViolation }
        return value
    }

    private static func binaryBaseV2TransitionCrashWriteJSON<T: Encodable>(
        _ value: T
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
