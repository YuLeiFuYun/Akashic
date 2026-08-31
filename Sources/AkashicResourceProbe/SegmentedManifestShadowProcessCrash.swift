import AkashicCore
import CryptoKit
import Darwin
import Foundation

private enum SegmentedShadowProcessCrashPoint: String, Sendable {
    case runDurableRootOld = "run-durable-root-old"
    case rootPreRename = "root-pre-rename"
    case rootPostRename = "root-post-rename"
    case rootPostDirectorySync = "root-post-directory-sync"

    var durableWriterPoint: DurableFileWriteSwitchPoint? {
        switch self {
        case .runDurableRootOld:
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

private struct SegmentedShadowProcessSeedReport: Codable {
    let schemaVersion: Int
    let oldGeneration: UInt64
    let newGeneration: UInt64
    let oldRecordCount: Int
    let newRecordCount: Int
    let oldStateSHA256: String
    let newStateSHA256: String
    let baseSHA256: String
    let runSHA256: String
    let oldRootSeal: String
    let newRootSeal: String
}

private struct SegmentedShadowProcessInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let recordCount: Int
    let stateSHA256: String
    let rootSeal: String
}

extension SegmentedManifestShadowProbe {
    private static let processCrashExitCode: Int32 = 91
    private static let processBaseRecordCount = 1_024
    private static let processRunRecordCount = 512

    static func processCrashSeed(arguments: [String]) throws {
        let root = try processRoot(arguments: arguments)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segmentDirectory)

        let baseEntries = try makeBaseEntries(count: processBaseRecordCount)
        let mutations = try makeRunMutations(base: baseEntries, count: processRunRecordCount)
        let oldState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let newState = try apply(mutations, to: oldState)

        let baseURL = segmentDirectory.appendingPathComponent("base-0001.seg")
        let runURL = segmentDirectory.appendingPathComponent("run-0001.seg")
        try DurableFileWriter.writeReplacing(try encodeBase(baseEntries), to: baseURL)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: runURL)
        let base = try descriptor(.base, url: baseURL, expectedRecords: baseEntries.count)
        let run = try descriptor(.run, url: runURL, expectedRecords: mutations.count)

        let oldRoot = try makeRoot(generation: 10, base: base, runs: [])
        let newRoot = try makeRoot(generation: 11, base: base, runs: [run])
        let rootURL = root.appendingPathComponent("shadow-root.json")
        try DurableFileWriter.writeReplacing(try encodeRoot(oldRoot), to: rootURL)
        guard try recoverRootState(rootURL: rootURL, segmentDirectory: segmentDirectory) == oldState else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        try writeProcessJSON(
            SegmentedShadowProcessSeedReport(
                schemaVersion: 1,
                oldGeneration: oldRoot.generation,
                newGeneration: newRoot.generation,
                oldRecordCount: oldState.count,
                newRecordCount: newState.count,
                oldStateSHA256: try processStateSHA256(oldState),
                newStateSHA256: try processStateSHA256(newState),
                baseSHA256: base.sha256,
                runSHA256: run.sha256,
                oldRootSeal: oldRoot.seal,
                newRootSeal: newRoot.seal
            )
        )
    }

    static func processCrash(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = SegmentedShadowProcessCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.validateDirectory(root)
        try StorageDirectorySecurity.validateDirectory(segmentDirectory)
        let rootURL = root.appendingPathComponent("shadow-root.json")
        let oldRoot = try readProcessRoot(rootURL)
        guard oldRoot.runs.isEmpty else { throw SegmentedManifestShadowError.invalidFormat }
        let runURL = segmentDirectory.appendingPathComponent("run-0001.seg")
        let run = try descriptor(.run, url: runURL, expectedRecords: processRunRecordCount)
        _ = try readRun(run, directory: segmentDirectory)

        if point == .runDurableRootOld {
            Darwin._exit(processCrashExitCode)
        }

        let nextGeneration = oldRoot.generation.addingReportingOverflow(1)
        guard !nextGeneration.overflow else { throw SegmentedManifestShadowError.invalidFormat }
        let newRoot = try makeRoot(
            generation: nextGeneration.partialValue,
            base: oldRoot.base,
            runs: [run]
        )
        let target = point.durableWriterPoint
        try DurableFileWriter.writeReplacing(
            try encodeRoot(newRoot),
            to: rootURL,
            faultInjector: { switchPoint in
                if switchPoint == target {
                    Darwin._exit(processCrashExitCode)
                }
            }
        )
        Darwin._exit(92)
    }

    static func processCrashInspect(arguments: [String]) throws {
        let root = try processRoot(arguments: arguments)
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.validateDirectory(root)
        try StorageDirectorySecurity.validateDirectory(segmentDirectory)
        let rootURL = root.appendingPathComponent("shadow-root.json")
        let recoveredRoot = try readProcessRoot(rootURL)
        let state = try recoverRootState(rootURL: rootURL, segmentDirectory: segmentDirectory)
        try writeProcessJSON(
            SegmentedShadowProcessInspectReport(
                schemaVersion: 1,
                generation: recoveredRoot.generation,
                runCount: recoveredRoot.runs.count,
                recordCount: state.count,
                stateSHA256: try processStateSHA256(state),
                rootSeal: recoveredRoot.seal
            )
        )
    }

    private static func processRoot(arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func readProcessRoot(_ rootURL: URL) throws -> SegmentedShadowRoot {
        let data = try BoundedFileReader.read(from: rootURL, maximumBytes: maximumRootBytes)
        let root = try JSONDecoder().decode(SegmentedShadowRoot.self, from: data)
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        return root
    }

    private static func processStateSHA256(
        _ state: [String: SegmentedShadowEntry]
    ) throws -> String {
        let canonical = state.values.sorted { $0.key < $1.key }
        let data = try encodeBase(canonical)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeProcessJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
