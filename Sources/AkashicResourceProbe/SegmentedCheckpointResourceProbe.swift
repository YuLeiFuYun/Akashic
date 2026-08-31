import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Foundation

private struct SegmentedCheckpointBarrier {
    let readyFD: Int32
    let goFD: Int32
    let doneFD: Int32
    let releaseFD: Int32

    func enter() throws {
        try writeByte(0x52, to: readyFD)
        try readByte(from: goFD)
    }

    func leave() throws {
        try writeByte(0x44, to: doneFD)
        try readByte(from: releaseFD)
    }

    private func writeByte(_ byte: UInt8, to fd: Int32) throws {
        var byte = byte
        while true {
            let result = Darwin.write(fd, &byte, 1)
            if result == 1 { return }
            if result < 0, errno == EINTR { continue }
            throw SegmentedManifestShadowError.invalidFormat
        }
    }

    private func readByte(from fd: Int32) throws {
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(fd, &byte, 1)
            if result == 1 { return }
            if result < 0, errno == EINTR { continue }
            throw SegmentedManifestShadowError.invalidFormat
        }
    }
}

struct SegmentedCheckpointResourceReport: Codable {
    let schemaVersion: Int
    let mode: String
    let historyEntries: Int
    let deltaRecords: Int
    let finalEntries: Int
    let measuredElapsedNanoseconds: UInt64
    let fullSnapshotBytes: Int?
    let baseBytes: Int?
    let runBytes: Int?
    let rootBytes: Int?
    let measuredRegularFileAuthorityBytes: Int
    let currentHeadCountAfterMeasurement: Int
    let logicalStateEquivalent: Bool
    let claims: Claims

    struct Claims: Codable {
        let mechanismMeasurement: Bool
        let endToEndStorePerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let productionFormat: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func checkpointResource(arguments: [String]) throws {
        let parsed = try checkpointResourceArguments(arguments)
        let root = parsed.root
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let authority = root.appendingPathComponent("authority", isDirectory: true)
        let heads = root.appendingPathComponent("heads", isDirectory: true)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(authority)
        try StorageDirectorySecurity.prepareDirectory(heads)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let allEntries = try makeBaseEntries(count: parsed.historyEntries + maximumRunRecords)
        let historyEntries = Array(allEntries.prefix(parsed.historyEntries))
        let deltaEntries = Array(allEntries.dropFirst(parsed.historyEntries).prefix(maximumRunRecords))
        let historyState = Dictionary(uniqueKeysWithValues: historyEntries.map { ($0.key, $0) })
        let deltaMutations = deltaEntries.map(SegmentedShadowMutation.upsert).sorted { $0.key < $1.key }
        let finalState = try apply(deltaMutations, to: historyState)
        guard finalState.count == parsed.historyEntries + maximumRunRecords else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let finalShadow = checkpointShadowEntries(finalState)

        let barrier = parsed.barrier
        let start: UInt64
        let elapsed: UInt64
        let fullSnapshotBytes: Int?
        let baseBytes: Int?
        let runBytes: Int?
        let rootBytes: Int?
        let measuredRegularFileAuthorityBytes: Int
        let currentHeadCount: Int
        let equivalent: Bool

        switch parsed.mode {
        case "current-full":
            let oldShadow = checkpointShadowEntries(historyState)
            let oldData = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
                generation: 1,
                entries: oldShadow
            )
            let manifestURL = authority.appendingPathComponent("manifest.json")
            try DurableFileWriter.writeReplacing(oldData, to: manifestURL)
            try DirectoryHeadShadowProbe.initializeMigrationShadow(root: heads, generation: 1)

            try barrier.enter()
            start = DispatchTime.now().uptimeNanoseconds
            let nextData = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
                generation: 2,
                entries: finalShadow
            )
            try DurableFileWriter.writeReplacing(nextData, to: manifestURL)
            try DirectoryHeadShadowProbe.initializeMigrationShadow(root: heads, generation: 2)
            elapsed = DispatchTime.now().uptimeNanoseconds &- start
            try barrier.leave()

            let recovered = try checkpointDecodeCurrentSnapshot(manifestURL)
            equivalent = recovered == finalState
            fullSnapshotBytes = nextData.count
            baseBytes = nil
            runBytes = nil
            rootBytes = nil
            measuredRegularFileAuthorityBytes = nextData.count
            currentHeadCount = try checkpointHeadCount(generation: 2, heads: heads)

        case "segmented-epoch":
            let baseData = try encodeBase(historyEntries)
            let baseURL = segments.appendingPathComponent("base-checkpoint.seg")
            try DurableFileWriter.writeReplacing(baseData, to: baseURL)
            let base = try descriptor(.base, url: baseURL, expectedRecords: historyEntries.count)
            let oldRoot = try makeRoot(generation: 1, base: base, runs: [])
            let rootURL = authority.appendingPathComponent("manifest.json")
            try DurableFileWriter.writeReplacing(try encodeRoot(oldRoot), to: rootURL)
            try DirectoryHeadShadowProbe.initializeMigrationShadow(root: heads, generation: 1)

            try barrier.enter()
            start = DispatchTime.now().uptimeNanoseconds
            let runData = try encodeRun(deltaMutations)
            let runFileName = "run-checkpoint-0001.seg"
            let runURL = segments.appendingPathComponent(runFileName)
            try DurableFileWriter.writeReplacing(runData, to: runURL)
            let run = SegmentedShadowDescriptor(
                kind: .run,
                fileName: runFileName,
                byteCount: runData.count,
                recordCount: deltaMutations.count,
                sha256: SHA256.hash(data: runData).map { String(format: "%02x", $0) }.joined()
            )
            try validateDescriptorShape(run)
            let nextRoot = try makeRoot(generation: 2, base: base, runs: [run])
            let nextRootData = try encodeRoot(nextRoot)
            try DurableFileWriter.writeReplacing(nextRootData, to: rootURL)
            try DirectoryHeadShadowProbe.initializeMigrationShadow(root: heads, generation: 2)
            elapsed = DispatchTime.now().uptimeNanoseconds &- start
            try barrier.leave()

            var recovered = Dictionary(
                uniqueKeysWithValues: try readBase(base, directory: segments).map { ($0.key, $0) }
            )
            recovered = try apply(try readRun(run, directory: segments), to: recovered)
            equivalent = recovered == finalState
            fullSnapshotBytes = nil
            baseBytes = baseData.count
            runBytes = runData.count
            rootBytes = nextRootData.count
            measuredRegularFileAuthorityBytes = runData.count + nextRootData.count
            currentHeadCount = try checkpointHeadCount(generation: 2, heads: heads)

        default:
            throw SegmentedManifestShadowError.invalidArguments
        }

        guard equivalent, currentHeadCount == 2 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let report = SegmentedCheckpointResourceReport(
            schemaVersion: 1,
            mode: parsed.mode,
            historyEntries: parsed.historyEntries,
            deltaRecords: maximumRunRecords,
            finalEntries: finalState.count,
            measuredElapsedNanoseconds: elapsed,
            fullSnapshotBytes: fullSnapshotBytes,
            baseBytes: baseBytes,
            runBytes: runBytes,
            rootBytes: rootBytes,
            measuredRegularFileAuthorityBytes: measuredRegularFileAuthorityBytes,
            currentHeadCountAfterMeasurement: currentHeadCount,
            logicalStateEquivalent: true,
            claims: .init(
                mechanismMeasurement: true,
                endToEndStorePerformance: false,
                physicalIOBytes: false,
                physicalDevice: false,
                powerLoss: false,
                productionFormat: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func checkpointResourceArguments(
        _ arguments: [String]
    ) throws -> (root: URL, mode: String, historyEntries: Int, barrier: SegmentedCheckpointBarrier) {
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
            let mode = values["--mode"],
            mode == "current-full" || mode == "segmented-epoch",
            let historyText = values["--history"],
            let history = Int(historyText),
            history > 0,
            history + maximumRunRecords <= 100_000,
            let ready = values["--ready-fd"].flatMap(Int32.init),
            let go = values["--go-fd"].flatMap(Int32.init),
            let done = values["--done-fd"].flatMap(Int32.init),
            let release = values["--release-fd"].flatMap(Int32.init)
        else { throw SegmentedManifestShadowError.invalidArguments }
        return (
            URL(fileURLWithPath: root, isDirectory: true),
            mode,
            history,
            SegmentedCheckpointBarrier(
                readyFD: ready,
                goFD: go,
                doneFD: done,
                releaseFD: release
            )
        )
    }

    private static func checkpointShadowEntries(
        _ state: [String: SegmentedShadowEntry]
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

    private static func checkpointDecodeCurrentSnapshot(
        _ url: URL
    ) throws -> [String: SegmentedShadowEntry] {
        let data = try BoundedFileReader.read(from: url, maximumBytes: 64 * 1024 * 1024)
        let shadow = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(data)
        return shadow.mapValues { entry in
            SegmentedShadowEntry(
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: entry.digest,
                    partition: entry.partition
                ),
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }

    private static func checkpointHeadCount(generation: UInt64, heads: URL) throws -> Int {
        let names = try XattrShadowProbeIO.listAttributes(heads)
        return try names.reduce(into: Set<UInt8>()) { slots, name in
            if let identity = try DirectoryHeadIdentity.parse(name), identity.generation == generation {
                guard slots.insert(identity.slot).inserted else {
                    throw DirectoryHeadShadowError.invalidHead
                }
            }
        }.count
    }
}
