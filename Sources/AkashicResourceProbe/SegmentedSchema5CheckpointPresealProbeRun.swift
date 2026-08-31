import AkashicCore
import AkashicDisk
import Foundation

extension SegmentedManifestShadowProbe {
    static func schema5CheckpointPreseal(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Build payload/storage authority once. Each case copies this source tree and constructs the
        // active epoch using metadata-only republish, so the qualification does not spend most of
        // its time repeatedly fsyncing 480 payloads.
        let template = root.appendingPathComponent("seed-template", isDirectory: true)
        var prepared: (store: FileBlobStore, snapshot: FileBlobStoreManifestShadowSnapshot)?
            = try await schema5CheckpointPresealPrepareV3Base(root: template, baseCount: 512)
        let templateSnapshot = prepared!.snapshot
        prepared = nil
        let identities = try schema5CheckpointPresealIdentities(
            domain: "preseal-base-512",
            count: 512
        )

        // Freeze the expensive active-epoch prefix once as well. The case fixtures below now copy
        // an already-valid `(V3 base + directory-head c=480)` state and execute only their
        // post-snapshot tail. Heavy churn is paid only by the churn adversary itself.
        let head480Template = root.appendingPathComponent(
            "head480-template",
            isDirectory: true
        )
        var headTemplateStore: FileBlobStore? = try await schema5CheckpointPresealOpenCase(
            template: template,
            root: head480Template
        )
        try await schema5CheckpointPresealRepublish(
            store: headTemplateStore!,
            identities: identities,
            range: 0..<480,
            epoch: 1
        )
        let frozenHead = try await headTemplateStore!.resourceProbeDirectoryHeadEpochSnapshot()
        guard frozenHead.distinctKeyCount == 480 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        headTemplateStore = nil

        let cases = [
            try await schema5CheckpointPresealBestCase(
                template: head480Template,
                root: root.appendingPathComponent("best-480", isDirectory: true),
                identities: identities,
                templateSnapshot: templateSnapshot
            ),
            try await schema5CheckpointPresealChurnFallbackCase(
                template: head480Template,
                root: root.appendingPathComponent("churn-fallback", isDirectory: true),
                identities: identities,
                templateSnapshot: templateSnapshot
            ),
            try await schema5CheckpointPresealDeletedPrefixCase(
                template: head480Template,
                root: root.appendingPathComponent("deleted-prefix", isDirectory: true),
                identities: identities,
                templateSnapshot: templateSnapshot
            ),
            try await schema5CheckpointPresealCorruptFallbackCase(
                template: head480Template,
                root: root.appendingPathComponent("corrupt-fallback", isDirectory: true),
                identities: identities,
                templateSnapshot: templateSnapshot
            ),
        ]
        let byName = Dictionary(uniqueKeysWithValues: cases.map { ($0.name, $0) })
        let best = byName["best-480"]!
        let churn = byName["churn-fallback"]!
        let deleted = byName["deleted-prefix"]!
        let corrupt = byName["corrupt-fallback"]!
        let common = cases.allSatisfy {
            $0.generationDelta == 1
                && $0.finalActiveDistinctKeys == 0
                && $0.finalEntryCount == 512
                && $0.authorityExactBeforeReopen
                && $0.reopenExact
                && $0.targetReadableAfterReopen
                && $0.segmentSetExactlyReferenced
        }
        let all = common
            && best.sourceDistinctKeys == 480
            && best.candidateRecords == 480
            && best.finalRunRecordCounts == [480, 32]
            && best.candidateReferencedAfterCheckpoint
            && !best.candidateReclaimedAfterCheckpoint
            && churn.churnedPrefixKeys == 480
            && churn.finalRunRecordCounts == [512]
            && !churn.candidateReferencedAfterCheckpoint
            && churn.candidateReclaimedAfterCheckpoint
            && deleted.deletedPrefixPhysicalIDChanges == 1
            && deleted.finalRunRecordCounts == [480, 33]
            && deleted.candidateReferencedAfterCheckpoint
            && !deleted.candidateReclaimedAfterCheckpoint
            && corrupt.finalRunRecordCounts == [512]
            && !corrupt.candidateReferencedAfterCheckpoint
            && corrupt.candidateReclaimedAfterCheckpoint

        let report = Schema5CheckpointPresealReport(
            schemaVersion: 2,
            checkpointDistinctLimit: SegmentedManifestPrototypeV1.maximumRunRecords,
            cases: cases,
            allChecksPass: all,
            claims: [
                "semanticAuthority": true,
                "physicalOwnershipObserved": true,
                "candidateIsNonAuthoritative": true,
                "automaticScheduling": false,
                "processCrash": false,
                "powerLoss": false,
                "formalPerformance": false,
                "physicalDeviceIO": false,
                "productionPolicyRecommendation": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5CheckpointPresealBestCase(
        template: URL,
        root: URL,
        identities: [Schema5CheckpointPresealIdentity],
        templateSnapshot: FileBlobStoreManifestShadowSnapshot
    ) async throws -> Schema5CheckpointPresealCase {
        var store: FileBlobStore? = try await schema5CheckpointPresealOpenCase(
            template: template,
            root: root
        )
        let beforeGeneration = try schema5CheckpointPresealReadRoot(root).generation
        let preseal = try await store!.resourceProbePrepareSegmentedCheckpointPresealV3()
        try await schema5CheckpointPresealRepublish(
            store: store!,
            identities: identities,
            range: 480..<511,
            epoch: 1
        )
        let target = identities[511]
        try await store!.resourceProbeRepublishEntry(
            digest: target.digest,
            partition: target.partition,
            lastAccess: schema5CheckpointPresealDate(epoch: 1, index: 511)
        )
        return try await schema5CheckpointPresealFinishCase(
            name: "best-480",
            root: root,
            store: &store,
            templateSnapshot: templateSnapshot,
            identities: identities,
            target: target,
            preseal: preseal,
            beforeGeneration: beforeGeneration,
            churnedPrefixKeys: 0,
            deletedPrefixPhysicalIDChanges: 0
        )
    }

    private static func schema5CheckpointPresealChurnFallbackCase(
        template: URL,
        root: URL,
        identities: [Schema5CheckpointPresealIdentity],
        templateSnapshot: FileBlobStoreManifestShadowSnapshot
    ) async throws -> Schema5CheckpointPresealCase {
        var store: FileBlobStore? = try await schema5CheckpointPresealOpenCase(
            template: template,
            root: root
        )
        let beforeGeneration = try schema5CheckpointPresealReadRoot(root).generation
        let preseal = try await store!.resourceProbePrepareSegmentedCheckpointPresealV3()
        // Every prefix key gets a newer latest record, so tail latest-state count reaches 512.
        try await schema5CheckpointPresealRepublish(
            store: store!,
            identities: identities,
            range: 0..<480,
            epoch: 2
        )
        try await schema5CheckpointPresealRepublish(
            store: store!,
            identities: identities,
            range: 480..<511,
            epoch: 1
        )
        let target = identities[511]
        try await store!.resourceProbeRepublishEntry(
            digest: target.digest,
            partition: target.partition,
            lastAccess: schema5CheckpointPresealDate(epoch: 1, index: 511)
        )
        return try await schema5CheckpointPresealFinishCase(
            name: "churn-fallback",
            root: root,
            store: &store,
            templateSnapshot: templateSnapshot,
            identities: identities,
            target: target,
            preseal: preseal,
            beforeGeneration: beforeGeneration,
            churnedPrefixKeys: 480,
            deletedPrefixPhysicalIDChanges: 0
        )
    }

    private static func schema5CheckpointPresealDeletedPrefixCase(
        template: URL,
        root: URL,
        identities: [Schema5CheckpointPresealIdentity],
        templateSnapshot: FileBlobStoreManifestShadowSnapshot
    ) async throws -> Schema5CheckpointPresealCase {
        var store: FileBlobStore? = try await schema5CheckpointPresealOpenCase(
            template: template,
            root: root
        )
        let beforeGeneration = try schema5CheckpointPresealReadRoot(root).generation
        let preseal = try await store!.resourceProbePrepareSegmentedCheckpointPresealV3()
        let donor = identities[0]
        let beforeID = await store!.physicalID(digest: donor.digest, partition: donor.partition)
        try await store!.remove(digest: donor.digest, partition: donor.partition)
        _ = try await store!.commit(
            data: donor.data,
            digest: donor.digest,
            partition: donor.partition
        )
        let afterID = await store!.physicalID(digest: donor.digest, partition: donor.partition)
        let changed = beforeID != nil && afterID != nil && beforeID != afterID ? 1 : 0
        try await schema5CheckpointPresealRepublish(
            store: store!,
            identities: identities,
            range: 480..<511,
            epoch: 1
        )
        let target = identities[511]
        try await store!.resourceProbeRepublishEntry(
            digest: target.digest,
            partition: target.partition,
            lastAccess: schema5CheckpointPresealDate(epoch: 1, index: 511)
        )
        return try await schema5CheckpointPresealFinishCase(
            name: "deleted-prefix",
            root: root,
            store: &store,
            templateSnapshot: templateSnapshot,
            identities: identities,
            target: target,
            preseal: preseal,
            beforeGeneration: beforeGeneration,
            churnedPrefixKeys: 1,
            deletedPrefixPhysicalIDChanges: changed
        )
    }

    private static func schema5CheckpointPresealCorruptFallbackCase(
        template: URL,
        root: URL,
        identities: [Schema5CheckpointPresealIdentity],
        templateSnapshot: FileBlobStoreManifestShadowSnapshot
    ) async throws -> Schema5CheckpointPresealCase {
        var store: FileBlobStore? = try await schema5CheckpointPresealOpenCase(
            template: template,
            root: root
        )
        let beforeGeneration = try schema5CheckpointPresealReadRoot(root).generation
        let preseal = try await store!.resourceProbePrepareSegmentedCheckpointPresealV3()
        let candidateURL = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        ).appendingPathComponent(preseal.candidateFileName, isDirectory: false)
        try Data("corrupt speculative prefix".utf8).write(to: candidateURL)
        try await schema5CheckpointPresealRepublish(
            store: store!,
            identities: identities,
            range: 480..<511,
            epoch: 1
        )
        let target = identities[511]
        try await store!.resourceProbeRepublishEntry(
            digest: target.digest,
            partition: target.partition,
            lastAccess: schema5CheckpointPresealDate(epoch: 1, index: 511)
        )
        return try await schema5CheckpointPresealFinishCase(
            name: "corrupt-fallback",
            root: root,
            store: &store,
            templateSnapshot: templateSnapshot,
            identities: identities,
            target: target,
            preseal: preseal,
            beforeGeneration: beforeGeneration,
            churnedPrefixKeys: 0,
            deletedPrefixPhysicalIDChanges: 0
        )
    }

    private static func schema5CheckpointPresealFinishCase(
        name: String,
        root: URL,
        store: inout FileBlobStore?,
        templateSnapshot: FileBlobStoreManifestShadowSnapshot,
        identities: [Schema5CheckpointPresealIdentity],
        target: Schema5CheckpointPresealIdentity,
        preseal: FileBlobStoreSegmentedCheckpointPresealResult,
        beforeGeneration: UInt64,
        churnedPrefixKeys: Int,
        deletedPrefixPhysicalIDChanges: Int
    ) async throws -> Schema5CheckpointPresealCase {
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterRoot = try schema5CheckpointPresealReadRoot(root)
        let afterHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let authorityExact = after.entries.count == templateSnapshot.entries.count
            && identities.allSatisfy { identity in
                guard let entry = after.entries[identity.key] else { return false }
                return entry.partition == identity.partition
                    && entry.digest == identity.digest
                    && entry.byteCount == identity.data.count
            }
        let names = try schema5CheckpointPresealSegmentNames(root)
        let referenced = Set([afterRoot.base.fileName] + afterRoot.runs.map(\.fileName))
        let candidateReferenced = afterRoot.runs.contains {
            $0.fileName == preseal.candidateFileName
        }
        let candidateReclaimed = !names.contains(preseal.candidateFileName)
        let runCounts = afterRoot.runs.map(\.recordCount)

        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5CheckpointPresealReadRoot(root)
        let readBack = try await store!.read(digest: target.digest, partition: target.partition)
        let reopenExact = reopened == after && reopenedRoot == afterRoot
        store = nil

        return .init(
            name: name,
            sourceDistinctKeys: preseal.sourceDistinctKeyCount,
            candidateBytes: preseal.candidateByteCount,
            candidateRecords: preseal.candidateRecordCount,
            finalRunCount: afterRoot.runs.count,
            finalRunRecordCounts: runCounts,
            generationDelta: afterRoot.generation - beforeGeneration,
            finalActiveDistinctKeys: afterHead.distinctKeyCount,
            finalEntryCount: after.entries.count,
            candidateReferencedAfterCheckpoint: candidateReferenced,
            candidateReclaimedAfterCheckpoint: candidateReclaimed,
            churnedPrefixKeys: churnedPrefixKeys,
            deletedPrefixPhysicalIDChanges: deletedPrefixPhysicalIDChanges,
            authorityExactBeforeReopen: authorityExact,
            reopenExact: reopenExact,
            targetReadableAfterReopen: readBack == target.data,
            segmentSetExactlyReferenced: Set(names) == referenced && names.count == referenced.count
        )
    }

    private static func schema5CheckpointPresealOpenCase(
        template: URL,
        root: URL
    ) async throws -> FileBlobStore {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.copyItem(at: template, to: root)
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.openSegmentedV3Candidate(root: root)
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw SegmentedManifestShadowError.invariantViolation
    }

    private static func schema5CheckpointPresealRepublish(
        store: FileBlobStore,
        identities: [Schema5CheckpointPresealIdentity],
        range: Range<Int>,
        epoch: Int
    ) async throws {
        for index in range {
            let identity = identities[index]
            try await store.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: schema5CheckpointPresealDate(epoch: epoch, index: index)
            )
        }
    }

    private static func schema5CheckpointPresealDate(epoch: Int, index: Int) -> Date {
        Date(timeIntervalSinceReferenceDate:
            800_000_000 + Double(epoch * 10_000 + index))
    }

    static func schema5CheckpointPresealPrepareV3Base(
        root: URL,
        baseCount: Int
    ) async throws -> (store: FileBlobStore, snapshot: FileBlobStoreManifestShadowSnapshot) {
        try? FileManager.default.removeItem(at: root)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        let base = try schema5CheckpointPresealIdentities(
            domain: "preseal-base-\(baseCount)",
            count: baseCount
        )
        for identity in base {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil

        let rootURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let v1 = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let transition = try SegmentedManifestBinaryBaseTransitionV3.prepare(
            frozenRoot: v1,
            segmentDirectory: segmentDirectory,
            candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        )
        try SegmentedManifestPrototypeV1.writeRoot(transition.root, to: rootURL)
        _ = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: transition.root,
            directory: segmentDirectory
        )
        let reopened = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let snapshot = await reopened.resourceProbeManifestShadowSnapshot()
        guard snapshot.entries.count == baseCount else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        return (reopened, snapshot)
    }

    static func schema5CheckpointPresealReadRoot(
        _ root: URL
    ) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    static func schema5CheckpointPresealSegmentNames(_ root: URL) throws -> [String] {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        return try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter {
            SegmentedManifestSegmentCleanupV1.isProductionCanonical($0)
        }.sorted()
    }

    private static func schema5CheckpointPresealIdentities(
        domain: String,
        count: Int
    ) throws -> [Schema5CheckpointPresealIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: domain,
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("\(domain)-payload-\(index)".utf8)
            return .init(
                partition: partition,
                digest: BlobDigest.sha256(of: data),
                data: data
            )
        }
    }
}
