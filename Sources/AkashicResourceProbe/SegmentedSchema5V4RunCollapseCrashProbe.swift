import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum Schema5V4RunCollapseCrashPoint: String, CaseIterable {
    case manifestDataWritten = "manifest-data-written"
    case manifestFileSynced = "manifest-file-synced"
    case manifestRenamed = "manifest-renamed"
    case manifestDirectorySynced = "manifest-directory-synced"

    var switchPoint: FileBlobStoreSwitchPoint {
        switch self {
        case .manifestDataWritten: .afterManifestDataWritten
        case .manifestFileSynced: .afterManifestFileSynced
        case .manifestRenamed: .afterManifestRenamed
        case .manifestDirectorySynced: .afterManifestDirectorySynced
        }
    }

    var expectedRunCount: Int {
        switch self {
        case .manifestDataWritten, .manifestFileSynced: 64
        case .manifestRenamed, .manifestDirectorySynced: 2
        }
    }
}

private struct Schema5V4RunCollapseIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    let key: String
    let physicalID: PhysicalBlobID
}

private struct Schema5V4RunCollapseSeedReport: Codable {
    let point: String
    let generation: UInt64
    let entryCount: Int
    let identityCommitment: String
    let oldRunCount: Int
    let newRunCount: Int
    let oldCompoundRunCount: Int
    let sampleKey: String
    let samplePhysicalID: String
}

private struct Schema5V4RunCollapseInspectReport: Codable {
    let point: String
    let generation: UInt64
    let runCount: Int
    let runKinds: [String]
    let entryCount: Int
    let identityCommitment: String
    let segmentSetExactlyReferenced: Bool
    let blobSetExactlyAuthoritative: Bool
    let samplePhysicalIDExact: Bool
    let sampleReadable: Bool
}

private enum Schema5V4RunCollapseCrashError: Error {
    case invalidArguments
    case writerLeaseDidNotRelease
    case crashPointNotReached
}

enum SegmentedSchema5V4RunCollapseCrashProbe {
    static func seed(arguments: [String]) async throws {
        let parsed = try parse(arguments)
        try? FileManager.default.removeItem(at: parsed.root)
        let identities = try await prepareMixedHardCapRoot(root: parsed.root)
        var store: FileBlobStore? = try await openV4(root: parsed.root, faultInjector: { _ in })
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let root = try readRoot(parsed.root)
        let sample = identities[0]
        guard root.profile == SegmentedManifestPrototypeV1.profileV4,
            root.runs.count == 64,
            root.runs.filter({ $0.kind == .compoundRunV1 }).count == 32,
            snapshot.entries.count == identities.count,
            snapshot.entries[sample.key]?.physicalID == sample.physicalID
        else { throw AkashicError.invalidManifest }
        try writeJSON(
            Schema5V4RunCollapseSeedReport(
                point: parsed.point.rawValue,
                generation: root.generation,
                entryCount: snapshot.entries.count,
                identityCommitment: try identityCommitment(snapshot.entries),
                oldRunCount: 64,
                newRunCount: 2,
                oldCompoundRunCount: 32,
                sampleKey: sample.key,
                samplePhysicalID: sample.physicalID.rawValue.uuidString.lowercased()
            ),
            to: parsed.report
        )
        store = nil
    }

    static func crash(arguments: [String]) async throws {
        let parsed = try parse(arguments)
        let store = try await openV4(
            root: parsed.root,
            faultInjector: { observed in
                if observed == parsed.point.switchPoint { Darwin._exit(91) }
            }
        )
        _ = try await store.resourceProbeCollapseSegmentedRunsV4()
        throw Schema5V4RunCollapseCrashError.crashPointNotReached
    }

    static func inspect(arguments: [String]) async throws {
        let parsed = try parse(arguments)
        let seed = try JSONDecoder().decode(
            Schema5V4RunCollapseSeedReport.self,
            from: Data(contentsOf: parsed.report)
        )
        var store: FileBlobStore? = try await openV4(root: parsed.root, faultInjector: { _ in })
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let root = try readRoot(parsed.root)
        let segmentDirectory = parsed.root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let segmentNames = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referencedNames = Set([root.base.fileName] + root.runs.map(\.fileName))
        let blobDirectory = parsed.root.appendingPathComponent("blobs", isDirectory: true)
        let blobNames = try BoundedDirectoryReader.names(
            in: blobDirectory,
            maximumCount: 4_096
        ).filter { UUID(uuidString: $0) != nil }
        let authoritativeBlobNames = Set(
            snapshot.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
        )
        let sample = try makeSampleIdentity(seed: seed, snapshot: snapshot)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        let report = Schema5V4RunCollapseInspectReport(
            point: seed.point,
            generation: root.generation,
            runCount: root.runs.count,
            runKinds: root.runs.map(\.kind.rawValue),
            entryCount: snapshot.entries.count,
            identityCommitment: try identityCommitment(snapshot.entries),
            segmentSetExactlyReferenced: Set(segmentNames) == referencedNames
                && segmentNames.count == referencedNames.count,
            blobSetExactlyAuthoritative: Set(blobNames) == authoritativeBlobNames
                && blobNames.count == authoritativeBlobNames.count,
            samplePhysicalIDExact: snapshot.entries[seed.sampleKey]?.physicalID.rawValue.uuidString.lowercased()
                == seed.samplePhysicalID,
            sampleReadable: sampleReadable
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        store = nil
    }

    private static func prepareMixedHardCapRoot(
        root: URL
    ) async throws -> [Schema5V4RunCollapseIdentity] {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        var identities: [Schema5V4RunCollapseIdentity] = []
        identities.reserveCapacity(512)
        for index in 0..<512 {
            let partition = try CachePartitionID.derive(
                domain: "schema5-v4-run-collapse-crash-v1",
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("payload-\(index)".utf8)
            let digest = BlobDigest.sha256(of: data)
            let publication = try await store!.commit(
                data: data,
                digest: digest,
                partition: partition
            )
            identities.append(
                .init(
                    partition: partition,
                    digest: digest,
                    data: data,
                    key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
                    physicalID: publication.physicalID
                )
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw AkashicError.storageUnavailable
        }
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
        try await waitForRelease(root)

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
        try await waitForRelease(root)

        let v4 = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let sample = identities[0]
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(64)
        for index in 0..<64 {
            let finalEntry = SegmentedManifestEntry(
                key: sample.key,
                physicalID: sample.physicalID,
                partition: sample.partition,
                digest: sample.digest,
                byteCount: sample.data.count,
                lastAccess: Date(timeIntervalSinceReferenceDate: 940_000_000 + Double(index * 2 + 1))
            )
            if index.isMultiple(of: 2) {
                runs.append(
                    try SegmentedManifestPrototypeV1.writeRun(
                        [.upsert(finalEntry)],
                        fileName: "run-g\(v4.generation)-\(UUID().uuidString.lowercased()).seg",
                        directory: migration.segmentDirectory
                    )
                )
            } else {
                let prefixEntry = SegmentedManifestEntry(
                    key: sample.key,
                    physicalID: sample.physicalID,
                    partition: sample.partition,
                    digest: sample.digest,
                    byteCount: sample.data.count,
                    lastAccess: finalEntry.lastAccess.addingTimeInterval(-1)
                )
                let data = try SegmentedManifestCompoundRunV1.encodeFinalized(
                    prefix: [.upsert(prefixEntry)],
                    tail: [.upsert(finalEntry)]
                )
                let name = "compound-hardcap-\(UUID().uuidString.lowercased()).cseg"
                try DurableFileWriter.writeReplacing(
                    data,
                    to: migration.segmentDirectory.appendingPathComponent(name, isDirectory: false)
                )
                runs.append(
                    try SegmentedManifestCompoundRunV1.finalizedDescriptor(fileName: name, data: data)
                )
            }
        }
        let hardRoot = try SegmentedManifestPrototypeV1.makeRootV4(
            generation: v4.generation,
            base: v4.base,
            runs: runs
        )
        _ = try SegmentedManifestPrototypeV1.recover(
            root: hardRoot,
            segmentDirectory: migration.segmentDirectory
        )
        try SegmentedManifestPrototypeV1.writeRoot(hardRoot, to: rootURL)
        return identities
    }

    private static func openV4(
        root: URL,
        faultInjector: @escaping FileBlobStoreFaultInjector
    ) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.openSegmentedV4Candidate(
                    root: root,
                    faultInjector: faultInjector,
                    runCapacityPolicy: .synchronousV4RunCollapseThenCompactionAtHardLimit
                )
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5V4RunCollapseCrashError.writerLeaseDidNotRelease
    }

    private static func waitForRelease(_ root: URL) async throws {
        for _ in 0..<250 {
            do {
                let probe = try await FileBlobStore.openSegmentedV3Candidate(root: root)
                _ = probe
                return
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.invalidManifest {
                return
            }
        }
        throw Schema5V4RunCollapseCrashError.writerLeaseDidNotRelease
    }

    private static func parse(
        _ arguments: [String]
    ) throws -> (root: URL, point: Schema5V4RunCollapseCrashPoint, report: URL) {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--point",
            arguments[4] == "--report",
            arguments[1].hasPrefix("/"),
            arguments[5].hasPrefix("/"),
            let point = Schema5V4RunCollapseCrashPoint(rawValue: arguments[3])
        else { throw Schema5V4RunCollapseCrashError.invalidArguments }
        return (
            URL(fileURLWithPath: arguments[1], isDirectory: true),
            point,
            URL(fileURLWithPath: arguments[5], isDirectory: false)
        )
    }

    private static func readRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
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

    private static func makeSampleIdentity(
        seed: Schema5V4RunCollapseSeedReport,
        snapshot: FileBlobStoreManifestShadowSnapshot
    ) throws -> (partition: CachePartitionID, digest: BlobDigest, data: Data) {
        guard let entry = snapshot.entries[seed.sampleKey] else {
            throw AkashicError.invalidManifest
        }
        let bytes = entry.digest.bytes
        // The deterministic seed payload is recovered by matching its digest rather than by
        // deriving business identity from the key.
        for index in 0..<512 {
            let data = Data("payload-\(index)".utf8)
            if BlobDigest.sha256(of: data).bytes == bytes {
                return (entry.partition, entry.digest, data)
            }
        }
        throw AkashicError.invalidManifest
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
