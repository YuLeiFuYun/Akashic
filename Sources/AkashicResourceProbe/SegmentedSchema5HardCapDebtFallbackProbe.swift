import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct Schema5HardCapDebtFallbackReport: Codable {
    let schemaVersion: Int
    let maximumDirectoryEntries: Int
    let initialRunCount: Int
    let initialSegmentEntryCount: Int
    let injectedImmutableOrphanCount: Int
    let cleanupRemainingDebtBeforeMutation: Int
    let availableMaterializationEntriesBeforeMutation: Int
    let collapsePlanOutputRunCount: Int
    let collapsePlanInputRunBytes: Int
    let collapsePlanOutputRunBytes: Int
    let collapseMaterializationWouldFit: Bool
    let oneFileFullCompactionWouldFit: Bool
    let hardBoundaryCheckpointSucceeded: Bool
    let initialBaseFileName: String
    let finalBaseFileName: String
    let fullBaseFallbackObserved: Bool
    let finalRunCountWithDebt: Int
    let finalOrphanCountWithDebt: Int
    let finalSegmentEntryCountWithDebt: Int
    let physicalOwnershipExact: Bool
    let authorityCountExact: Bool
    let sampleReadable: Bool
    let reopenWithDebtExact: Bool
    let cleanupDeletedCountAfterRepair: Int
    let cleanupRemainingDebtAfterRepair: Int
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenAfterRepairExact: Bool
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum SegmentedSchema5HardCapDebtFallbackProbe {
    private static let recordsPerCheckpoint = 512
    private static let immutableOrphanCount = 64

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: SegmentedManifestPrototypeV1.maximumRunDescriptors
        )
        guard identities.count == recordsPerCheckpoint else {
            throw ProbeError.resourceSampleFailed
        }
        let rootURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        guard initialRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors else {
            throw ProbeError.resourceSampleFailed
        }
        let orphanURLs = try injectImmutableOrphans(
            count: immutableOrphanCount,
            generation: initialRoot.generation,
            directory: segmentDirectory,
            sampleKey: identities[0].key
        )
        defer {
            for url in orphanURLs {
                _ = url.path.withCString { Darwin.chflags($0, 0) }
            }
        }
        let blockedCleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: initialRoot,
            directory: segmentDirectory
        )
        let initialEntryCount = try segmentEntryCount(segmentDirectory)
        let availableBeforeMutation = try SegmentedManifestSegmentCleanupV1
            .availableMaterializationEntries(directory: segmentDirectory)
        guard let collapsePlan = try SegmentedManifestRunCollapseV1.plan(
            frozenRoot: initialRoot,
            segmentDirectory: segmentDirectory
        ) else { throw ProbeError.resourceSampleFailed }
        let collapseWouldFit = availableBeforeMutation >= collapsePlan.outputRunCount
        let fullCompactionWouldFit = availableBeforeMutation >= 1

        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let baseline = await store!.resourceProbeManifestShadowSnapshot()
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_500_000_000
        )
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalOrphans = try orphanCount(root: finalRoot, directory: segmentDirectory)
        let finalEntryCount = try segmentEntryCount(segmentDirectory)
        let physicalExact = baseline.entries.allSatisfy { key, before in
            finalSnapshot.entries[key]?.physicalID == before.physicalID
        }
        let sample = identities[0]
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil

        var debtReopen: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let debtReopenSnapshot = await debtReopen!.resourceProbeManifestShadowSnapshot()
        let debtReopenRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let reopenWithDebtExact = debtReopenSnapshot == finalSnapshot && debtReopenRoot == finalRoot
        debtReopen = nil

        for url in orphanURLs {
            guard url.path.withCString({ Darwin.chflags($0, 0) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let repairedCleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: finalRoot,
            directory: segmentDirectory
        )
        let finalSegmentExact = try segmentSetExactlyReferenced(
            root: finalRoot,
            directory: segmentDirectory
        )
        let repairedReopen = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let repairedSnapshot = await repairedReopen.resourceProbeManifestShadowSnapshot()
        let repairedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let finalReopenExact = repairedSnapshot == finalSnapshot && repairedRoot == finalRoot

        let report = Schema5HardCapDebtFallbackReport(
            schemaVersion: 1,
            maximumDirectoryEntries: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries,
            initialRunCount: initialRoot.runs.count,
            initialSegmentEntryCount: initialEntryCount,
            injectedImmutableOrphanCount: immutableOrphanCount,
            cleanupRemainingDebtBeforeMutation: blockedCleanup.remainingDebtCount,
            availableMaterializationEntriesBeforeMutation: availableBeforeMutation,
            collapsePlanOutputRunCount: collapsePlan.outputRunCount,
            collapsePlanInputRunBytes: collapsePlan.inputRunBytes,
            collapsePlanOutputRunBytes: collapsePlan.outputRunBytes,
            collapseMaterializationWouldFit: collapseWouldFit,
            oneFileFullCompactionWouldFit: fullCompactionWouldFit,
            hardBoundaryCheckpointSucceeded: finalRoot.generation > initialRoot.generation,
            initialBaseFileName: initialRoot.base.fileName,
            finalBaseFileName: finalRoot.base.fileName,
            fullBaseFallbackObserved:
                finalRoot.base.fileName != initialRoot.base.fileName && finalRoot.runs.count == 1,
            finalRunCountWithDebt: finalRoot.runs.count,
            finalOrphanCountWithDebt: finalOrphans,
            finalSegmentEntryCountWithDebt: finalEntryCount,
            physicalOwnershipExact: physicalExact,
            authorityCountExact: finalSnapshot.entries.count == recordsPerCheckpoint,
            sampleReadable: sampleReadable,
            reopenWithDebtExact: reopenWithDebtExact,
            cleanupDeletedCountAfterRepair: repairedCleanup.deletedCount,
            cleanupRemainingDebtAfterRepair: repairedCleanup.remainingDebtCount,
            finalSegmentSetExactlyReferenced: finalSegmentExact,
            finalReopenAfterRepairExact: finalReopenExact,
            observations: [
                "collapse-plan-needs-more-headroom-than-remains":
                    initialEntryCount == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries - 1
                        && availableBeforeMutation == 1
                        && collapsePlan.outputRunCount > availableBeforeMutation
                        && !collapseWouldFit,
                "full-base-candidate-still-fits-one-remaining-slot": fullCompactionWouldFit,
                "hard-boundary-selects-lower-headroom-full-base-fallback":
                    finalRoot.base.fileName != initialRoot.base.fileName
                        && finalRoot.runs.count == 1,
                "immutable-orphan-debt-remains-bounded-and-nonauthoritative":
                    finalOrphans == immutableOrphanCount
                        && finalEntryCount == 1 + 1 + immutableOrphanCount,
                "repair-repays-debt-without-changing-authority":
                    repairedCleanup.remainingDebtCount == 0
                        && repairedCleanup.deletedCount == immutableOrphanCount
                        && finalSegmentExact
                        && finalReopenExact,
            ],
            claims: [
                "hardCapStrategyFallsBackOnPrewriteHeadroom": true,
                "physicalDebtDoesNotBecomeAuthority": true,
                "hardCapProgressStillRespectsRecoveryBound": true,
                "formalPerformance": false,
                "physicalDeviceIO": false,
                "powerLoss": false,
                "publicDefault": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard report.observations.values.allSatisfy({ $0 }),
            report.cleanupRemainingDebtBeforeMutation == immutableOrphanCount,
            report.physicalOwnershipExact,
            report.authorityCountExact,
            report.sampleReadable,
            report.reopenWithDebtExact
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func injectImmutableOrphans(
        count: Int,
        generation: UInt64,
        directory: URL,
        sampleKey: String
    ) throws -> [URL] {
        var result: [URL] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let fileName = "run-g\(generation)-\(UUID().uuidString.lowercased()).seg"
            let descriptor = try SegmentedManifestPrototypeV1.writeRun(
                [.tombstone(key: sampleKey)],
                fileName: fileName,
                directory: directory
            )
            let url = directory.appendingPathComponent(descriptor.fileName, isDirectory: false)
            guard url.path.withCString({ Darwin.chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            result.append(url)
        }
        return result
    }

    private static func republishEpoch(
        store: FileBlobStore,
        identities: [Schema5StablePrefixIdentity],
        epochBase: Double
    ) async throws {
        for (index, identity) in identities.enumerated() {
            try await store.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(timeIntervalSinceReferenceDate: epochBase + Double(index))
            )
        }
    }

    private static func segmentEntryCount(_ directory: URL) throws -> Int {
        try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).count
    }

    private static func orphanCount(
        root: SegmentedManifestRootV1,
        directory: URL
    ) throws -> Int {
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referenced = Set([root.base.fileName] + root.runs.map(\.fileName))
        return Set(names).subtracting(referenced).count
    }

    private static func segmentSetExactlyReferenced(
        root: SegmentedManifestRootV1,
        directory: URL
    ) throws -> Bool {
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referenced = Set([root.base.fileName] + root.runs.map(\.fileName))
        return Set(names) == referenced && names.count == referenced.count
    }
}
