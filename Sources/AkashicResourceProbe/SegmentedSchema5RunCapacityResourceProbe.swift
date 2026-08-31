import AkashicCore
import AkashicDisk
import Foundation

private enum Schema5RunCapacityBoundaryResourcePolicy: String {
    case fullBase = "full-base"
    case collapseFirst = "collapse-first"

    var storePolicy: FileBlobStoreSegmentedRunCapacityPolicy {
        switch self {
        case .fullBase: .synchronousV3CompactionAtHardLimit
        case .collapseFirst: .synchronousV3RunCollapseThenCompactionAtHardLimit
        }
    }
}

private struct Schema5RunCapacityBoundaryResourceReport: Codable {
    struct Claims: Codable {
        let mechanismMeasurement: Bool
        let formalPerformance: Bool
        let endToEndStorePerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let energy: Bool
        let powerLoss: Bool
        let productionPolicyRecommendation: Bool
    }

    let schemaVersion: Int
    let policy: String
    let history: String
    let liveEntries: Int
    let startingRunCount: Int
    let startingRunBytes: Int
    let startingBaseBytes: Int
    let startingActiveDistinctKeys: Int
    let startingEntryCount: Int
    let boundaryCommitElapsedNanoseconds: UInt64
    let finalRunCount: Int
    let finalBaseBytes: Int
    let baseDescriptorUnchanged: Bool
    let usedRunCollapse: Bool
    let fellBackToFullBase: Bool
    let finalSegmentFileCount: Int
    let segmentSetExactlyReferenced: Bool
    let priorAuthorityPreserved: Bool
    let targetAuthorityExact: Bool
    let finalEntryCount: Int
    let freshReopenExact: Bool
    let targetReadableAfterReopen: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5RunCapacityBoundaryResource(arguments: [String]) async throws {
        let parsed = try schema5RunCapacityBoundaryResourceArguments(arguments)
        var seeded: Schema5CompactionResourceSeedResult? = try await schema5CompactionResourceSeed(
            root: parsed.root,
            profile: .v3CompactBinary,
            liveCount: parsed.liveEntries,
            runCount: SegmentedManifestPrototypeV1.maximumRunDescriptors,
            recordsPerRun: SegmentedManifestPrototypeV1.maximumRunRecords,
            history: parsed.history
        )
        var store: FileBlobStore? = seeded!.store
        let frozenRoot = seeded!.root
        let startingRunBytes = seeded!.runBytes
        let startingBaseBytes = seeded!.baseBytes
        store = nil
        seeded = nil

        let limits = FileBlobStoreLimits(
            softTotalBytes: 256 * 1024 * 1024,
            maximumBlobBytes: 64 * 1024 * 1024,
            maximumDirectoryEntryCount: 201_024
        )
        store = try await FileBlobStore.openSegmentedV3Candidate(
            root: parsed.root,
            limits: limits,
            runCapacityPolicy: parsed.policy.storePolicy
        )
        let identities = try schema5MigrationIdentities(
            labels: (0..<512).map {
                "run-cap-resource-\(parsed.policy.rawValue)-\(parsed.history)-\(parsed.liveEntries)-\($0)"
            }
        )
        for identity in identities.prefix(511) {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let beforeRoot = try schema5RunCapacityReadRoot(parsed.root)
        let beforeHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        guard beforeRoot == frozenRoot,
            beforeRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors,
            beforeHead.distinctKeyCount == 511
        else { throw SegmentedManifestShadowError.invariantViolation }

        let target = identities[511]
        try parsed.barrier.enter()
        let started = DispatchTime.now().uptimeNanoseconds
        let publication: BlobPublication
        do {
            publication = try await store!.commit(
                data: target.data,
                digest: target.digest,
                partition: target.partition
            )
        } catch {
            try? parsed.barrier.leave()
            throw error
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        try parsed.barrier.leave()

        let after = await store!.resourceProbeManifestShadowSnapshot()
        let afterRoot = try schema5RunCapacityReadRoot(parsed.root)
        let names = try schema5RunCapacitySegmentNames(parsed.root)
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
        let baseUnchanged = afterRoot.base == beforeRoot.base

        store = nil
        store = try await FileBlobStore.openSegmentedV3Candidate(
            root: parsed.root,
            limits: limits,
            runCapacityPolicy: parsed.policy.storePolicy
        )
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5RunCapacityReadRoot(parsed.root)
        let reopenedCommitment = try schema5IdentityCommitment(reopened.entries)
        let readBack = try await store!.read(digest: target.digest, partition: target.partition)
        let freshReopenExact = reopened.entries == after.entries
            && reopenedRoot == afterRoot
            && reopenedCommitment == afterCommitment
        store = nil

        let report = Schema5RunCapacityBoundaryResourceReport(
            schemaVersion: 1,
            policy: parsed.policy.rawValue,
            history: parsed.history,
            liveEntries: parsed.liveEntries,
            startingRunCount: beforeRoot.runs.count,
            startingRunBytes: startingRunBytes,
            startingBaseBytes: startingBaseBytes,
            startingActiveDistinctKeys: beforeHead.distinctKeyCount,
            startingEntryCount: before.entries.count,
            boundaryCommitElapsedNanoseconds: elapsed,
            finalRunCount: afterRoot.runs.count,
            finalBaseBytes: afterRoot.base.byteCount,
            baseDescriptorUnchanged: baseUnchanged,
            usedRunCollapse: parsed.policy == .collapseFirst && baseUnchanged,
            fellBackToFullBase: parsed.policy == .collapseFirst && !baseUnchanged,
            finalSegmentFileCount: names.count,
            segmentSetExactlyReferenced: Set(names) == referenced && names.count == referenced.count,
            priorAuthorityPreserved: priorAuthorityPreserved,
            targetAuthorityExact: targetAuthorityExact,
            finalEntryCount: after.entries.count,
            freshReopenExact: freshReopenExact,
            targetReadableAfterReopen: readBack == target.data,
            claims: .init(
                mechanismMeasurement: true,
                formalPerformance: false,
                endToEndStorePerformance: false,
                physicalIOBytes: false,
                physicalDevice: false,
                energy: false,
                powerLoss: false,
                productionPolicyRecommendation: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard report.startingRunCount == SegmentedManifestPrototypeV1.maximumRunDescriptors,
            report.startingActiveDistinctKeys == 511,
            report.finalEntryCount == parsed.liveEntries + 512,
            report.segmentSetExactlyReferenced,
            report.priorAuthorityPreserved,
            report.targetAuthorityExact,
            report.freshReopenExact,
            report.targetReadableAfterReopen
        else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5RunCapacityBoundaryResourceArguments(
        _ arguments: [String]
    ) throws -> (
        root: URL,
        policy: Schema5RunCapacityBoundaryResourcePolicy,
        history: String,
        liveEntries: Int,
        barrier: Schema5CompactionResourceBarrier
    ) {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let root = values["--root"],
            let rawPolicy = values["--policy"],
            let policy = Schema5RunCapacityBoundaryResourcePolicy(rawValue: rawPolicy),
            let history = values["--history"],
            history == "hot" || history == "wide",
            let liveEntries = values["--live"].flatMap(Int.init),
            liveEntries >= SegmentedManifestPrototypeV1.maximumRunRecords,
            liveEntries <= FileBlobStore.resourceProbeMaximumManifestEntryCount,
            history != "wide" || liveEntries >= SegmentedManifestPrototypeV1.maximumRunDescriptors
                * SegmentedManifestPrototypeV1.maximumRunRecords,
            let ready = values["--ready-fd"].flatMap(Int32.init),
            let go = values["--go-fd"].flatMap(Int32.init),
            let done = values["--done-fd"].flatMap(Int32.init),
            let release = values["--release-fd"].flatMap(Int32.init)
        else { throw SegmentedManifestShadowError.invalidArguments }
        return (
            root: URL(fileURLWithPath: root, isDirectory: true),
            policy: policy,
            history: history,
            liveEntries: liveEntries,
            barrier: Schema5CompactionResourceBarrier(
                readyFD: ready,
                goFD: go,
                doneFD: done,
                releaseFD: release
            )
        )
    }
}
