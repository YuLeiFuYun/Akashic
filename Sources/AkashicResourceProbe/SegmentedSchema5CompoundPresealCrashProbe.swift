import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum Schema5CompoundPresealCrashPoint: String, CaseIterable {
    case tailAppended = "tail-appended"
    case footerAppended = "footer-appended"
    case compoundFileSynced = "compound-file-synced"
    case manifestDataWritten = "manifest-data-written"
    case manifestFileSynced = "manifest-file-synced"
    case manifestRenamed = "manifest-renamed"
    case manifestDirectorySynced = "manifest-directory-synced"

    var finalizePoint: SegmentedManifestCompoundRunV1.FinalizeSwitchPoint? {
        switch self {
        case .tailAppended: .afterTailAppended
        case .footerAppended: .afterFooterAppended
        case .compoundFileSynced: .afterFileSynced
        case .manifestDataWritten, .manifestFileSynced, .manifestRenamed, .manifestDirectorySynced: nil
        }
    }

    var manifestPoint: FileBlobStoreSwitchPoint? {
        switch self {
        case .manifestDataWritten: .afterManifestDataWritten
        case .manifestFileSynced: .afterManifestFileSynced
        case .manifestRenamed: .afterManifestRenamed
        case .manifestDirectorySynced: .afterManifestDirectorySynced
        case .tailAppended, .footerAppended, .compoundFileSynced: nil
        }
    }
}

private struct Schema5CompoundCrashIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    var key: String { FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition) }
}

private struct Schema5CompoundCrashSeedReport: Codable {
    let point: String
    let oldIdentityCommitment: String
    let newIdentityCommitment: String
    let oldGeneration: UInt64
    let oldRunCount: Int
    let candidateFileName: String
    let boundaryKey: String
    let boundaryPhysicalID: String
    let entryCountBefore: Int
    let entryCountAfter: Int
}

private struct Schema5CompoundCrashInspectReport: Codable {
    let point: String
    let identityCommitment: String
    let generation: UInt64
    let runCount: Int
    let runKinds: [String]
    let activeDistinctKeys: Int
    let entryCount: Int
    let boundaryPresentInAuthority: Bool
    let boundaryPhysicalFileExists: Bool
    let candidateFileExists: Bool
    let segmentSetExact: Bool
}

private enum Schema5CompoundCrashError: Error {
    case invalidArguments
    case writerLeaseDidNotRelease
    case crashPointNotReached
}

enum SegmentedSchema5CompoundPresealCrashProbe {
    static func run(arguments: [String]) async throws {
        let parsed = try parseCrash(arguments)
        try? FileManager.default.removeItem(at: parsed.root)
        let identities = try makeIdentities(count: 512)
        try await seedV4(root: parsed.root, identities: identities)

        let targetManifestPoint = parsed.point.manifestPoint
        let store: FileBlobStore? = try await openV4(
            root: parsed.root,
            faultInjector: { point in
                if point == targetManifestPoint { Darwin._exit(91) }
            }
        )
        for (index, identity) in identities.prefix(480).enumerated() {
            try await store!.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(timeIntervalSinceReferenceDate: 920_000_000 + Double(index))
            )
        }
        let prepared = try await store!.resourceProbePrepareSegmentedCompoundPresealV4()
        for index in 480..<511 {
            let identity = identities[index]
            try await store!.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(timeIntervalSinceReferenceDate: 921_000_000 + Double(index))
            )
        }

        let boundary = identities[511]
        let before = await store!.resourceProbeManifestShadowSnapshot()
        guard let boundaryEntry = before.entries[boundary.key] else {
            throw AkashicError.invalidManifest
        }
        var planned = before.entries
        planned.removeValue(forKey: boundary.key)
        let currentRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: parsed.root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let seed = Schema5CompoundCrashSeedReport(
            point: parsed.point.rawValue,
            oldIdentityCommitment: try identityCommitment(before.entries),
            newIdentityCommitment: try identityCommitment(planned),
            oldGeneration: currentRoot.generation,
            oldRunCount: currentRoot.runs.count,
            candidateFileName: prepared.candidateFileName,
            boundaryKey: boundary.key,
            boundaryPhysicalID: boundaryEntry.physicalID.rawValue.uuidString.lowercased(),
            entryCountBefore: before.entries.count,
            entryCountAfter: planned.count
        )
        try writeJSON(seed, to: parsed.seedReport)

        let targetFinalizePoint = parsed.point.finalizePoint
        await store!.resourceProbeSetSegmentedCompoundFinalizeFaultInjector { point in
            if point == targetFinalizePoint { Darwin._exit(91) }
        }
        try await store!.remove(digest: boundary.digest, partition: boundary.partition)
        throw Schema5CompoundCrashError.crashPointNotReached
    }

    static func inspect(arguments: [String]) async throws {
        let parsed = try parseInspect(arguments)
        let seed = try JSONDecoder().decode(
            Schema5CompoundCrashSeedReport.self,
            from: Data(contentsOf: parsed.seedReport)
        )
        var store: FileBlobStore? = try await openV4(root: parsed.root, faultInjector: { _ in })
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let root = try SegmentedManifestPrototypeV1.readRoot(
            from: parsed.root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let segments = parsed.root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let names = try BoundedDirectoryReader.names(
            in: segments,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referenced = Set([root.base.fileName] + root.runs.map(\.fileName))
        let physicalURL = parsed.root
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(seed.boundaryPhysicalID, isDirectory: false)
        let candidateURL = segments.appendingPathComponent(seed.candidateFileName, isDirectory: false)
        let report = Schema5CompoundCrashInspectReport(
            point: seed.point,
            identityCommitment: try identityCommitment(snapshot.entries),
            generation: root.generation,
            runCount: root.runs.count,
            runKinds: root.runs.map(\.kind.rawValue),
            activeDistinctKeys: head.distinctKeyCount,
            entryCount: snapshot.entries.count,
            boundaryPresentInAuthority: snapshot.entries[seed.boundaryKey] != nil,
            boundaryPhysicalFileExists: FileManager.default.fileExists(atPath: physicalURL.path),
            candidateFileExists: FileManager.default.fileExists(atPath: candidateURL.path),
            segmentSetExact: Set(names) == referenced
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        store = nil
    }

    private static func seedV4(
        root: URL,
        identities: [Schema5CompoundCrashIdentity]
    ) async throws {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw AkashicError.storageUnavailable
        }
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
        try await waitForRelease(root: root)

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
        try await waitForRelease(root: root)
    }

    private static func openV4(
        root: URL,
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
        throw Schema5CompoundCrashError.writerLeaseDidNotRelease
    }

    private static func waitForRelease(root: URL) async throws {
        for _ in 0..<250 {
            do {
                let probe = try await FileBlobStore.openSegmentedV3Candidate(root: root)
                _ = probe
                return
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.invalidManifest {
                // V4 roots intentionally cannot be opened by the V3 seam. Reaching this error means
                // the writer lease was acquired and released, which is sufficient for the wait.
                return
            }
        }
        throw Schema5CompoundCrashError.writerLeaseDidNotRelease
    }

    private static func identityCommitment(
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
                    lastAccess: Date(timeIntervalSinceReferenceDate: 0)
                )
            )
        })
        return try SegmentedManifestPrototypeV1.semanticStateCommitment(canonical)
    }

    private static func makeIdentities(count: Int) throws -> [Schema5CompoundCrashIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-compound-preseal-crash-v1",
                material: Data("partition-\(index)".utf8)
            )
            var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 64)
            withUnsafeBytes(of: UInt64(index).littleEndian) { encoded in
                for offset in 0..<encoded.count { bytes[offset] = encoded[offset] }
            }
            let data = Data(bytes)
            return .init(
                partition: partition,
                digest: BlobDigest.sha256(of: data),
                data: data
            )
        }
    }

    private static func parseCrash(
        _ arguments: [String]
    ) throws -> (root: URL, point: Schema5CompoundPresealCrashPoint, seedReport: URL) {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--point",
            arguments[4] == "--seed-report",
            arguments[1].hasPrefix("/"),
            arguments[5].hasPrefix("/"),
            let point = Schema5CompoundPresealCrashPoint(rawValue: arguments[3])
        else { throw Schema5CompoundCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            point,
            URL(fileURLWithPath: arguments[5], isDirectory: false)
        )
    }

    private static func parseInspect(
        _ arguments: [String]
    ) throws -> (root: URL, seedReport: URL) {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--seed-report",
            arguments[1].hasPrefix("/"),
            arguments[3].hasPrefix("/")
        else { throw Schema5CompoundCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            URL(fileURLWithPath: arguments[3], isDirectory: false)
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
