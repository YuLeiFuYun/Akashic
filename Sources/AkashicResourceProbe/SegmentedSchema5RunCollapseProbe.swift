import AkashicCore
import AkashicDisk
import Darwin
import Foundation

struct Schema5RunCollapseIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    var key: String {
        FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
    }
}

struct Schema5RunCollapseCaseReport: Codable {
    let name: String
    let inputRunCount: Int
    let expectedOutputRunCount: Int?
    let actualOutputRunCount: Int?
    let touchedKeyCount: Int?
    let finalUpsertCount: Int?
    let inputRunBytes: Int?
    let outputRunBytes: Int?
    let expectedSpeculativeAutomaticAdmission: Bool?
    let actualSpeculativeAutomaticAdmission: Bool?
    let rootChanged: Bool
    let segmentCountBefore: Int
    let segmentCountAfter: Int
    let authorityExactBeforeCollapse: Bool
    let authorityExactAfterCollapse: Bool
    let physicalOwnershipExactAfterCollapse: Bool
    let reopenExact: Bool
    let sampleReadable: Bool
}

struct Schema5RunCollapseReport: Codable {
    struct Claims: Codable {
        let productionPolicy: Bool
        let automaticScheduling: Bool
        let runOnlyTopologyCandidate: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let cases: [Schema5RunCollapseCaseReport]
    let allChecksPass: Bool
    let claims: Claims
}

enum Schema5RunCollapseCrashPoint: String, CaseIterable {
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

    var expectedRunCountAfterRecovery: Int {
        switch self {
        case .manifestDataWritten, .manifestFileSynced: 16
        case .manifestRenamed, .manifestDirectorySynced: 2
        }
    }
}

struct Schema5RunCollapseCrashSeedReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let runCount: Int
    let entryCount: Int
    let segmentFileCount: Int
    let identityCommitment: String
}

struct Schema5RunCollapseCrashRecoverReport: Codable {
    let schemaVersion: Int
    let point: String
    let expectedRunCount: Int
    let actualRunCount: Int
    let generation: UInt64
    let entryCount: Int
    let identityCommitment: String
    let segmentFileCount: Int
    let segmentSetExactlyReferenced: Bool
    let blobSetExactlyAuthoritative: Bool
    let sampleReadable: Bool
    let followupCommitSucceeded: Bool
    let followupReopenExact: Bool
    let followupReadableAfterReopen: Bool
}

struct Schema5RunCollapseResourceReport: Codable {
    struct Claims: Codable {
        let mechanismMeasurement: Bool
        let formalPerformance: Bool
        let endToEndStorePerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let energy: Bool
        let powerLoss: Bool
        let automaticScheduling: Bool
    }

    let schemaVersion: Int
    let method: String
    let liveEntries: Int
    let inputRunCount: Int
    let inputRunRecords: Int
    let frozenBaseBytes: Int
    let frozenRunBytes: Int
    let maintenanceElapsedNanoseconds: UInt64
    let published: Bool
    let collapseTouchedKeyCount: Int?
    let collapseFinalUpsertCount: Int?
    let collapseOutputRunBytes: Int?
    let finalRunCount: Int
    let finalBaseBytes: Int
    let finalSegmentFileCount: Int
    let segmentSetExactlyReferenced: Bool
    let authorityExact: Bool
    let freshReopenExact: Bool
    let identityCommitmentBefore: String
    let identityCommitmentAfter: String
    let claims: Claims
}
extension SegmentedManifestShadowProbe {
    static func schema5RunCollapse(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let rows = try await [
            schema5RunCollapseHotCase(
                root: root.appendingPathComponent("hot-16x512", isDirectory: true)
            ),
            schema5RunCollapseWide64x32Case(
                root: root.appendingPathComponent("wide-64x32", isDirectory: true)
            ),
            schema5RunCollapseWide48x32Case(
                root: root.appendingPathComponent("wide-48x32", isDirectory: true)
            ),
            schema5RunCollapseDisjointRejectCase(
                root: root.appendingPathComponent("disjoint-4x512-reject", isDirectory: true)
            ),
            schema5RunCollapsePhysicalTransferCase(
                root: root.appendingPathComponent("physical-transfer", isDirectory: true)
            ),
        ]
        let all = rows.allSatisfy { row in
            row.authorityExactBeforeCollapse
                && row.authorityExactAfterCollapse
                && row.physicalOwnershipExactAfterCollapse
                && row.reopenExact
                && row.sampleReadable
                && row.actualOutputRunCount == row.expectedOutputRunCount
                && row.actualSpeculativeAutomaticAdmission
                    == row.expectedSpeculativeAutomaticAdmission
                && (row.expectedOutputRunCount == nil ? !row.rootChanged : row.rootChanged)
        }
        let report = Schema5RunCollapseReport(
            schemaVersion: 2,
            cases: rows,
            allChecksPass: all,
            claims: .init(
                productionPolicy: false,
                automaticScheduling: false,
                runOnlyTopologyCandidate: true,
                formalLatency: false,
                physicalDeviceIO: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5RunCollapseHotCase(root: URL) async throws
        -> Schema5RunCollapseCaseReport
    {
        let identities = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-hot-v1",
            count: 512
        )
        let baseline = try await schema5RunCollapsePrepareV3Base(root: root, identities: identities)
        let runs = try schema5RunCollapseHotRuns(identities: identities, baseline: baseline)
        _ = try schema5RunCollapseInstallRuns(root: root, runs: runs)
        return try await schema5RunCollapseExecuteCase(
            name: "hot-16x512",
            root: root,
            expectedBefore: baseline.entries,
            sample: identities[0],
            expectedInputRuns: 16,
            expectedOutputRuns: 2,
            expectedSpeculativeAutomaticAdmission: true
        )
    }

    static func schema5RunCollapseCrashSeed(arguments: [String]) async throws {
        let root = try schema5RunCollapseCrashRoot(arguments)
        let identities = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-crash-v1",
            count: 512
        )
        let baseline = try await schema5RunCollapsePrepareV3Base(root: root, identities: identities)
        let runs = try schema5RunCollapseHotRuns(identities: identities, baseline: baseline)
        let installed = try schema5RunCollapseInstallRuns(root: root, runs: runs)
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let names = try schema5RunCollapseSegmentNames(root)
        guard installed.runs.count == 16,
            snapshot.entries == baseline.entries,
            Set(names) == Set([installed.base.fileName] + installed.runs.map(\.fileName))
        else { throw SegmentedManifestShadowError.invariantViolation }
        try schema5RunCollapseWriteJSON(
            Schema5RunCollapseCrashSeedReport(
                schemaVersion: 1,
                generation: installed.generation,
                runCount: installed.runs.count,
                entryCount: snapshot.entries.count,
                segmentFileCount: names.count,
                identityCommitment: try schema5IdentityCommitment(snapshot.entries)
            )
        )
        store = nil
    }

    static func schema5RunCollapseCrash(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = Schema5RunCollapseCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            faultInjector: { observed in
                if observed == point.switchPoint { Darwin._exit(91) }
            }
        )
        _ = try await store.resourceProbeCollapseSegmentedRunsV3()
        Darwin._exit(92)
    }

    static func schema5RunCollapseCrashRecover(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--point",
            let point = Schema5RunCollapseCrashPoint(rawValue: arguments[3])
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let identities = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-crash-v1",
            count: 512
        )
        let sample = identities[0]
        let followup = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-crash-followup-v1",
            count: 1
        )[0]

        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let rootBefore = try schema5RunCollapseReadRoot(root)
        let segmentNames = try schema5RunCollapseSegmentNames(root)
        let referencedNames = Set([rootBefore.base.fileName] + rootBefore.runs.map(\.fileName))
        let blobNames = try schema5RunCollapseBlobNames(root)
        let authoritativeBlobNames = Set(
            before.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
        )
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data

        _ = try await store!.commit(
            data: followup.data,
            digest: followup.digest,
            partition: followup.partition
        )
        let afterFollowup = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let followupRead = try await store!.read(
            digest: followup.digest,
            partition: followup.partition
        )

        try schema5RunCollapseWriteJSON(
            Schema5RunCollapseCrashRecoverReport(
                schemaVersion: 1,
                point: point.rawValue,
                expectedRunCount: point.expectedRunCountAfterRecovery,
                actualRunCount: rootBefore.runs.count,
                generation: rootBefore.generation,
                entryCount: before.entries.count,
                identityCommitment: try schema5IdentityCommitment(before.entries),
                segmentFileCount: segmentNames.count,
                segmentSetExactlyReferenced: Set(segmentNames) == referencedNames
                    && segmentNames.count == referencedNames.count,
                blobSetExactlyAuthoritative: Set(blobNames) == authoritativeBlobNames
                    && blobNames.count == authoritativeBlobNames.count,
                sampleReadable: sampleReadable,
                followupCommitSucceeded: afterFollowup.entries[followup.key] != nil,
                followupReopenExact: reopened.entries == afterFollowup.entries,
                followupReadableAfterReopen: followupRead == followup.data
            )
        )
        store = nil
    }

    static func schema5RunCollapseResource(arguments: [String]) async throws {
        let parsed = try schema5RunCollapseResourceArguments(arguments)
        var seeded: Schema5CompactionResourceSeedResult? = try await schema5CompactionResourceSeed(
            root: parsed.root,
            profile: .v3CompactBinary,
            liveCount: parsed.liveEntries,
            runCount: 16,
            recordsPerRun: 512,
            history: "hot"
        )
        var store: FileBlobStore? = seeded!.store
        let frozenRoot = seeded!.root
        let frozenBaseBytes = seeded!.baseBytes
        let frozenRunBytes = seeded!.runBytes
        let inputRunRecords = seeded!.replayRecords
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        guard frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            frozenRoot.runs.count == 16,
            beforeCommitment == seeded!.expectedCommitment
        else { throw SegmentedManifestShadowError.invariantViolation }
        seeded = nil

        try parsed.barrier.enter()
        let started = DispatchTime.now().uptimeNanoseconds
        let published: Bool
        let collapseResult: FileBlobStoreSegmentedRunCollapseResult?
        do {
            switch parsed.method {
            case "collapse":
                collapseResult = try await store!.resourceProbeCollapseSegmentedRunsV3()
                published = collapseResult != nil
            case "full":
                collapseResult = nil
                published = try await store!.resourceProbeCompactSegmentedManifestV3()
            default:
                throw SegmentedManifestShadowError.invalidArguments
            }
        } catch {
            try? parsed.barrier.leave()
            throw error
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        try parsed.barrier.leave()

        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterCommitment = try schema5IdentityCommitment(after.entries)
        let finalRoot = try schema5RunCollapseReadRoot(parsed.root)
        let finalNames = try schema5RunCollapseSegmentNames(parsed.root)
        let referenced = Set([finalRoot.base.fileName] + finalRoot.runs.map(\.fileName))
        let segmentSetExact = Set(finalNames) == referenced && finalNames.count == referenced.count
        let authorityExact = after.entries == before.entries && afterCommitment == beforeCommitment
        store = nil

        let limits = FileBlobStoreLimits(
            softTotalBytes: 256 * 1024 * 1024,
            maximumBlobBytes: 64 * 1024 * 1024,
            maximumDirectoryEntryCount: 201_024
        )
        store = try await FileBlobStore.openSegmentedV3Candidate(root: parsed.root, limits: limits)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5RunCollapseReadRoot(parsed.root)
        let freshReopenExact = reopened.entries == after.entries && reopenedRoot == finalRoot
        store = nil

        let report = Schema5RunCollapseResourceReport(
            schemaVersion: 1,
            method: parsed.method,
            liveEntries: parsed.liveEntries,
            inputRunCount: frozenRoot.runs.count,
            inputRunRecords: inputRunRecords,
            frozenBaseBytes: frozenBaseBytes,
            frozenRunBytes: frozenRunBytes,
            maintenanceElapsedNanoseconds: elapsed,
            published: published,
            collapseTouchedKeyCount: collapseResult?.touchedKeyCount,
            collapseFinalUpsertCount: collapseResult?.finalUpsertCount,
            collapseOutputRunBytes: collapseResult?.outputRunBytes,
            finalRunCount: finalRoot.runs.count,
            finalBaseBytes: finalRoot.base.byteCount,
            finalSegmentFileCount: finalNames.count,
            segmentSetExactlyReferenced: segmentSetExact,
            authorityExact: authorityExact,
            freshReopenExact: freshReopenExact,
            identityCommitmentBefore: beforeCommitment,
            identityCommitmentAfter: afterCommitment,
            claims: .init(
                mechanismMeasurement: true,
                formalPerformance: false,
                endToEndStorePerformance: false,
                physicalIOBytes: false,
                physicalDevice: false,
                energy: false,
                powerLoss: false,
                automaticScheduling: false
            )
        )
        try schema5RunCollapseWriteJSON(report)
        guard published,
            authorityExact,
            freshReopenExact,
            segmentSetExact,
            (parsed.method != "collapse" || finalRoot.runs.count == 2),
            (parsed.method != "full" || finalRoot.runs.isEmpty)
        else { throw SegmentedManifestShadowError.invariantViolation }
    }
}
