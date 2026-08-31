import AkashicCore
import AkashicDisk
import Foundation

private enum Schema5CheckpointBoundarySample: String {
    case ordinary = "ordinary"
    case checkpoint = "checkpoint"

    var prefillCount: Int {
        switch self {
        case .ordinary: 510
        case .checkpoint: 511
        }
    }
}

private struct Schema5CheckpointBoundaryResourceReport: Codable {
    struct Claims: Codable {
        let mechanismMeasurement: Bool
        let formalPerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let energy: Bool
        let powerLoss: Bool
        let productionPolicyRecommendation: Bool
    }

    let schemaVersion: Int
    let sample: String
    let liveEntries: Int
    let startingRunCount: Int
    let startingBaseBytes: Int
    let startingRunBytes: Int
    let prefillCount: Int
    let activeDistinctBeforeMeasurement: Int
    let measuredCommitElapsedNanoseconds: UInt64
    let generationDelta: UInt64
    let finalRunCount: Int
    let finalActiveDistinctKeys: Int
    let finalEntryCount: Int
    let baseDescriptorUnchanged: Bool
    let segmentSetExactlyReferenced: Bool
    let priorAuthorityPreserved: Bool
    let targetAuthorityExact: Bool
    let freshReopenExact: Bool
    let targetReadableAfterReopen: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5CheckpointBoundaryResource(arguments: [String]) async throws {
        let parsed = try schema5CheckpointBoundaryResourceArguments(arguments)
        var seeded: Schema5CompactionResourceSeedResult? = try await schema5CompactionResourceSeed(
            root: parsed.root,
            profile: .v3CompactBinary,
            liveCount: parsed.liveEntries,
            runCount: 1,
            recordsPerRun: 512,
            history: "hot"
        )
        var store: FileBlobStore? = seeded!.store
        let frozenRoot = seeded!.root
        let startingBaseBytes = seeded!.baseBytes
        let startingRunBytes = seeded!.runBytes
        seeded = nil

        let identities = try schema5MigrationIdentities(
            labels: (0..<512).map {
                "checkpoint-boundary-\(parsed.sample.rawValue)-\(parsed.liveEntries)-\($0)"
            }
        )
        for identity in identities.prefix(parsed.sample.prefillCount) {
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
            beforeHead.distinctKeyCount == parsed.sample.prefillCount
        else { throw SegmentedManifestShadowError.invariantViolation }

        let target = identities[parsed.sample.prefillCount]
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
        let afterHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
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

        store = nil
        let limits = FileBlobStoreLimits(
            softTotalBytes: 256 * 1024 * 1024,
            maximumBlobBytes: 64 * 1024 * 1024,
            maximumDirectoryEntryCount: 201_024
        )
        store = try await FileBlobStore.openSegmentedV3Candidate(root: parsed.root, limits: limits)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try schema5RunCapacityReadRoot(parsed.root)
        let reopenedCommitment = try schema5IdentityCommitment(reopened.entries)
        let readBack = try await store!.read(digest: target.digest, partition: target.partition)
        let freshReopenExact = reopened.entries == after.entries
            && reopenedRoot == afterRoot
            && reopenedCommitment == afterCommitment
        store = nil

        let report = Schema5CheckpointBoundaryResourceReport(
            schemaVersion: 1,
            sample: parsed.sample.rawValue,
            liveEntries: parsed.liveEntries,
            startingRunCount: beforeRoot.runs.count,
            startingBaseBytes: startingBaseBytes,
            startingRunBytes: startingRunBytes,
            prefillCount: parsed.sample.prefillCount,
            activeDistinctBeforeMeasurement: beforeHead.distinctKeyCount,
            measuredCommitElapsedNanoseconds: elapsed,
            generationDelta: afterRoot.generation - beforeRoot.generation,
            finalRunCount: afterRoot.runs.count,
            finalActiveDistinctKeys: afterHead.distinctKeyCount,
            finalEntryCount: after.entries.count,
            baseDescriptorUnchanged: afterRoot.base == beforeRoot.base,
            segmentSetExactlyReferenced: Set(names) == referenced && names.count == referenced.count,
            priorAuthorityPreserved: priorAuthorityPreserved,
            targetAuthorityExact: targetAuthorityExact,
            freshReopenExact: freshReopenExact,
            targetReadableAfterReopen: readBack == target.data,
            claims: .init(
                mechanismMeasurement: true,
                formalPerformance: false,
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

        let expectedGenerationDelta: UInt64 = parsed.sample == .checkpoint ? 1 : 0
        let expectedRunCount = parsed.sample == .checkpoint ? 2 : 1
        let expectedActive = parsed.sample == .checkpoint ? 0 : 511
        guard report.startingRunCount == 1,
            report.generationDelta == expectedGenerationDelta,
            report.finalRunCount == expectedRunCount,
            report.finalActiveDistinctKeys == expectedActive,
            report.finalEntryCount == parsed.liveEntries + parsed.sample.prefillCount + 1,
            report.baseDescriptorUnchanged,
            report.segmentSetExactlyReferenced,
            report.priorAuthorityPreserved,
            report.targetAuthorityExact,
            report.freshReopenExact,
            report.targetReadableAfterReopen
        else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5CheckpointBoundaryResourceArguments(
        _ arguments: [String]
    ) throws -> (
        root: URL,
        sample: Schema5CheckpointBoundarySample,
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
            let rawSample = values["--sample"],
            let sample = Schema5CheckpointBoundarySample(rawValue: rawSample),
            let liveEntries = values["--live"].flatMap(Int.init),
            liveEntries >= 512,
            liveEntries <= FileBlobStore.resourceProbeMaximumManifestEntryCount,
            let ready = values["--ready-fd"].flatMap(Int32.init),
            let go = values["--go-fd"].flatMap(Int32.init),
            let done = values["--done-fd"].flatMap(Int32.init),
            let release = values["--release-fd"].flatMap(Int32.init)
        else { throw SegmentedManifestShadowError.invalidArguments }
        return (
            root: URL(fileURLWithPath: root, isDirectory: true),
            sample: sample,
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
