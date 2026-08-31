import AkashicCore
import AkashicDisk
import Darwin
import Foundation

struct SegmentedEpochHandoffReport: Codable {
    let schemaVersion: Int
    let oldGeneration: UInt64
    let newGeneration: UInt64
    let activeDistinctKeys: Int
    let sealedRunRecords: Int
    let sealedRunBytes: Int
    let sealedRunMatchesActiveEpoch: Bool
    let runDurableRootOldPreservesState: Bool
    let futureHeadsBeforeRootRejected: Bool
    let rootNewRepairsMissingEmptyEpoch: Bool
    let newAuthorityMatchesOldLogicalState: Bool
    let oneHeadRecoveryRepairMatchesState: Bool
    let oldEpochCleanupFailureDoesNotRollback: Bool
    let rootRollbackRejectedAfterNewHeadsExist: Bool
    let oldEpochMetadataCanRemainAsDebt: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let productionAuthorityChanged: Bool
        let checkpointReplacementQualified: Bool
        let processCrash: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func epochHandoffShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        let heads = root.appendingPathComponent("heads", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        try StorageDirectorySecurity.prepareDirectory(heads)

        let oldGeneration: UInt64 = 100
        let newGeneration: UInt64 = 101
        let baseEntries = try makeBaseEntries(count: 64)
        let base = try epochWriteBase(
            baseEntries,
            fileName: "base-epoch-origin.seg",
            directory: segments
        )
        let oldRoot = try makeRoot(generation: oldGeneration, base: base, runs: [])
        let rootURL = root.appendingPathComponent("shadow-root.json")
        try DurableFileWriter.writeReplacing(try encodeRoot(oldRoot), to: rootURL)

        let baseShadow = epochShadowState(
            Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        )
        try DirectoryHeadShadowProbe.initializeMigrationShadow(
            root: heads,
            generation: oldGeneration
        )
        try epochApplyMixedMutations(
            heads: heads,
            generation: oldGeneration,
            baseEntries: baseEntries
        )
        let oldRecovered = try DirectoryHeadShadowProbe.recover(
            root: heads,
            generation: oldGeneration,
            base: baseShadow
        )
        let epochMutations = try epochSegmentedMutations(oldRecovered)
        let runData = try encodeRun(epochMutations)
        let runURL = segments.appendingPathComponent("run-epoch-100.seg")
        try DurableFileWriter.writeReplacing(runData, to: runURL)
        let run = try descriptor(
            .run,
            url: runURL,
            expectedRecords: epochMutations.count
        )
        let sealedHistory = try apply(
            epochMutations,
            to: Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        )
        let sealedRunMatchesActiveEpoch = epochSegmentedState(oldRecovered.logical) == sealedHistory
        guard sealedRunMatchesActiveEpoch else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let runDurableRootOldPreservesState = try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: false
        ) == sealedHistory
        guard runDurableRootOldPreservesState else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        // Future-generation heads are not safe to materialize before the root generation advances:
        // old-root recovery must reject them rather than silently ignore future authority metadata.
        try DirectoryHeadShadowProbe.initializeMigrationShadow(
            root: heads,
            generation: newGeneration
        )
        var futureHeadsBeforeRootRejected = false
        do {
            _ = try recoverEpochAuthority(
                rootURL: rootURL,
                segmentDirectory: segments,
                headDirectory: heads,
                allowEmptyEpochRepair: false
            )
        } catch {
            futureHeadsBeforeRootRejected = true
        }
        guard futureHeadsBeforeRootRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try epochRemoveEmptyHeads(generation: newGeneration, from: heads)

        let newRoot = try makeRoot(
            generation: newGeneration,
            base: base,
            runs: [run]
        )
        try DurableFileWriter.writeReplacing(try encodeRoot(newRoot), to: rootURL)

        // Root publication is the logical handoff. Empty active heads may be absent after a crash;
        // recovery is allowed to create them only because the new root already includes the sealed epoch.
        let repairedNew = try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: true
        )
        let rootNewRepairsMissingEmptyEpoch = repairedNew == sealedHistory
        let newAuthorityMatchesOldLogicalState = repairedNew == epochSegmentedState(oldRecovered.logical)
        guard rootNewRepairsMissingEmptyEpoch,
            newAuthorityMatchesOldLogicalState
        else { throw SegmentedManifestShadowError.invariantViolation }

        // Recovery-of-recovery: one empty head may already exist after another interruption.
        try DirectoryHeadShadowIO.removeAttribute(
            DirectoryHeadIdentity(generation: newGeneration, slot: 1).name,
            at: heads
        )
        try DirectoryHeadShadowIO.synchronize(heads)
        let oneHeadRecovered = try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: true
        )
        let oneHeadRecoveryRepairMatchesState = oneHeadRecovered == sealedHistory
        guard oneHeadRecoveryRepairMatchesState else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        // Once the new root selects generation 101, old generation-100 xattrs are only cleanup debt.
        // Make the directory immutable to force a real fremovexattr failure, then prove generation-101
        // recovery remains exact and does not consult the stale generation as logical authority.
        let oldNames = oldRecovered.recordIdentities.map(\.name) + [
            DirectoryHeadIdentity(generation: oldGeneration, slot: 0).name,
            DirectoryHeadIdentity(generation: oldGeneration, slot: 1).name,
        ]
        try epochSetImmutable(true, url: heads)
        var cleanupFailed = false
        do {
            if let first = oldNames.first {
                try DirectoryHeadShadowIO.removeAttribute(first, at: heads)
            }
        } catch {
            cleanupFailed = true
        }
        let stateDuringCleanupFailure = try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: false
        )
        try epochSetImmutable(false, url: heads)
        let oldEpochCleanupFailureDoesNotRollback = cleanupFailed
            && stateDuringCleanupFailure == sealedHistory
        guard oldEpochCleanupFailureDoesNotRollback else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let namesAfterFailure = try XattrShadowProbeIO.listAttributes(heads)
        let oldEpochMetadataCanRemainAsDebt = try namesAfterFailure.contains { name in
            if let identity = try DirectoryHeadIdentity.parse(name) {
                return identity.generation == oldGeneration
            }
            if let identity = try DirectoryHeadRecordIdentity.parse(name) {
                return identity.generation == oldGeneration
            }
            return false
        }
        guard oldEpochMetadataCanRemainAsDebt else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        // A root rollback after generation-101 heads exist must fail closed: future head metadata is
        // evidence that the old generation is no longer a complete current authority frontier.
        try DurableFileWriter.writeReplacing(try encodeRoot(oldRoot), to: rootURL)
        var rootRollbackRejectedAfterNewHeadsExist = false
        do {
            _ = try recoverEpochAuthority(
                rootURL: rootURL,
                segmentDirectory: segments,
                headDirectory: heads,
                allowEmptyEpochRepair: false
            )
        } catch {
            rootRollbackRejectedAfterNewHeadsExist = true
        }
        guard rootRollbackRejectedAfterNewHeadsExist else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try DurableFileWriter.writeReplacing(try encodeRoot(newRoot), to: rootURL)
        guard try recoverEpochAuthority(
            rootURL: rootURL,
            segmentDirectory: segments,
            headDirectory: heads,
            allowEmptyEpochRepair: false
        ) == sealedHistory else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let report = SegmentedEpochHandoffReport(
            schemaVersion: 1,
            oldGeneration: oldGeneration,
            newGeneration: newGeneration,
            activeDistinctKeys: oldRecovered.latest.count,
            sealedRunRecords: epochMutations.count,
            sealedRunBytes: runData.count,
            sealedRunMatchesActiveEpoch: true,
            runDurableRootOldPreservesState: true,
            futureHeadsBeforeRootRejected: true,
            rootNewRepairsMissingEmptyEpoch: true,
            newAuthorityMatchesOldLogicalState: true,
            oneHeadRecoveryRepairMatchesState: true,
            oldEpochCleanupFailureDoesNotRollback: true,
            rootRollbackRejectedAfterNewHeadsExist: true,
            oldEpochMetadataCanRemainAsDebt: true,
            claims: .init(
                productionFormat: false,
                productionAuthorityChanged: false,
                checkpointReplacementQualified: false,
                processCrash: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func epochApplyMixedMutations(
        heads: URL,
        generation: UInt64,
        baseEntries: [SegmentedShadowEntry]
    ) throws {
        guard baseEntries.count >= 4 else { throw SegmentedManifestShadowError.invalidFormat }
        let repairSource = baseEntries[0]
        for offset in 1...3 {
            let entry = FileBlobStoreRecordShadowEntry(
                physicalID: PhysicalBlobID(),
                partition: repairSource.partition,
                digest: repairSource.digest,
                byteCount: repairSource.byteCount,
                lastAccess: repairSource.lastAccess.addingTimeInterval(Double(offset))
            )
            try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
                root: heads,
                generation: generation,
                key: repairSource.key,
                entry: entry
            )
        }
        try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
            root: heads,
            generation: generation,
            key: baseEntries[1].key,
            entry: nil
        )
        for index in 0..<20 {
            let entry = try epochCreatedShadowEntry(index: index)
            try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
                root: heads,
                generation: generation,
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: entry.digest,
                    partition: entry.partition
                ),
                entry: entry
            )
        }
        let transient = try epochCreatedShadowEntry(index: 100)
        let transientKey = FileBlobStore.resourceProbeManifestKey(
            digest: transient.digest,
            partition: transient.partition
        )
        try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
            root: heads,
            generation: generation,
            key: transientKey,
            entry: transient
        )
        try DirectoryHeadShadowProbe.applyMigrationShadowMutation(
            root: heads,
            generation: generation,
            key: transientKey,
            entry: nil
        )
    }

    private static func epochCreatedShadowEntry(index: Int) throws -> FileBlobStoreRecordShadowEntry {
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-epoch-handoff-v1",
            material: Data("create-\(index)".utf8)
        )
        let payload = Data("epoch-created-\(index)".utf8)
        let digest = BlobDigest.sha256(of: payload)
        return FileBlobStoreRecordShadowEntry(
            physicalID: PhysicalBlobID(),
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 1_030_000_000 + Double(index))
        )
    }

    static func epochSegmentedMutations(
        _ recovered: DirectoryHeadRecovered
    ) throws -> [SegmentedShadowMutation] {
        recovered.latest.map { key, latest in
            if let entry = latest.mutation.entry {
                return .upsert(
                    SegmentedShadowEntry(
                        key: key,
                        physicalID: entry.physicalID,
                        partition: entry.partition,
                        digest: entry.digest,
                        byteCount: entry.byteCount,
                        lastAccess: entry.lastAccess
                    )
                )
            }
            return .tombstone(key: key)
        }.sorted { $0.key < $1.key }
    }

}
