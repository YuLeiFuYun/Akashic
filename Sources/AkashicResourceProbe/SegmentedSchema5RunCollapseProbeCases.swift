import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension SegmentedManifestShadowProbe {
    static func schema5RunCollapseWide64x32Case(root: URL) async throws
        -> Schema5RunCollapseCaseReport
    {
        let identities = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-wide64-v1",
            count: 2_048
        )
        let baseline = try await schema5RunCollapsePrepareV3Base(root: root, identities: identities)
        var runs: [[SegmentedManifestMutation]] = []
        runs.reserveCapacity(64)
        for runIndex in 0..<64 {
            let range = (runIndex * 32)..<((runIndex + 1) * 32)
            runs.append(
                try schema5RunCollapseUpserts(
                    keys: range.map { identities[$0].key },
                    snapshot: baseline
                )
            )
        }
        _ = try schema5RunCollapseInstallRuns(root: root, runs: runs)
        return try await schema5RunCollapseExecuteCase(
            name: "wide-64x32",
            root: root,
            expectedBefore: baseline.entries,
            sample: identities[0],
            expectedInputRuns: 64,
            expectedOutputRuns: 8,
            expectedSpeculativeAutomaticAdmission: false
        )
    }

    static func schema5RunCollapseWide48x32Case(root: URL) async throws
        -> Schema5RunCollapseCaseReport
    {
        let runCount = 48
        let recordsPerRun = 32
        let identities = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-wide48-v1",
            count: runCount * recordsPerRun
        )
        let baseline = try await schema5RunCollapsePrepareV3Base(root: root, identities: identities)
        var runs: [[SegmentedManifestMutation]] = []
        runs.reserveCapacity(runCount)
        for runIndex in 0..<runCount {
            let range = (runIndex * recordsPerRun)..<((runIndex + 1) * recordsPerRun)
            runs.append(
                try schema5RunCollapseUpserts(
                    keys: range.map { identities[$0].key },
                    snapshot: baseline
                )
            )
        }
        _ = try schema5RunCollapseInstallRuns(root: root, runs: runs)
        return try await schema5RunCollapseExecuteCase(
            name: "wide-48x32",
            root: root,
            expectedBefore: baseline.entries,
            sample: identities[0],
            expectedInputRuns: runCount,
            expectedOutputRuns: 6,
            expectedSpeculativeAutomaticAdmission: false
        )
    }

    static func schema5RunCollapseDisjointRejectCase(root: URL) async throws
        -> Schema5RunCollapseCaseReport
    {
        let identities = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-disjoint-v1",
            count: 2_048
        )
        let baseline = try await schema5RunCollapsePrepareV3Base(root: root, identities: identities)
        var runs: [[SegmentedManifestMutation]] = []
        for runIndex in 0..<4 {
            let range = (runIndex * 512)..<((runIndex + 1) * 512)
            runs.append(
                try schema5RunCollapseUpserts(
                    keys: range.map { identities[$0].key },
                    snapshot: baseline
                )
            )
        }
        _ = try schema5RunCollapseInstallRuns(root: root, runs: runs)
        return try await schema5RunCollapseExecuteCase(
            name: "disjoint-4x512-reject",
            root: root,
            expectedBefore: baseline.entries,
            sample: identities[0],
            expectedInputRuns: 4,
            expectedOutputRuns: nil,
            expectedSpeculativeAutomaticAdmission: nil
        )
    }

    static func schema5RunCollapsePhysicalTransferCase(root: URL) async throws
        -> Schema5RunCollapseCaseReport
    {
        let old = try schema5RunCollapseIdentities(
            domain: "schema5-run-collapse-transfer-old-v1",
            count: 513
        )
        let baseline = try await schema5RunCollapsePrepareV3Base(root: root, identities: old)
        let newPartitions = try (0..<513).map { index in
            try CachePartitionID.derive(
                domain: "schema5-run-collapse-transfer-new-v1",
                material: Data("partition-\(index)".utf8)
            )
        }
        var finalEntries: [String: FileBlobStoreRecordShadowEntry] = [:]
        var transferPairs: [[SegmentedManifestMutation]] = []
        transferPairs.reserveCapacity(513)
        for index in 0..<513 {
            guard let source = baseline.entries[old[index].key] else {
                throw SegmentedManifestShadowError.invariantViolation
            }
            let newKey = FileBlobStore.resourceProbeManifestKey(
                digest: old[index].digest,
                partition: newPartitions[index]
            )
            let newShadow = FileBlobStoreRecordShadowEntry(
                physicalID: source.physicalID,
                partition: newPartitions[index],
                digest: source.digest,
                byteCount: source.byteCount,
                lastAccess: source.lastAccess
            )
            finalEntries[newKey] = newShadow
            transferPairs.append(
                [
                    .tombstone(key: old[index].key),
                    .upsert(
                    SegmentedManifestEntry(
                        key: newKey,
                        physicalID: source.physicalID,
                        partition: newPartitions[index],
                        digest: source.digest,
                        byteCount: source.byteCount,
                        lastAccess: source.lastAccess
                    )
                    ),
                ]
            )
        }
        // Keep every release/acquire pair inside one source run. A run's replay semantics release
        // ownership for all touched keys before applying its upserts, so cross-key PhysicalBlobID
        // transfer is legal inside the run. Globally sorting 1,026 mutations and then slicing at
        // 512 would be an invalid fixture: an acquiring upsert could land in an earlier run than
        // the tombstone that releases the previous owner.
        var runs: [[SegmentedManifestMutation]] = []
        for pairRange in [0..<256, 256..<512, 512..<513] {
            var mutations: [SegmentedManifestMutation] = []
            mutations.reserveCapacity(pairRange.count * 2)
            for index in pairRange { mutations.append(contentsOf: transferPairs[index]) }
            mutations.sort { $0.key < $1.key }
            runs.append(mutations)
        }
        let finalKeys = finalEntries.keys.sorted()
        // Keep the three overlap runs physically distinct. A V3 root rejects duplicate segment
        // hashes, so repeating the exact same 512-record run would describe an invalid source
        // topology rather than a hard run-collapse case. Prefixes 510/511/512 retain the same
        // touched-key and final-upsert sets while producing three legal immutable runs.
        for count in [510, 511, 512] {
            let repeatedUpserts = finalKeys.prefix(count).compactMap {
                key -> SegmentedManifestMutation? in
                guard let entry = finalEntries[key] else { return nil }
                return .upsert(
                    SegmentedManifestEntry(
                        key: key,
                        physicalID: entry.physicalID,
                        partition: entry.partition,
                        digest: entry.digest,
                        byteCount: entry.byteCount,
                        lastAccess: entry.lastAccess
                    )
                )
            }
            runs.append(Array(repeatedUpserts))
        }
        guard runs.count == 6 else { throw SegmentedManifestShadowError.invariantViolation }
        _ = try schema5RunCollapseInstallRuns(root: root, runs: runs)

        let sample = Schema5RunCollapseIdentity(
            partition: newPartitions[0],
            digest: old[0].digest,
            data: old[0].data
        )
        return try await schema5RunCollapseExecuteCase(
            name: "physical-transfer",
            root: root,
            expectedBefore: finalEntries,
            sample: sample,
            expectedInputRuns: 6,
            expectedOutputRuns: 5,
            expectedSpeculativeAutomaticAdmission: false
        )
    }

    static func schema5RunCollapseExecuteCase(
        name: String,
        root: URL,
        expectedBefore: [String: FileBlobStoreRecordShadowEntry],
        sample: Schema5RunCollapseIdentity,
        expectedInputRuns: Int,
        expectedOutputRuns: Int?,
        expectedSpeculativeAutomaticAdmission: Bool?
    ) async throws -> Schema5RunCollapseCaseReport {
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeRoot = try schema5RunCollapseReadRoot(root)
        let beforeRootData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let beforeNames = try schema5RunCollapseSegmentNames(root)
        let authorityExactBefore = before.entries == expectedBefore
        guard beforeRoot.runs.count == expectedInputRuns else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let result = try await store!.resourceProbeCollapseSegmentedRunsV3()
        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterRoot = try schema5RunCollapseReadRoot(root)
        let afterRootData = try Data(
            contentsOf: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let afterNames = try schema5RunCollapseSegmentNames(root)
        let authorityExactAfter = after.entries == expectedBefore
        let physicalExact = expectedBefore.allSatisfy { key, expected in
            after.entries[key]?.physicalID == expected.physicalID
        }
        let sampleRead = try await store!.read(digest: sample.digest, partition: sample.partition)
        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5RunCollapseReadRoot(root)
        let reopenExact = reopened.entries == expectedBefore && reopenedRoot == afterRoot
        store = nil

        let referencedAfter = Set([afterRoot.base.fileName] + afterRoot.runs.map(\.fileName))
        guard Set(afterNames) == referencedAfter,
            afterNames.count == referencedAfter.count
        else { throw SegmentedManifestShadowError.invariantViolation }
        let speculativeAutomaticAdmission = result.map { collapse in
            FileBlobStoreSegmentedRunPrefixPreparationAdmission.speculativeAutomatic.accepts(
                inputRunCount: collapse.inputRunCount,
                outputRunCount: collapse.outputRunCount,
                inputRunBytes: collapse.inputRunBytes,
                outputRunBytes: collapse.outputRunBytes
            )
        }

        return Schema5RunCollapseCaseReport(
            name: name,
            inputRunCount: expectedInputRuns,
            expectedOutputRunCount: expectedOutputRuns,
            actualOutputRunCount: result?.outputRunCount,
            touchedKeyCount: result?.touchedKeyCount,
            finalUpsertCount: result?.finalUpsertCount,
            inputRunBytes: result?.inputRunBytes,
            outputRunBytes: result?.outputRunBytes,
            expectedSpeculativeAutomaticAdmission: expectedSpeculativeAutomaticAdmission,
            actualSpeculativeAutomaticAdmission: speculativeAutomaticAdmission,
            rootChanged: beforeRootData != afterRootData,
            segmentCountBefore: beforeNames.count,
            segmentCountAfter: afterNames.count,
            authorityExactBeforeCollapse: authorityExactBefore,
            authorityExactAfterCollapse: authorityExactAfter,
            physicalOwnershipExactAfterCollapse: physicalExact,
            reopenExact: reopenExact,
            sampleReadable: sampleRead == sample.data
        )
    }
}
