import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum SegmentedRebaseCrashPoint: String {
    case candidateVerifiedRootOld = "candidate-verified-root-old"
    case rootPreRename = "root-pre-rename"
    case rootPostRename = "root-post-rename"
    case rootPostDirectorySync = "root-post-directory-sync"

    var writerPoint: DurableFileWriteSwitchPoint? {
        switch self {
        case .candidateVerifiedRootOld:
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

private struct SegmentedRebaseCrashSeedReport: Codable {
    let schemaVersion: Int
    let frozenGeneration: UInt64
    let oldGeneration: UInt64
    let newGeneration: UInt64
    let originalBaseSHA256: String
    let candidateBaseSHA256: String
    let frozenRunSHA256: String
    let suffixRunSHA256: String
    let expectedStateCommitment: String
    let oldRootSeal: String
    let newRootSeal: String
}

private struct SegmentedRebaseCrashInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let baseSHA256: String
    let runSHA256: [String]
    let runCount: Int
    let stateCommitment: String
    let rootSeal: String
}

extension SegmentedManifestShadowProbe {
    private static let rebaseCrashExitCode: Int32 = 91

    static func rebaseCrashSeed(arguments: [String]) throws {
        let root = try rebaseCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let baseEntries = try makeBaseEntries(count: 128)
        let baseState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let base = try rebaseCrashWriteBase(
            baseEntries,
            fileName: "base-rebase-crash-origin.seg",
            directory: segments
        )
        let frozenMutations = try makeRunMutations(base: baseEntries, count: 32)
        let frozenRun = try rebaseCrashWriteRun(
            frozenMutations,
            fileName: "run-rebase-crash-frozen.seg",
            directory: segments
        )
        let frozenState = try apply(frozenMutations, to: baseState)
        let frozen = try makeRoot(generation: 89, base: base, runs: [frozenRun])
        let candidate = try rebaseCrashWriteBase(
            frozenState.values.sorted { $0.key < $1.key },
            fileName: "base-rebase-crash-candidate.seg",
            directory: segments
        )
        let suffixMutations = try rebaseCrashSuffix(frozenState.values.sorted { $0.key < $1.key })
        let suffixRun = try rebaseCrashWriteRun(
            suffixMutations,
            fileName: "run-rebase-crash-suffix.seg",
            directory: segments
        )
        let expected = try apply(suffixMutations, to: frozenState)
        let current = try makeRoot(
            generation: 90,
            base: base,
            runs: [frozenRun, suffixRun]
        )
        let proof = try makeSemanticProof(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segments
        )
        let proposed = try boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: proof,
            expectedCandidate: candidate
        )
        guard try rebaseCrashRecover(current, directory: segments) == expected,
            try rebaseCrashRecover(proposed, directory: segments) == expected
        else { throw SegmentedManifestShadowError.invariantViolation }

        let rootURL = root.appendingPathComponent("shadow-root.json")
        try DurableFileWriter.writeReplacing(try encodeRoot(current), to: rootURL)
        try rebaseCrashWriteJSON(
            SegmentedRebaseCrashSeedReport(
                schemaVersion: 1,
                frozenGeneration: frozen.generation,
                oldGeneration: current.generation,
                newGeneration: proposed.generation,
                originalBaseSHA256: base.sha256,
                candidateBaseSHA256: candidate.sha256,
                frozenRunSHA256: frozenRun.sha256,
                suffixRunSHA256: suffixRun.sha256,
                expectedStateCommitment: try semanticStateCommitment(expected),
                oldRootSeal: current.seal,
                newRootSeal: proposed.seal
            )
        )
    }

    static func rebaseCrash(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = SegmentedRebaseCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.validateDirectory(root)
        try StorageDirectorySecurity.validateDirectory(segments)
        let rootURL = root.appendingPathComponent("shadow-root.json")
        let current = try rebaseCrashReadRoot(rootURL)
        guard current.runs.count == 2,
            current.generation > 1
        else { throw SegmentedManifestShadowError.invalidFormat }
        let frozen = try makeRoot(
            generation: current.generation - 1,
            base: current.base,
            runs: [current.runs[0]]
        )
        let candidateURL = segments.appendingPathComponent("base-rebase-crash-candidate.seg")
        let candidateData = try BoundedFileReader.read(from: candidateURL, maximumBytes: maximumBaseBytes)
        let candidateEntries = try decodeBase(candidateData)
        let candidate = try descriptor(.base, url: candidateURL, expectedRecords: candidateEntries.count)
        let proof = try makeSemanticProof(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segments
        )
        let proposed = try boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: proof,
            expectedCandidate: candidate
        )
        guard proposed.runs.count == 1,
            proposed.runs[0] == current.runs[1]
        else { throw SegmentedManifestShadowError.invariantViolation }

        if point == .candidateVerifiedRootOld {
            Darwin._exit(rebaseCrashExitCode)
        }
        let target = point.writerPoint
        try DurableFileWriter.writeReplacing(
            try encodeRoot(proposed),
            to: rootURL,
            faultInjector: { switchPoint in
                if switchPoint == target {
                    Darwin._exit(rebaseCrashExitCode)
                }
            }
        )
        Darwin._exit(92)
    }

    static func rebaseCrashInspect(arguments: [String]) throws {
        let root = try rebaseCrashRoot(arguments)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.validateDirectory(root)
        try StorageDirectorySecurity.validateDirectory(segments)
        let recovered = try rebaseCrashReadRoot(root.appendingPathComponent("shadow-root.json"))
        let state = try rebaseCrashRecover(recovered, directory: segments)
        try rebaseCrashWriteJSON(
            SegmentedRebaseCrashInspectReport(
                schemaVersion: 1,
                generation: recovered.generation,
                baseSHA256: recovered.base.sha256,
                runSHA256: recovered.runs.map(\.sha256),
                runCount: recovered.runs.count,
                stateCommitment: try semanticStateCommitment(state),
                rootSeal: recovered.seal
            )
        )
    }

    private static func rebaseCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func rebaseCrashReadRoot(_ url: URL) throws -> SegmentedShadowRoot {
        let data = try BoundedFileReader.read(from: url, maximumBytes: maximumRootBytes)
        let root = try JSONDecoder().decode(SegmentedShadowRoot.self, from: data)
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        return root
    }

    private static func rebaseCrashSuffix(
        _ entries: [SegmentedShadowEntry]
    ) throws -> [SegmentedShadowMutation] {
        guard entries.count >= 2 else { throw SegmentedManifestShadowError.invalidFormat }
        let source = entries[1]
        let repaired = SegmentedShadowEntry(
            key: source.key,
            physicalID: PhysicalBlobID(),
            partition: source.partition,
            digest: source.digest,
            byteCount: source.byteCount,
            lastAccess: source.lastAccess.addingTimeInterval(4)
        )
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-rebase-process-v1",
            material: Data("create".utf8)
        )
        let payload = Data("rebase-process-create".utf8)
        let digest = BlobDigest.sha256(of: payload)
        let created = SegmentedShadowEntry(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            physicalID: PhysicalBlobID(),
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 1_020_000_000)
        )
        return [
            .tombstone(key: entries[0].key),
            .upsert(repaired),
            .upsert(created),
        ].sorted { $0.key < $1.key }
    }

    private static func rebaseCrashWriteBase(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    private static func rebaseCrashWriteRun(
        _ mutations: [SegmentedShadowMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: url)
        return try descriptor(.run, url: url, expectedRecords: mutations.count)
    }

    private static func rebaseCrashRecover(
        _ root: SegmentedShadowRoot,
        directory: URL
    ) throws -> [String: SegmentedShadowEntry] {
        var state = Dictionary(uniqueKeysWithValues: try readBase(root.base, directory: directory).map { ($0.key, $0) })
        for run in root.runs {
            state = try apply(try readRun(run, directory: directory), to: state)
        }
        return state
    }

    private static func rebaseCrashWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
