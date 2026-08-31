import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Foundation

private enum Schema5RunCapacityRescueCrashPhase: String {
    case compaction
    case collapse
    case checkpoint

    var occurrence: Int {
        switch self {
        case .compaction, .collapse: 1
        case .checkpoint: 2
        }
    }
}

private enum Schema5RunCapacityRescueCrashPoint: String {
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

    var isPostRename: Bool {
        switch self {
        case .manifestDataWritten, .manifestFileSynced: false
        case .manifestRenamed, .manifestDirectorySynced: true
        }
    }
}

private final class Schema5RunCapacityCrashOccurrence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func shouldCrash(
        observed: FileBlobStoreSwitchPoint,
        matching point: FileBlobStoreSwitchPoint,
        occurrence: Int
    ) -> Bool {
        guard observed == point else { return false }
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == occurrence
    }
}

private struct Schema5RunCapacityRescueCrashSeedReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let activeDistinctKeys: Int
    let entryCount: Int
    let priorIdentityCommitment: String
    let priorLogicalCommitment: String
    let targetLogicalCommitment: String
}

private struct Schema5RunCapacityRescueCrashRecoverReport: Codable {
    let schemaVersion: Int
    let generationBeforeFollowup: UInt64
    let runCountBeforeFollowup: Int
    let activeDistinctKeysBeforeFollowup: Int
    let entryCountBeforeFollowup: Int
    let segmentFileCountBeforeFollowup: Int
    let blobFileCountBeforeFollowup: Int
    let profileBeforeFollowup: String
    let baseKindBeforeFollowup: String
    let priorIdentityCommitment: String
    let logicalCommitmentBeforeFollowup: String
    let targetPresentBeforeFollowup: Bool
    let targetReadableBeforeFollowup: Bool
    let segmentSetExactlyReferencedBeforeFollowup: Bool
    let blobSetExactlyAuthoritativeBeforeFollowup: Bool
    let followupCommitSucceeded: Bool
    let followupReopenExact: Bool
    let followupReadableAfterReopen: Bool
}

extension SegmentedManifestShadowProbe {
    static func schema5RunCapacityRescueCrashSeed(arguments: [String]) async throws {
        let root = try schema5RunCapacityCrashRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        let identities = try schema5RunCapacityHotIdentities()
        var store: FileBlobStore? = try await schema5RunCapacitySeed(
            root: root,
            policy: .synchronousV3CompactionAtHardLimit
        )
        for identity in identities.prefix(511) {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let rootValue = try schema5RunCapacityReadRoot(root)
        guard rootValue.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors,
            head.distinctKeyCount == 511,
            snapshot.entries.count == 511
        else { throw SegmentedManifestShadowError.invariantViolation }

        let target = identities[511]
        let priorLogical = try schema5RunCapacityLogicalCommitment(snapshot.entries)
        let targetLogical = try schema5RunCapacityLogicalCommitment(
            snapshot.entries,
            adding: target
        )
        try schema5RunCapacityCrashWriteJSON(
            Schema5RunCapacityRescueCrashSeedReport(
                schemaVersion: 1,
                generation: rootValue.generation,
                runCount: rootValue.runs.count,
                activeDistinctKeys: head.distinctKeyCount,
                entryCount: snapshot.entries.count,
                priorIdentityCommitment: try schema5IdentityCommitment(snapshot.entries),
                priorLogicalCommitment: priorLogical,
                targetLogicalCommitment: targetLogical
            )
        )
        store = nil
    }

    static func schema5RunCapacityRescueCrash(arguments: [String]) async throws {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--phase",
            let phase = Schema5RunCapacityRescueCrashPhase(rawValue: arguments[3]),
            phase != .collapse,
            arguments[4] == "--point",
            let point = Schema5RunCapacityRescueCrashPoint(rawValue: arguments[5])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let counter = Schema5RunCapacityCrashOccurrence()
        let store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            faultInjector: { observed in
                if counter.shouldCrash(
                    observed: observed,
                    matching: point.switchPoint,
                    occurrence: phase.occurrence
                ) {
                    Darwin._exit(91)
                }
            },
            runCapacityPolicy: .synchronousV3CompactionAtHardLimit
        )
        let target = try schema5RunCapacityHotIdentities()[511]
        _ = try await store.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        Darwin._exit(92)
    }

    static func schema5RunCapacityCollapseCrash(arguments: [String]) async throws {
        guard arguments.count == 6,
            arguments[0] == "--root",
            arguments[2] == "--phase",
            let phase = Schema5RunCapacityRescueCrashPhase(rawValue: arguments[3]),
            phase != .compaction,
            arguments[4] == "--point",
            let point = Schema5RunCapacityRescueCrashPoint(rawValue: arguments[5])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let counter = Schema5RunCapacityCrashOccurrence()
        let store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            faultInjector: { observed in
                if counter.shouldCrash(
                    observed: observed,
                    matching: point.switchPoint,
                    occurrence: phase.occurrence
                ) {
                    Darwin._exit(91)
                }
            },
            runCapacityPolicy: .synchronousV3RunCollapseThenCompactionAtHardLimit
        )
        let target = try schema5RunCapacityHotIdentities()[511]
        _ = try await store.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        Darwin._exit(92)
    }

    static func schema5RunCapacityRescueCrashRecover(arguments: [String]) async throws {
        try await schema5RunCapacityCrashRecover(
            arguments: arguments,
            policy: .synchronousV3CompactionAtHardLimit
        )
    }

    static func schema5RunCapacityCollapseCrashRecover(arguments: [String]) async throws {
        try await schema5RunCapacityCrashRecover(
            arguments: arguments,
            policy: .synchronousV3RunCollapseThenCompactionAtHardLimit
        )
    }

    private static func schema5RunCapacityCrashRecover(
        arguments: [String],
        policy: FileBlobStoreSegmentedRunCapacityPolicy
    ) async throws {
        let root = try schema5RunCapacityCrashRoot(arguments)
        let identities = try schema5RunCapacityHotIdentities()
        let target = identities[511]
        let followup = try schema5MigrationIdentities(labels: ["run-cap-rescue-followup"])[0]

        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            runCapacityPolicy: policy
        )
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let headBefore = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let rootBefore = try schema5RunCapacityReadRoot(root)
        let segmentNames = try schema5RunCapacitySegmentNames(root)
        let referencedSegmentNames = Set(
            [rootBefore.base.fileName] + rootBefore.runs.map(\.fileName)
        )
        let blobNames = try schema5RunCapacityBlobNames(root)
        let authoritativeBlobNames = Set(
            before.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
        )
        let priorEntries = before.entries.filter { $0.key != target.key }
        let targetPresent = before.entries[target.key] != nil
        let targetReadable: Bool
        if targetPresent {
            targetReadable = try await store!.read(
                digest: target.digest,
                partition: target.partition
            ) == target.data
        } else {
            targetReadable = false
        }

        _ = try await store!.commit(
            data: followup.data,
            digest: followup.digest,
            partition: followup.partition
        )
        let afterFollowup = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            runCapacityPolicy: policy
        )
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let followupRead = try await store!.read(
            digest: followup.digest,
            partition: followup.partition
        )
        let report = Schema5RunCapacityRescueCrashRecoverReport(
            schemaVersion: 1,
            generationBeforeFollowup: rootBefore.generation,
            runCountBeforeFollowup: rootBefore.runs.count,
            activeDistinctKeysBeforeFollowup: headBefore.distinctKeyCount,
            entryCountBeforeFollowup: before.entries.count,
            segmentFileCountBeforeFollowup: segmentNames.count,
            blobFileCountBeforeFollowup: blobNames.count,
            profileBeforeFollowup: rootBefore.profile,
            baseKindBeforeFollowup: rootBefore.base.kind.rawValue,
            priorIdentityCommitment: try schema5IdentityCommitment(priorEntries),
            logicalCommitmentBeforeFollowup: try schema5RunCapacityLogicalCommitment(before.entries),
            targetPresentBeforeFollowup: targetPresent,
            targetReadableBeforeFollowup: targetReadable,
            segmentSetExactlyReferencedBeforeFollowup: Set(segmentNames) == referencedSegmentNames
                && segmentNames.count == referencedSegmentNames.count,
            blobSetExactlyAuthoritativeBeforeFollowup: Set(blobNames) == authoritativeBlobNames
                && blobNames.count == authoritativeBlobNames.count,
            followupCommitSucceeded: afterFollowup.entries[followup.key] != nil,
            followupReopenExact: reopened.entries == afterFollowup.entries,
            followupReadableAfterReopen: followupRead == followup.data
        )
        try schema5RunCapacityCrashWriteJSON(report)
        store = nil
    }

    private static func schema5RunCapacityCrashRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func schema5RunCapacityBlobNames(_ root: URL) throws -> [String] {
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        return try BoundedDirectoryReader.names(
            in: blobs,
            maximumCount: 4_096
        ).filter { name in
            guard let uuid = UUID(uuidString: name) else { return false }
            return uuid.uuidString.lowercased() == name
        }.sorted()
    }

    private static func schema5RunCapacityLogicalCommitment(
        _ entries: [String: FileBlobStoreRecordShadowEntry],
        adding identity: MigrationIdentity? = nil
    ) throws -> String {
        struct LogicalValue {
            let partition: CachePartitionID
            let digest: BlobDigest
            let byteCount: Int
        }
        var logical = entries.mapValues {
            LogicalValue(partition: $0.partition, digest: $0.digest, byteCount: $0.byteCount)
        }
        if let identity {
            logical[identity.key] = LogicalValue(
                partition: identity.partition,
                digest: identity.digest,
                byteCount: identity.data.count
            )
        }
        var transcript = Data("AKASHIC-SCHEMA5-RUN-CAP-LOGICAL-V1\0".utf8)
        for (key, value) in logical.sorted(by: { $0.key < $1.key }) {
            let keyData = Data(key.utf8)
            schema5RunCapacityAppendLE(UInt32(keyData.count), to: &transcript)
            transcript.append(keyData)
            transcript.append(value.partition.canonicalBytes)
            transcript.append(value.digest.bytes)
            schema5RunCapacityAppendLE(UInt64(value.byteCount), to: &transcript)
        }
        return SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
    }

    private static func schema5RunCapacityAppendLE<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func schema5RunCapacityCrashWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
