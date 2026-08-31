import AkashicCore
import AkashicDisk
import Darwin
import Foundation

enum Schema5StablePrefixCrashPoint: String, CaseIterable {
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
        case .manifestDataWritten, .manifestFileSynced: 50
        case .manifestRenamed, .manifestDirectorySynced: 4
        }
    }
}

enum Schema5StablePrefixMaterializationCrashPoint: String, CaseIterable {
    case planning = "planning"
    case beforeFirstOutput = "before-first-output"
    case afterFirstOutput = "after-first-output"
    case afterAllOutputs = "after-all-outputs"
    case preparedCandidate = "prepared-candidate"

    var expectedUnreferencedOutputsBeforeReopen: Int {
        switch self {
        case .planning, .beforeFirstOutput: 0
        case .afterFirstOutput: 1
        case .afterAllOutputs, .preparedCandidate: 2
        }
    }
}

final class Schema5StablePrefixCrashArm: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func shouldCrash(_ point: FileBlobStoreSwitchPoint, target: FileBlobStoreSwitchPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed && point == target
    }
}

struct Schema5StablePrefixCrashIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    let key: String
}

struct Schema5StablePrefixCrashSeedReport: Codable {
    let point: String
    let identityCommitment: String
    let generation: UInt64
    let oldRunCount: Int
    let newRunCount: Int
    let preparedPrefixRunCount: Int
    let preparedReplacementRunCount: Int
    let suffixRunCount: Int
    let entryCount: Int
    let sampleKey: String
    let samplePhysicalID: String
}

struct Schema5StablePrefixCrashInspectReport: Codable {
    let point: String
    let expectedRunCount: Int
    let actualRunCount: Int
    let generation: UInt64
    let entryCount: Int
    let identityCommitment: String
    let identityCommitmentExact: Bool
    let samplePhysicalIDExact: Bool
    let sampleReadable: Bool
    let segmentSetExactlyReferenced: Bool
    let blobSetExactlyAuthoritative: Bool
}

struct Schema5StablePrefixMaterializationCrashSeedReport: Codable {
    let point: String
    let identityCommitment: String
    let generation: UInt64
    let oldRunCount: Int
    let expectedUnreferencedOutputsBeforeReopen: Int
    let entryCount: Int
    let sampleKey: String
    let samplePhysicalID: String
}

struct Schema5StablePrefixMaterializationCrashInspectReport: Codable {
    let point: String
    let rawRunCountBeforeReopen: Int
    let rawUnreferencedOutputCountBeforeReopen: Int
    let expectedUnreferencedOutputCountBeforeReopen: Int
    let recoveredRunCount: Int
    let generation: UInt64
    let entryCount: Int
    let identityCommitmentExact: Bool
    let samplePhysicalIDExact: Bool
    let sampleReadable: Bool
    let segmentSetExactlyReferencedAfterReopen: Bool
    let blobSetExactlyAuthoritative: Bool
}

enum Schema5StablePrefixCrashError: Error {
    case invalidArguments
    case writerLeaseDidNotRelease
    case crashPointNotReached
}
enum SegmentedSchema5StablePrefixCollapseCrashProbe {
    static func materializationCrash(arguments: [String]) async throws {
        let parsed = try parseMaterializationCrash(arguments)
        try? FileManager.default.removeItem(at: parsed.root)
        let identities = try await prepareV4Root(root: parsed.root, runCount: 48)
        var store: FileBlobStore? = try await openV4(parsed.root, faultInjector: { _ in })
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let root = try readRoot(parsed.root)
        guard root.runs.count == 48,
            let sample = identities.first,
            let sampleEntry = snapshot.entries[sample.key]
        else { throw AkashicError.invalidManifest }

        let seed = Schema5StablePrefixMaterializationCrashSeedReport(
            point: parsed.point.rawValue,
            identityCommitment: try identityCommitment(snapshot.entries),
            generation: root.generation,
            oldRunCount: root.runs.count,
            expectedUnreferencedOutputsBeforeReopen:
                parsed.point.expectedUnreferencedOutputsBeforeReopen,
            entryCount: snapshot.entries.count,
            sampleKey: sample.key,
            samplePhysicalID: sampleEntry.physicalID.rawValue.uuidString.lowercased()
        )
        try writeJSON(seed, to: parsed.seedReport)

        let crashObserver: FileBlobStoreSegmentedCompactionPreparationObserver = {
            Darwin._exit(91)
        }
        let preparationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? =
            parsed.point == .planning ? crashObserver : nil
        let materializationObserver: FileBlobStoreSegmentedCompactionPreparationObserver? =
            parsed.point == .beforeFirstOutput ? crashObserver : nil
        let progressObserver: FileBlobStoreSegmentedRunPrefixMaterializationProgressObserver? =
            switch parsed.point {
            case .afterFirstOutput:
                { completed, _ in
                    if completed == 1 { Darwin._exit(91) }
                }
            case .afterAllOutputs:
                { completed, total in
                    if completed == total { Darwin._exit(91) }
                }
            default:
                nil
            }

        let prepared = try await store!.resourceProbePrepareSegmentedRunPrefixCollapseV4(
            prefixRunCount: 48,
            preparationObserver: preparationObserver,
            materializationObserver: materializationObserver,
            materializationProgressObserver: progressObserver
        )
        guard let prepared, prepared.replacementRunCount == 2 else {
            throw AkashicError.limitExceeded
        }
        if parsed.point == .preparedCandidate { Darwin._exit(91) }
        store = nil
        throw Schema5StablePrefixCrashError.crashPointNotReached
    }

    static func materializationInspect(arguments: [String]) async throws {
        let parsed = try parseMaterializationInspect(arguments)
        let seed = try JSONDecoder().decode(
            Schema5StablePrefixMaterializationCrashSeedReport.self,
            from: Data(contentsOf: parsed.seedReport)
        )
        guard Schema5StablePrefixMaterializationCrashPoint(rawValue: seed.point) != nil else {
            throw Schema5StablePrefixCrashError.invalidArguments
        }

        let rawRoot = try readRoot(parsed.root)
        let segmentDirectory = parsed.root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let rawSegmentNames = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let rawReferencedNames = Set([rawRoot.base.fileName] + rawRoot.runs.map(\.fileName))
        let rawUnreferencedOutputCount = Set(rawSegmentNames)
            .subtracting(rawReferencedNames)
            .count

        var store: FileBlobStore? = try await openV4(parsed.root, faultInjector: { _ in })
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let recoveredRoot = try readRoot(parsed.root)
        let commitment = try identityCommitment(snapshot.entries)
        let sample = try makeMaterializationSampleIdentity(seed: seed, snapshot: snapshot)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data

        let recoveredSegmentNames = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let recoveredReferencedNames = Set(
            [recoveredRoot.base.fileName] + recoveredRoot.runs.map(\.fileName)
        )
        let blobDirectory = parsed.root.appendingPathComponent("blobs", isDirectory: true)
        let blobNames = try BoundedDirectoryReader.names(
            in: blobDirectory,
            maximumCount: 4_096
        ).filter { UUID(uuidString: $0) != nil }
        let authoritativeBlobNames = Set(
            snapshot.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
        )

        let report = Schema5StablePrefixMaterializationCrashInspectReport(
            point: seed.point,
            rawRunCountBeforeReopen: rawRoot.runs.count,
            rawUnreferencedOutputCountBeforeReopen: rawUnreferencedOutputCount,
            expectedUnreferencedOutputCountBeforeReopen:
                seed.expectedUnreferencedOutputsBeforeReopen,
            recoveredRunCount: recoveredRoot.runs.count,
            generation: recoveredRoot.generation,
            entryCount: snapshot.entries.count,
            identityCommitmentExact: commitment == seed.identityCommitment,
            samplePhysicalIDExact:
                snapshot.entries[seed.sampleKey]?.physicalID.rawValue.uuidString.lowercased()
                    == seed.samplePhysicalID,
            sampleReadable: sampleReadable,
            segmentSetExactlyReferencedAfterReopen:
                Set(recoveredSegmentNames) == recoveredReferencedNames
                    && recoveredSegmentNames.count == recoveredReferencedNames.count,
            blobSetExactlyAuthoritative:
                Set(blobNames) == authoritativeBlobNames
                    && blobNames.count == authoritativeBlobNames.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        store = nil

        guard rawRoot.runs.count == seed.oldRunCount,
            rawRoot.generation == seed.generation,
            rawUnreferencedOutputCount == seed.expectedUnreferencedOutputsBeforeReopen,
            recoveredRoot.runs.count == seed.oldRunCount,
            recoveredRoot.generation == seed.generation,
            snapshot.entries.count == seed.entryCount,
            report.identityCommitmentExact,
            report.samplePhysicalIDExact,
            report.sampleReadable,
            report.segmentSetExactlyReferencedAfterReopen,
            report.blobSetExactlyAuthoritative
        else { throw AkashicError.storageUnavailable }
    }

    static func crash(arguments: [String]) async throws {
        let parsed = try parseCrash(arguments)
        try? FileManager.default.removeItem(at: parsed.root)
        let identities = try await prepareV4Root(root: parsed.root, runCount: 48)
        let arm = Schema5StablePrefixCrashArm()
        var store: FileBlobStore? = try await openV4(
            parsed.root,
            faultInjector: { observed in
                if arm.shouldCrash(observed, target: parsed.point.switchPoint) {
                    Darwin._exit(91)
                }
            }
        )
        let prepared = try await store!.resourceProbePrepareSegmentedRunPrefixCollapseV4(
            prefixRunCount: 48
        )
        guard let prepared, prepared.replacementRunCount == 2 else {
            throw AkashicError.limitExceeded
        }

        try await republishEpoch(store: store!, identities: identities, epoch: 0)
        try await republishEpoch(store: store!, identities: identities, epoch: 1)
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let root = try readRoot(parsed.root)
        guard root.runs.count == 50, root.generation >= 3 else {
            throw AkashicError.invalidManifest
        }
        guard let sample = identities.first else { throw AkashicError.invalidManifest }
        guard let sampleEntry = before.entries[sample.key] else {
            throw AkashicError.invalidManifest
        }
        let seed = Schema5StablePrefixCrashSeedReport(
            point: parsed.point.rawValue,
            identityCommitment: try identityCommitment(before.entries),
            generation: root.generation,
            oldRunCount: root.runs.count,
            newRunCount: prepared.replacementRunCount + 2,
            preparedPrefixRunCount: prepared.sourcePrefixRunCount,
            preparedReplacementRunCount: prepared.replacementRunCount,
            suffixRunCount: 2,
            entryCount: before.entries.count,
            sampleKey: sample.key,
            samplePhysicalID: sampleEntry.physicalID.rawValue.uuidString.lowercased()
        )
        try writeJSON(seed, to: parsed.seedReport)

        arm.arm()
        _ = try await store!.resourceProbeAdoptSegmentedRunPrefixCollapseV4()
        store = nil
        throw Schema5StablePrefixCrashError.crashPointNotReached
    }

    static func inspect(arguments: [String]) async throws {
        let parsed = try parseInspect(arguments)
        let seed = try JSONDecoder().decode(
            Schema5StablePrefixCrashSeedReport.self,
            from: Data(contentsOf: parsed.seedReport)
        )
        guard let point = Schema5StablePrefixCrashPoint(rawValue: seed.point) else {
            throw Schema5StablePrefixCrashError.invalidArguments
        }
        var store: FileBlobStore? = try await openV4(parsed.root, faultInjector: { _ in })
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        let root = try readRoot(parsed.root)
        let commitment = try identityCommitment(snapshot.entries)
        let sample = try makeSampleIdentity(seed: seed, snapshot: snapshot)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data

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
        let expectedRuns = point.expectedRunCountAfterRecovery
        let report = Schema5StablePrefixCrashInspectReport(
            point: seed.point,
            expectedRunCount: expectedRuns,
            actualRunCount: root.runs.count,
            generation: root.generation,
            entryCount: snapshot.entries.count,
            identityCommitment: commitment,
            identityCommitmentExact: commitment == seed.identityCommitment,
            samplePhysicalIDExact: snapshot.entries[seed.sampleKey]?.physicalID.rawValue.uuidString.lowercased()
                == seed.samplePhysicalID,
            sampleReadable: sampleReadable,
            segmentSetExactlyReferenced: Set(segmentNames) == referencedNames
                && segmentNames.count == referencedNames.count,
            blobSetExactlyAuthoritative: Set(blobNames) == authoritativeBlobNames
                && blobNames.count == authoritativeBlobNames.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        store = nil
        guard root.runs.count == expectedRuns,
            root.generation == seed.generation,
            snapshot.entries.count == seed.entryCount,
            report.identityCommitmentExact,
            report.samplePhysicalIDExact,
            report.sampleReadable,
            report.segmentSetExactlyReferenced,
            report.blobSetExactlyAuthoritative
        else { throw AkashicError.storageUnavailable }
    }
}
