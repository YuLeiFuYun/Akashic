import AkashicCore
import AkashicDisk
import Foundation

extension SegmentedManifestShadowProbe {
    static func schema5RunCapacityRescue(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let control = try await schema5RunCapacityControlCase(
            root: root.appendingPathComponent("reject-control", isDirectory: true)
        )
        let rescue = try await schema5RunCapacityRescueCase(
            root: root.appendingPathComponent("sync-rescue", isDirectory: true),
            policy: .synchronousV3CompactionAtHardLimit
        )
        let collapseFirstRescue = try await schema5RunCapacityRescueCase(
            root: root.appendingPathComponent("collapse-first-rescue", isDirectory: true),
            policy: .synchronousV3RunCollapseThenCompactionAtHardLimit
        )
        let all = control.startingRunCount == SegmentedManifestPrototypeV1.maximumRunDescriptors
            && control.startingActiveDistinctKeys == 511
            && control.limitExceeded
            && control.rootUnchanged
            && control.segmentSetUnchanged
            && control.actorAuthorityUnchanged
            && control.targetAbsent
            && control.reopenExact
            && rescue.startingRunCount == SegmentedManifestPrototypeV1.maximumRunDescriptors
            && rescue.startingActiveDistinctKeys == 511
            && rescue.boundaryCommitSucceeded
            && rescue.generationDelta == 1
            && rescue.finalRunCount == 1
            && rescue.finalActiveDistinctKeys == 0
            && rescue.finalEntryCount == 512
            && rescue.finalProfile == SegmentedManifestPrototypeV1.profileV3
            && rescue.finalBaseKind == SegmentedManifestDescriptorV1.Kind.baseBinaryV2.rawValue
            && !rescue.baseDescriptorUnchanged
            && rescue.finalSegmentFileCount == 2
            && rescue.segmentSetExactlyReferenced
            && rescue.priorAuthorityPreserved
            && rescue.targetAuthorityExact
            && rescue.reopenExact
            && rescue.targetReadableAfterReopen
            && collapseFirstRescue.startingRunCount
                == SegmentedManifestPrototypeV1.maximumRunDescriptors
            && collapseFirstRescue.startingActiveDistinctKeys == 511
            && collapseFirstRescue.boundaryCommitSucceeded
            && collapseFirstRescue.generationDelta == 1
            && collapseFirstRescue.finalRunCount == 2
            && collapseFirstRescue.finalActiveDistinctKeys == 0
            && collapseFirstRescue.finalEntryCount == 512
            && collapseFirstRescue.finalProfile == SegmentedManifestPrototypeV1.profileV3
            && collapseFirstRescue.finalBaseKind
                == SegmentedManifestDescriptorV1.Kind.baseBinaryV2.rawValue
            && collapseFirstRescue.baseDescriptorUnchanged
            && collapseFirstRescue.finalSegmentFileCount == 3
            && collapseFirstRescue.segmentSetExactlyReferenced
            && collapseFirstRescue.priorAuthorityPreserved
            && collapseFirstRescue.targetAuthorityExact
            && collapseFirstRescue.reopenExact
            && collapseFirstRescue.targetReadableAfterReopen

        let report = Schema5RunCapacityRescueReport(
            schemaVersion: 2,
            maximumRunDescriptors: SegmentedManifestPrototypeV1.maximumRunDescriptors,
            maximumRecordsPerRun: SegmentedManifestPrototypeV1.maximumRunRecords,
            control: control,
            rescue: rescue,
            collapseFirstRescue: collapseFirstRescue,
            allChecksPass: all,
            claims: .init(
                publicDefaultChanged: false,
                automaticBackgroundCompaction: false,
                hardCapacityProgressCandidate: true,
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

    static func schema5RunCapacityCollapseFallback(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        var seeded: Schema5CompactionResourceSeedResult? = try await schema5CompactionResourceSeed(
            root: root,
            profile: .v3CompactBinary,
            liveCount: 32_768,
            runCount: SegmentedManifestPrototypeV1.maximumRunDescriptors,
            recordsPerRun: SegmentedManifestPrototypeV1.maximumRunRecords,
            history: "wide"
        )
        var store: FileBlobStore? = seeded!.store
        let seededRoot = seeded!.root
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let collapsePlan = try SegmentedManifestRunCollapseV1.plan(
            frozenRoot: seededRoot,
            segmentDirectory: segmentDirectory
        )
        guard collapsePlan == nil else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        store = nil
        seeded = nil

        let limits = FileBlobStoreLimits(
            softTotalBytes: 256 * 1024 * 1024,
            maximumBlobBytes: 64 * 1024 * 1024,
            maximumDirectoryEntryCount: 201_024
        )
        store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            limits: limits,
            runCapacityPolicy: .synchronousV3RunCollapseThenCompactionAtHardLimit
        )
        let identities = try schema5MigrationIdentities(
            labels: (0..<512).map { "run-cap-collapse-fallback-\($0)" }
        )
        for identity in identities.prefix(511) {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let beforeRoot = try schema5RunCapacityReadRoot(root)
        let target = identities[511]
        let publication = try await store!.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterRoot = try schema5RunCapacityReadRoot(root)
        let names = try schema5RunCapacitySegmentNames(root)
        let referenced = Set([afterRoot.base.fileName] + afterRoot.runs.map(\.fileName))
        let priorAuthorityPreserved = before.entries.allSatisfy { key, entry in
            after.entries[key] == entry
        }
        let targetAuthorityExact = after.entries[target.key].map { entry in
            entry.physicalID == publication.physicalID
                && entry.partition == target.partition
                && entry.digest == target.digest
                && entry.byteCount == target.data.count
        } ?? false
        let afterCommitment = try schema5IdentityCommitment(after.entries)

        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            limits: limits,
            runCapacityPolicy: .synchronousV3RunCollapseThenCompactionAtHardLimit
        )
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5RunCapacityReadRoot(root)
        let reopenedCommitment = try schema5IdentityCommitment(reopened.entries)
        let readBack = try await store!.read(digest: target.digest, partition: target.partition)
        let reopenExact = reopened.entries == after.entries
            && reopenedRoot == afterRoot
            && reopenedCommitment == afterCommitment
        store = nil

        let report = Schema5RunCapacityFallbackReport(
            schemaVersion: 1,
            startingRunCount: beforeRoot.runs.count,
            startingLiveEntryCount: before.entries.count,
            startingActiveDistinctKeys: beforeHead.distinctKeyCount,
            collapsePlanRejected: collapsePlan == nil,
            boundaryCommitSucceeded: true,
            generationDelta: afterRoot.generation - beforeRoot.generation,
            finalRunCount: afterRoot.runs.count,
            finalEntryCount: after.entries.count,
            baseDescriptorChanged: afterRoot.base != beforeRoot.base,
            finalSegmentFileCount: names.count,
            segmentSetExactlyReferenced: Set(names) == referenced
                && names.count == referenced.count,
            priorAuthorityPreserved: priorAuthorityPreserved,
            targetAuthorityExact: targetAuthorityExact,
            reopenExact: reopenExact,
            targetReadableAfterReopen: readBack == target.data,
            claims: [
                "hardCapacityFallback": true,
                "formalLatency": false,
                "physicalDeviceIO": false,
                "powerLoss": false,
                "publicDefaultChanged": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard report.startingRunCount == SegmentedManifestPrototypeV1.maximumRunDescriptors,
            report.startingActiveDistinctKeys == 511,
            report.collapsePlanRejected,
            report.generationDelta == 1,
            report.finalRunCount == 1,
            report.finalEntryCount == 33_280,
            report.baseDescriptorChanged,
            report.finalSegmentFileCount == 2,
            report.segmentSetExactlyReferenced,
            report.priorAuthorityPreserved,
            report.targetAuthorityExact,
            report.reopenExact,
            report.targetReadableAfterReopen
        else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5RunCapacityControlCase(
        root: URL
    ) async throws -> Schema5RunCapacityControlReport {
        let identities = try schema5RunCapacityHotIdentities()
        var store: FileBlobStore? = try await schema5RunCapacitySeed(
            root: root,
            policy: .rejectAtHardLimit
        )
        for identity in identities.prefix(511) {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let beforeRoot = try schema5RunCapacityReadRoot(root)
        let beforeRootData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let beforeSegments = try schema5RunCapacitySegmentNames(root)
        let target = identities[511]
        let limitExceeded: Bool
        do {
            _ = try await store!.commit(
                data: target.data,
                digest: target.digest,
                partition: target.partition
            )
            limitExceeded = false
        } catch AkashicError.limitExceeded {
            limitExceeded = true
        }
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterRootData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let afterSegments = try schema5RunCapacitySegmentNames(root)
        let actorAuthorityUnchanged = after.entries == before.entries
        let targetAbsent = after.entries[target.key] == nil
        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let reopenedRoot = try schema5RunCapacityReadRoot(root)
        let reopenExact = reopened.entries == before.entries
            && reopenedHead.distinctKeyCount == 511
            && reopenedRoot == beforeRoot
        store = nil
        return .init(
            startingRunCount: beforeRoot.runs.count,
            startingActiveDistinctKeys: beforeHead.distinctKeyCount,
            limitExceeded: limitExceeded,
            rootUnchanged: afterRootData == beforeRootData,
            segmentSetUnchanged: afterSegments == beforeSegments,
            actorAuthorityUnchanged: actorAuthorityUnchanged,
            targetAbsent: targetAbsent,
            reopenExact: reopenExact
        )
    }

    private static func schema5RunCapacityRescueCase(
        root: URL,
        policy: FileBlobStoreSegmentedRunCapacityPolicy
    ) async throws -> Schema5RunCapacityRescueCaseReport {
        let identities = try schema5RunCapacityHotIdentities()
        var store: FileBlobStore? = try await schema5RunCapacitySeed(
            root: root,
            policy: policy
        )
        for identity in identities.prefix(511) {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let beforeRoot = try schema5RunCapacityReadRoot(root)
        let target = identities[511]
        let publication = try await store!.commit(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let afterRoot = try schema5RunCapacityReadRoot(root)
        let names = try schema5RunCapacitySegmentNames(root)
        let referencedNames = Set([afterRoot.base.fileName] + afterRoot.runs.map(\.fileName))
        let priorAuthorityPreserved = before.entries.allSatisfy { key, entry in
            after.entries[key] == entry
        }
        let targetAuthorityExact = after.entries[target.key].map { entry in
            entry.physicalID == publication.physicalID
                && entry.partition == target.partition
                && entry.digest == target.digest
                && entry.byteCount == target.data.count
        } ?? false

        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            runCapacityPolicy: policy
        )
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let reopenedRoot = try schema5RunCapacityReadRoot(root)
        let readBack = try await store!.read(digest: target.digest, partition: target.partition)
        let reopenExact = reopened.entries == after.entries
            && reopenedRoot == afterRoot
            && reopenedHead.distinctKeyCount == afterHead.distinctKeyCount
        store = nil
        return .init(
            startingRunCount: beforeRoot.runs.count,
            startingActiveDistinctKeys: beforeHead.distinctKeyCount,
            boundaryCommitSucceeded: true,
            generationDelta: afterRoot.generation - beforeRoot.generation,
            finalRunCount: afterRoot.runs.count,
            finalActiveDistinctKeys: afterHead.distinctKeyCount,
            finalEntryCount: after.entries.count,
            finalProfile: afterRoot.profile,
            finalBaseKind: afterRoot.base.kind.rawValue,
            baseDescriptorUnchanged: afterRoot.base == beforeRoot.base,
            finalSegmentFileCount: names.count,
            segmentSetExactlyReferenced: Set(names) == referencedNames
                && names.count == referencedNames.count,
            priorAuthorityPreserved: priorAuthorityPreserved,
            targetAuthorityExact: targetAuthorityExact,
            reopenExact: reopenExact,
            targetReadableAfterReopen: readBack == target.data
        )
    }

    static func schema5RunCapacitySeed(
        root: URL,
        policy: FileBlobStoreSegmentedRunCapacityPolicy,
        runCount: Int = SegmentedManifestPrototypeV1.maximumRunDescriptors
    ) async throws -> FileBlobStore {
        guard runCount > 0,
            runCount <= SegmentedManifestPrototypeV1.maximumRunDescriptors
        else { throw SegmentedManifestShadowError.invalidArguments }
        try StorageDirectorySecurity.prepareDirectory(root)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(blobs)
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(segments)
        let generation: UInt64 = 10
        let base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
            [:],
            fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
            directory: segments
        )
        let history = try schema5MigrationIdentities(
            labels: (0..<runCount).map {
                "run-cap-rescue-history-\($0)"
            }
        )
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(runCount)
        for identity in history {
            runs.append(
                try SegmentedManifestPrototypeV1.writeRun(
                    [.tombstone(key: identity.key)],
                    fileName: "run-g\(generation)-\(UUID().uuidString.lowercased()).seg",
                    directory: segments
                )
            )
        }
        let seededRoot = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: generation,
            base: base,
            runs: runs
        )
        try SegmentedManifestPrototypeV1.writeRoot(
            seededRoot,
            to: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        _ = try SegmentedManifestDirectoryHeadPrototypeV1.repairEmptyGeneration(
            generation: generation,
            blobsDirectory: blobs
        )
        return try await FileBlobStore.openSegmentedV3Candidate(
            root: root,
            runCapacityPolicy: policy
        )
    }

    static func schema5RunCapacityHotIdentities() throws -> [MigrationIdentity] {
        try schema5MigrationIdentities(
            labels: (0..<512).map { "run-cap-rescue-hot-\($0)" }
        )
    }

    static func schema5RunCapacityReadRoot(_ root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    static func schema5RunCapacitySegmentNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        return try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).sorted()
    }
}
