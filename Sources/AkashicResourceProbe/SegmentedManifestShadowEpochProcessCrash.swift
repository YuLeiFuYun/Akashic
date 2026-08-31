import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum SegmentedEpochCrashPoint: String {
    case runDurableRootOld = "run-durable-root-old"
    case rootPreRename = "root-pre-rename"
    case rootPostRename = "root-post-rename"
    case rootPostDirectorySync = "root-post-directory-sync"
    case oneNewHead = "one-new-head"
    case bothNewHeads = "both-new-heads"

    var writerPoint: DurableFileWriteSwitchPoint? {
        switch self {
        case .runDurableRootOld, .oneNewHead, .bothNewHeads:
            nil
        case .rootPreRename:
            .afterFileSynced
        case .rootPostRename:
            .afterRename
        case .rootPostDirectorySync:
            .afterDirectorySynced
        }
    }
}

private struct SegmentedEpochCrashSeedReport: Codable {
    let schemaVersion: Int
    let oldGeneration: UInt64
    let newGeneration: UInt64
    let baseSHA256: String
    let runSHA256: String
    let runRecordCount: Int
    let expectedStateCommitment: String
    let oldRootSeal: String
    let newRootSeal: String
}

private struct SegmentedEpochCrashInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let runSHA256: [String]
    let stateCommitment: String
    let currentHeadCount: Int
    let rootSeal: String
}

extension SegmentedManifestShadowProbe {
    private static let epochCrashExitCode: Int32 = 91
    private static let epochCrashOldGeneration: UInt64 = 100
    private static let epochCrashNewGeneration: UInt64 = 101

    static func epochCrashSeed(arguments: [String]) throws {
        let root = try epochCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let heads = root.appendingPathComponent("heads", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        try StorageDirectorySecurity.prepareDirectory(heads)

        let baseEntries = try makeBaseEntries(count: 64)
        let base = try epochWriteBase(
            baseEntries,
            fileName: "base-epoch-crash.seg",
            directory: segments
        )
        let oldRoot = try makeRoot(
            generation: epochCrashOldGeneration,
            base: base,
            runs: []
        )
        let rootURL = root.appendingPathComponent("shadow-root.json")
        try DurableFileWriter.writeReplacing(try encodeRoot(oldRoot), to: rootURL)

        try DirectoryHeadShadowProbe.initializeMigrationShadow(
            root: heads,
            generation: epochCrashOldGeneration
        )
        try epochApplyMixedMutations(
            heads: heads,
            generation: epochCrashOldGeneration,
            baseEntries: baseEntries
        )
        let oldRecovered = try DirectoryHeadShadowProbe.recover(
            root: heads,
            generation: epochCrashOldGeneration,
            base: epochShadowState(
                Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
            )
        )
        let epochMutations = try epochSegmentedMutations(oldRecovered)
        let runURL = segments.appendingPathComponent("run-epoch-crash-100.seg")
        try DurableFileWriter.writeReplacing(try encodeRun(epochMutations), to: runURL)
        let run = try descriptor(.run, url: runURL, expectedRecords: epochMutations.count)
        let newRoot = try makeRoot(
            generation: epochCrashNewGeneration,
            base: base,
            runs: [run]
        )
        let expected = epochSegmentedState(oldRecovered.logical)
        let history = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        guard try apply(epochMutations, to: history) == expected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        try epochCrashWriteJSON(
            SegmentedEpochCrashSeedReport(
                schemaVersion: 1,
                oldGeneration: epochCrashOldGeneration,
                newGeneration: epochCrashNewGeneration,
                baseSHA256: base.sha256,
                runSHA256: run.sha256,
                runRecordCount: run.recordCount,
                expectedStateCommitment: try semanticStateCommitment(expected),
                oldRootSeal: oldRoot.seal,
                newRootSeal: newRoot.seal
            )
        )
    }

    static func epochCrash(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = SegmentedEpochCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let heads = root.appendingPathComponent("heads", isDirectory: true)
        let rootURL = root.appendingPathComponent("shadow-root.json")
        try StorageDirectorySecurity.validateDirectory(root)
        try StorageDirectorySecurity.validateDirectory(segments)
        try StorageDirectorySecurity.validateDirectory(heads)

        let oldRoot = try epochCrashReadRoot(rootURL)
        guard oldRoot.generation == epochCrashOldGeneration,
            oldRoot.runs.isEmpty
        else { throw SegmentedManifestShadowError.invalidFormat }
        let oldState = try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: false
        )
        let runURL = segments.appendingPathComponent("run-epoch-crash-100.seg")
        let runData = try BoundedFileReader.read(from: runURL, maximumBytes: maximumRunBytes)
        let mutations = try decodeRun(runData)
        let run = try descriptor(.run, url: runURL, expectedRecords: mutations.count)
        let history = Dictionary(
            uniqueKeysWithValues: try readBase(oldRoot.base, directory: segments).map { ($0.key, $0) }
        )
        guard try apply(mutations, to: history) == oldState else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let newRoot = try makeRoot(
            generation: epochCrashNewGeneration,
            base: oldRoot.base,
            runs: [run]
        )

        if point == .runDurableRootOld {
            Darwin._exit(epochCrashExitCode)
        }
        if let target = point.writerPoint {
            try DurableFileWriter.writeReplacing(
                try encodeRoot(newRoot),
                to: rootURL,
                faultInjector: { switchPoint in
                    if switchPoint == target {
                        Darwin._exit(epochCrashExitCode)
                    }
                }
            )
            Darwin._exit(92)
        }

        try DurableFileWriter.writeReplacing(try encodeRoot(newRoot), to: rootURL)
        switch point {
        case .oneNewHead:
            try epochCrashWriteEmptyHead(
                generation: epochCrashNewGeneration,
                slot: 0,
                heads: heads
            )
            try DirectoryHeadShadowIO.synchronize(heads)
            Darwin._exit(epochCrashExitCode)
        case .bothNewHeads:
            try DirectoryHeadShadowProbe.initializeMigrationShadow(
                root: heads,
                generation: epochCrashNewGeneration
            )
            Darwin._exit(epochCrashExitCode)
        default:
            Darwin._exit(92)
        }
    }

    static func epochCrashInspect(arguments: [String]) throws {
        let root = try epochCrashRoot(arguments)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let heads = root.appendingPathComponent("heads", isDirectory: true)
        let rootURL = root.appendingPathComponent("shadow-root.json")
        let recoveredState = try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: true
        )
        let recoveredRoot = try epochCrashReadRoot(rootURL)
        let currentHeadCount = try epochCrashHeadCount(
            generation: recoveredRoot.generation,
            heads: heads
        )
        try epochCrashWriteJSON(
            SegmentedEpochCrashInspectReport(
                schemaVersion: 1,
                generation: recoveredRoot.generation,
                runCount: recoveredRoot.runs.count,
                runSHA256: recoveredRoot.runs.map(\.sha256),
                stateCommitment: try semanticStateCommitment(recoveredState),
                currentHeadCount: currentHeadCount,
                rootSeal: recoveredRoot.seal
            )
        )
    }

    private static func epochCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func epochCrashReadRoot(_ url: URL) throws -> SegmentedShadowRoot {
        let data = try BoundedFileReader.read(from: url, maximumBytes: maximumRootBytes)
        let root = try JSONDecoder().decode(SegmentedShadowRoot.self, from: data)
        try validateRootStructure(root)
        guard try validateRootSeal(root) else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return root
    }

    private static func epochCrashWriteEmptyHead(
        generation: UInt64,
        slot: UInt8,
        heads: URL
    ) throws {
        let head = try DirectoryHeadShadowProbe.makeHead(
            generation: generation,
            slot: slot,
            sequence: 0,
            count: 0,
            root: DirectoryHeadShadowProbe.zeroRoot
        )
        try DirectoryHeadShadowIO.setAttribute(
            DirectoryHeadIdentity(generation: generation, slot: slot).name,
            value: try DirectoryHeadShadowProbe.encodeHead(head),
            at: heads,
            flags: XATTR_CREATE
        )
    }

    private static func epochCrashHeadCount(
        generation: UInt64,
        heads: URL
    ) throws -> Int {
        let names = try XattrShadowProbeIO.listAttributes(heads)
        var slots = Set<UInt8>()
        for name in names {
            guard let identity = try DirectoryHeadIdentity.parse(name) else { continue }
            if identity.generation == generation {
                guard slots.insert(identity.slot).inserted else {
                    throw DirectoryHeadShadowError.invalidHead
                }
            }
        }
        return slots.count
    }

    private static func epochCrashWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
