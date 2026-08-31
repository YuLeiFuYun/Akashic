import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func schema5PublicSegmentGC(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let checkpoint = try await schema5GCCheckpointOrphanCase(
            root: root.appendingPathComponent("checkpoint-orphan", isDirectory: true)
        )
        let unreferenced = try await schema5GCUnreferencedCase(
            root: root.appendingPathComponent("unreferenced", isDirectory: true)
        )
        let symlink = try await schema5GCSymlinkCase(
            root: root.appendingPathComponent("symlink", isDirectory: true)
        )
        let hardlink = try await schema5GCHardlinkCase(
            root: root.appendingPathComponent("hardlink", isDirectory: true)
        )
        let unsafeMode = try await schema5GCUnsafeModeCase(
            root: root.appendingPathComponent("unsafe-mode", isDirectory: true)
        )
        let immutable = try await schema5GCImmutableCase(
            root: root.appendingPathComponent("immutable", isDirectory: true)
        )
        let overflow = try await schema5GCOverflowCase(
            root: root.appendingPathComponent("overflow", isDirectory: true)
        )
        let callerCauseLoss = try await schema5GCCallerCauseLossCase(
            root: root.appendingPathComponent("caller-cause-loss", isDirectory: true)
        )

        let allChecksPass = checkpoint.orphanRemoved
            && checkpoint.authorityExact
            && unreferenced.validRemoved
            && unreferenced.corruptRemoved
            && unreferenced.foreignPreserved
            && symlink.rejected
            && symlink.targetPreserved
            && hardlink.rejected
            && hardlink.targetPreserved
            && unsafeMode
            && immutable.openExact
            && immutable.debtRemained
            && immutable.retryRemoved
            && overflow
            && callerCauseLoss.bootstrapAuthorityExact
            && callerCauseLoss.activeDistinctKeysBeforeRejectedMutation == 511
            && callerCauseLoss.directFailureFileNameMatches
            && callerCauseLoss.directFailurePOSIXCode == EPERM
            && callerCauseLoss.directRemainingDebtCount == 1
            && callerCauseLoss.mutationRejectedAsLimitExceeded
            && callerCauseLoss.rejectedMutationAuthorityExact
            && callerCauseLoss.rootUnchangedAfterRejectedMutation
            && callerCauseLoss.activeDistinctKeysAfterRejectedMutation == 511
            && callerCauseLoss.retryAfterObstacleRemovedSucceeded
            && callerCauseLoss.retryAuthorityAdvanced
            && callerCauseLoss.activeDistinctKeysAfterRetry == 0

        let report = Schema5PublicSegmentGCReport(
            schemaVersion: 1,
            checkpointOrphanRemoved: checkpoint.orphanRemoved,
            checkpointOldAuthorityExact: checkpoint.authorityExact,
            validUnreferencedRemoved: unreferenced.validRemoved,
            corruptUnreferencedRemoved: unreferenced.corruptRemoved,
            foreignNoncanonicalPreserved: unreferenced.foreignPreserved,
            symlinkCanonicalRejected: symlink.rejected,
            symlinkTargetPreserved: symlink.targetPreserved,
            hardlinkCanonicalRejected: hardlink.rejected,
            hardlinkTargetPreserved: hardlink.targetPreserved,
            unsafeModeCanonicalRejected: unsafeMode,
            immutableOpenExact: immutable.openExact,
            immutableDebtRemained: immutable.debtRemained,
            immutableRetryRemoved: immutable.retryRemoved,
            boundedOverflowRejected: overflow,
            callerCauseLoss: callerCauseLoss,
            maximumDirectoryEntries: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries,
            claims: .init(
                sameUserRaceProtection: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allChecksPass else {
            throw SegmentedManifestShadowError.invariantViolation
        }
    }

    private static func schema5GCCheckpointOrphanCase(
        root: URL
    ) async throws -> (orphanRemoved: Bool, authorityExact: Bool) {
        var store: FileBlobStore? = try await schema5PrepareCheckpointSeed(root: root).store
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        store = nil
        let target = try schema5IntegrationIdentities(prefix: "hot", count: 512)[511]
        store = try await FileBlobStore.open(
            root: root,
            faultInjector: { point in
                if point == .afterManifestFileSynced { throw Schema5PublicGCInjectedError.preRename }
            }
        )
        let stage = try await store!.stage(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        do {
            _ = try await store!.publish(stage)
            throw SegmentedManifestShadowError.invariantViolation
        } catch Schema5PublicGCInjectedError.preRename {
            // Expected: run durable, root still old.
        }
        store = nil
        let segmentDirectory = schema5GCSegmentDirectory(root)
        let beforeOpenCount = try schema5GCEntryCount(segmentDirectory)
        store = try await schema5GCOpen(root: root)
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let active = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let afterOpenCount = try schema5GCEntryCount(segmentDirectory)
        return (
            orphanRemoved: beforeOpenCount == 2 && afterOpenCount == 1,
            authorityExact: try schema5IdentityCommitment(after.entries) == beforeCommitment
                && after.entries == before.entries
                && active.distinctKeyCount == 511
        )
    }

    private static func schema5GCUnreferencedCase(
        root: URL
    ) async throws -> (validRemoved: Bool, corruptRemoved: Bool, foreignPreserved: Bool) {
        var store: FileBlobStore? = try await schema5GCPrepareStore(root: root)
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        store = nil
        let segmentDirectory = schema5GCSegmentDirectory(root)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let baseData = try SegmentedManifestPrototypeV1.readDescriptorData(
            segmentedRoot.base,
            directory: segmentDirectory
        )
        let validName = "base-compaction-\(UUID().uuidString.lowercased()).json"
        _ = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: segmentedRoot.base.recordCount,
            fileName: validName,
            directory: segmentDirectory
        )
        let corruptName = "run-g\(segmentedRoot.generation)-\(UUID().uuidString.lowercased()).seg"
        let corruptURL = segmentDirectory.appendingPathComponent(corruptName, isDirectory: false)
        try DurableFileWriter.writeReplacing(Data("corrupt-unreferenced-run".utf8), to: corruptURL)
        let foreignURL = segmentDirectory.appendingPathComponent("foreign.keep", isDirectory: false)
        try DurableFileWriter.writeReplacing(Data("foreign".utf8), to: foreignURL)

        store = try await schema5GCOpen(root: root)
        let after = await store!.resourceProbeManifestShadowSnapshot()
        guard try schema5IdentityCommitment(after.entries) == beforeCommitment else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        return (
            validRemoved: !FileManager.default.fileExists(
                atPath: segmentDirectory.appendingPathComponent(validName).path
            ),
            corruptRemoved: !FileManager.default.fileExists(atPath: corruptURL.path),
            foreignPreserved: FileManager.default.fileExists(atPath: foreignURL.path)
        )
    }

    private static func schema5GCSymlinkCase(
        root: URL
    ) async throws -> (rejected: Bool, targetPreserved: Bool) {
        try await schema5GCPrepareAndReleaseStore(root: root)
        let directory = schema5GCSegmentDirectory(root)
        let target = directory.appendingPathComponent("foreign-target", isDirectory: false)
        try DurableFileWriter.writeReplacing(Data("target".utf8), to: target)
        let lookalike = directory.appendingPathComponent(
            "base-compaction-\(UUID().uuidString.lowercased()).json",
            isDirectory: false
        )
        guard target.path.withCString({ targetPointer in
            lookalike.path.withCString { linkPointer in Darwin.symlink(targetPointer, linkPointer) }
        }) == 0 else { throw POSIXError(.EIO) }
        let rejected = await schema5GCOpenRejected(root: root)
        return (
            rejected: rejected,
            targetPreserved: FileManager.default.fileExists(atPath: target.path)
        )
    }

    private static func schema5GCHardlinkCase(
        root: URL
    ) async throws -> (rejected: Bool, targetPreserved: Bool) {
        try await schema5GCPrepareAndReleaseStore(root: root)
        let directory = schema5GCSegmentDirectory(root)
        let target = directory.appendingPathComponent("foreign-target", isDirectory: false)
        try DurableFileWriter.writeReplacing(Data("target".utf8), to: target)
        let lookalike = directory.appendingPathComponent(
            "run-g3-\(UUID().uuidString.lowercased()).seg",
            isDirectory: false
        )
        guard target.path.withCString({ targetPointer in
            lookalike.path.withCString { linkPointer in Darwin.link(targetPointer, linkPointer) }
        }) == 0 else { throw POSIXError(.EIO) }
        let rejected = await schema5GCOpenRejected(root: root)
        return (
            rejected: rejected,
            targetPreserved: FileManager.default.fileExists(atPath: target.path)
        )
    }

    private static func schema5GCUnsafeModeCase(root: URL) async throws -> Bool {
        try await schema5GCPrepareAndReleaseStore(root: root)
        let url = schema5GCSegmentDirectory(root).appendingPathComponent(
            "base-compaction-\(UUID().uuidString.lowercased()).json",
            isDirectory: false
        )
        try DurableFileWriter.writeReplacing(Data("unsafe-mode".utf8), to: url)
        guard url.path.withCString({ Darwin.chmod($0, 0o644) }) == 0 else {
            throw POSIXError(.EIO)
        }
        return await schema5GCOpenRejected(root: root)
            && FileManager.default.fileExists(atPath: url.path)
    }

    private static func schema5GCImmutableCase(
        root: URL
    ) async throws -> (openExact: Bool, debtRemained: Bool, retryRemoved: Bool) {
        var store: FileBlobStore? = try await schema5GCPrepareStore(root: root)
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        store = nil
        let url = schema5GCSegmentDirectory(root).appendingPathComponent(
            "base-compaction-\(UUID().uuidString.lowercased()).json",
            isDirectory: false
        )
        try DurableFileWriter.writeReplacing(Data("immutable-debt".utf8), to: url)
        guard url.path.withCString({ Darwin.chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
            throw POSIXError(.EIO)
        }
        store = try await schema5GCOpen(root: root)
        let opened = await store!.resourceProbeManifestShadowSnapshot()
        let openExact = try schema5IdentityCommitment(opened.entries) == beforeCommitment
            && opened.entries == before.entries
        let debtRemained = FileManager.default.fileExists(atPath: url.path)
        store = nil
        guard url.path.withCString({ Darwin.chflags($0, 0) }) == 0 else {
            throw POSIXError(.EIO)
        }
        store = try await schema5GCOpen(root: root)
        let retried = await store!.resourceProbeManifestShadowSnapshot()
        return (
            openExact: openExact,
            debtRemained: debtRemained,
            retryRemoved: !FileManager.default.fileExists(atPath: url.path)
                && retried.entries == before.entries
        )
    }

    private static func schema5GCCallerCauseLossCase(
        root: URL
    ) async throws -> Schema5PublicSegmentGCReport.CallerCauseLoss {
        var store: FileBlobStore? = try await schema5GCPrepareStore(root: root)
        let checkpointIdentities = try schema5IntegrationIdentities(
            prefix: "caller-cause-loss",
            count: SegmentedManifestPrototypeV1.maximumRunRecords
        )
        for index in 0..<(SegmentedManifestPrototypeV1.maximumRunRecords - 1) {
            let identity = checkpointIdentities[index]
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let beforeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        guard beforeHead.distinctKeyCount == SegmentedManifestPrototypeV1.maximumRunRecords - 1 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        store = nil

        let directory = schema5GCSegmentDirectory(root)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let rootBytesBefore = try Data(contentsOf: manifestURL)
        let immutableName = "base-compaction-\(UUID().uuidString.lowercased()).json"
        let immutableURL = directory.appendingPathComponent(immutableName, isDirectory: false)
        try DurableFileWriter.writeReplacing(Data("immutable-headroom-debt".utf8), to: immutableURL)
        guard immutableURL.path.withCString({ Darwin.chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
            throw POSIXError(.EIO)
        }
        defer { _ = immutableURL.path.withCString { Darwin.chflags($0, 0) } }

        let existingAfterDebt = try schema5GCEntryCount(directory)
        guard existingAfterDebt <= SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        for index in existingAfterDebt..<SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries {
            let url = directory.appendingPathComponent(
                String(format: "foreign-headroom-%03d.keep", index),
                isDirectory: false
            )
            try DurableFileWriter.writeReplacing(Data([UInt8(truncatingIfNeeded: index)]), to: url)
        }
        guard try schema5GCEntryCount(directory)
            == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        else { throw SegmentedManifestShadowError.invariantViolation }

        store = try await schema5GCOpen(root: root)
        let opened = await store!.resourceProbeManifestShadowSnapshot()
        let openedHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let bootstrapAuthorityExact = try schema5IdentityCommitment(opened.entries) == beforeCommitment
            && opened.entries == before.entries
            && openedHead.distinctKeyCount == SegmentedManifestPrototypeV1.maximumRunRecords - 1

        // Observe the lower-layer cause directly without changing policy. The next distinct commit
        // is the 512th active head mutation, so it must enter checkpointSegmentedManifest, whose
        // cleanup result is currently discarded before ensureMaterializationCapacity reports the
        // caller-visible capacity error.
        let currentRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let direct = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: currentRoot,
            directory: directory
        )
        let directFailureFileNameMatches = direct.failures.count == 1
            && direct.failures[0].fileName == immutableName
        let directFailurePOSIXCode = direct.failures.first?.posixCode

        let candidate = checkpointIdentities[SegmentedManifestPrototypeV1.maximumRunRecords - 1]
        var mutationRejectedAsLimitExceeded = false
        var mutationErrorText: String?
        do {
            _ = try await store!.commit(
                data: candidate.data,
                digest: candidate.digest,
                partition: candidate.partition
            )
        } catch AkashicError.limitExceeded {
            mutationRejectedAsLimitExceeded = true
            mutationErrorText = String(reflecting: AkashicError.limitExceeded)
        } catch {
            mutationErrorText = String(reflecting: error)
        }
        let rejected = await store!.resourceProbeManifestShadowSnapshot()
        let rejectedHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let rejectedCommitment = try schema5IdentityCommitment(rejected.entries)
        let rejectedMutationAuthorityExact = rejected.entries == before.entries
            && rejectedCommitment == beforeCommitment
        let rootUnchangedAfterRejectedMutation = try Data(contentsOf: manifestURL) == rootBytesBefore
        store = nil

        guard immutableURL.path.withCString({ Darwin.chflags($0, 0) }) == 0 else {
            throw POSIXError(.EIO)
        }
        store = try await schema5GCOpen(root: root)
        let retryPublication: BlobPublication?
        do {
            retryPublication = try await store!.commit(
                data: candidate.data,
                digest: candidate.digest,
                partition: candidate.partition
            )
        } catch {
            retryPublication = nil
        }
        let retried = await store!.resourceProbeManifestShadowSnapshot()
        let retriedHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let retryAfterObstacleRemovedSucceeded = retryPublication != nil
        let retryAuthorityAdvanced = retried.entries.count == before.entries.count + 1
            && retried.entries[candidate.key] != nil

        return .init(
            bootstrapAuthorityExact: bootstrapAuthorityExact,
            activeDistinctKeysBeforeRejectedMutation: openedHead.distinctKeyCount,
            directFailureFileNameMatches: directFailureFileNameMatches,
            directFailurePOSIXCode: directFailurePOSIXCode,
            directRemainingDebtCount: direct.remainingDebtCount,
            mutationRejectedAsLimitExceeded: mutationRejectedAsLimitExceeded,
            mutationErrorText: mutationErrorText,
            rejectedMutationAuthorityExact: rejectedMutationAuthorityExact,
            rootUnchangedAfterRejectedMutation: rootUnchangedAfterRejectedMutation,
            activeDistinctKeysAfterRejectedMutation: rejectedHead.distinctKeyCount,
            retryAfterObstacleRemovedSucceeded: retryAfterObstacleRemovedSucceeded,
            retryAuthorityAdvanced: retryAuthorityAdvanced,
            activeDistinctKeysAfterRetry: retriedHead.distinctKeyCount
        )
    }

    private static func schema5GCOverflowCase(root: URL) async throws -> Bool {
        try await schema5GCPrepareAndReleaseStore(root: root)
        let directory = schema5GCSegmentDirectory(root)
        let existing = try schema5GCEntryCount(directory)
        guard existing < SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries + 1 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        for index in existing...SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries {
            let url = directory.appendingPathComponent(
                String(format: "foreign-overflow-%03d.keep", index),
                isDirectory: false
            )
            try DurableFileWriter.writeReplacing(Data([UInt8(truncatingIfNeeded: index)]), to: url)
        }
        do {
            _ = try await FileBlobStore.open(root: root)
            return false
        } catch AkashicError.limitExceeded {
            return true
        } catch {
            return false
        }
    }

    private static func schema5GCPrepareAndReleaseStore(root: URL) async throws {
        var store: FileBlobStore? = try await schema5GCPrepareStore(root: root)
        _ = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
    }

    private static func schema5GCPrepareStore(root: URL) async throws -> FileBlobStore {
        let identities = try schema5IntegrationIdentities(prefix: "gc-base", count: 2)
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        _ = try await store!.commit(
            data: identities[0].data,
            digest: identities[0].digest,
            partition: identities[0].partition
        )
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.commit(
            data: identities[1].data,
            digest: identities[1].digest,
            partition: identities[1].partition
        )
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
        return try await schema5GCOpen(root: root)
    }

    private static func schema5GCOpen(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do { return try await FileBlobStore.open(root: root) }
            catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    private static func schema5GCOpenRejected(root: URL) async -> Bool {
        for _ in 0..<250 {
            do {
                _ = try await FileBlobStore.open(root: root)
                return false
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                continue
            } catch {
                return true
            }
        }
        // If every attempt is storageUnavailable, the unsafe canonical entry is fail-closed.
        return true
    }

    private static func schema5GCSegmentDirectory(_ root: URL) -> URL {
        root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
    }

    private static func schema5GCEntryCount(_ directory: URL) throws -> Int {
        try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).count
    }
}
