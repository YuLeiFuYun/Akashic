import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct Schema5HardCapMinimumRescueReport: Codable {
    let schemaVersion: Int
    let maximumDirectoryEntries: Int
    let initialRunCount: Int
    let initialSegmentEntryCount: Int
    let immutableDebtCountAtFailure: Int
    let availableEntriesAtFailure: Int
    let preBoundaryMutationCount: Int
    let boundaryRejectedWithLimitExceeded: Bool
    let rootUnchangedAfterRejectedBoundary: Bool
    let segmentEntryCountAfterRejectedBoundary: Int
    let authorityExactAfterRejectedBoundary: Bool
    let sampleReadableAfterRejectedBoundary: Bool
    let releasedOrphanCountBeforeRetry: Int
    let retrySucceeded: Bool
    let finalBaseChanged: Bool
    let finalRunCountWithDebt: Int
    let remainingImmutableDebtAfterRetry: Int
    let finalSegmentEntryCountWithDebt: Int
    let physicalOwnershipExact: Bool
    let reopenWithDebtExact: Bool
    let cleanupDeletedCountAfterFinalRepair: Int
    let cleanupRemainingDebtAfterFinalRepair: Int
    let finalSegmentSetExactlyReferenced: Bool
    let finalReopenExact: Bool
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum SegmentedSchema5HardCapMinimumRescueProbe {
    private static let recordsPerCheckpoint = 512
    private static let immutableDebtCount = 65

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
        let orphanURLs = try injectImmutableOrphans(
            count: immutableDebtCount,
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
        let availableAtFailure = try SegmentedManifestSegmentCleanupV1
            .availableMaterializationEntries(directory: segmentDirectory)
        guard initialEntryCount == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries,
            availableAtFailure == 0,
            blockedCleanup.remainingDebtCount == immutableDebtCount
        else { throw ProbeError.resourceSampleFailed }

        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let baseline = await store!.resourceProbeManifestShadowSnapshot()
        try await republishPrefix(
            store: store!,
            identities: identities,
            count: recordsPerCheckpoint - 1,
            epochBase: 1_600_000_000
        )
        let beforeBoundarySnapshot = await store!.resourceProbeManifestShadowSnapshot()
        var rejectedWithLimitExceeded = false
        do {
            try await republishBoundary(
                store: store!,
                identity: identities[recordsPerCheckpoint - 1],
                timestamp: 1_600_000_000 + Double(recordsPerCheckpoint - 1)
            )
        } catch AkashicError.limitExceeded {
            rejectedWithLimitExceeded = true
        }
        let rejectedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let rejectedEntryCount = try segmentEntryCount(segmentDirectory)
        let rejectedSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let sample = identities[0]
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data

        guard let released = orphanURLs.first,
            released.path.withCString({ Darwin.chflags($0, 0) }) == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try await republishBoundary(
            store: store!,
            identity: identities[recordsPerCheckpoint - 1],
            timestamp: 1_600_000_000 + Double(recordsPerCheckpoint - 1)
        )
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let finalOrphans = try orphanCount(root: finalRoot, directory: segmentDirectory)
        let finalEntryCount = try segmentEntryCount(segmentDirectory)
        let physicalExact = baseline.entries.allSatisfy { key, before in
            finalSnapshot.entries[key]?.physicalID == before.physicalID
        }
        store = nil

        var debtReopen: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let debtReopenSnapshot = await debtReopen!.resourceProbeManifestShadowSnapshot()
        let debtReopenRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let reopenWithDebtExact = debtReopenSnapshot == finalSnapshot && debtReopenRoot == finalRoot
        debtReopen = nil

        for url in orphanURLs.dropFirst() {
            guard url.path.withCString({ Darwin.chflags($0, 0) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: finalRoot,
            directory: segmentDirectory
        )
        let segmentExact = try segmentSetExactlyReferenced(
            root: finalRoot,
            directory: segmentDirectory
        )
        let finalReopen = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let finalReopenSnapshot = await finalReopen.resourceProbeManifestShadowSnapshot()
        let finalReopenRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let finalReopenExact = finalReopenSnapshot == finalSnapshot && finalReopenRoot == finalRoot

        let report = Schema5HardCapMinimumRescueReport(
            schemaVersion: 1,
            maximumDirectoryEntries: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries,
            initialRunCount: initialRoot.runs.count,
            initialSegmentEntryCount: initialEntryCount,
            immutableDebtCountAtFailure: blockedCleanup.remainingDebtCount,
            availableEntriesAtFailure: availableAtFailure,
            preBoundaryMutationCount: recordsPerCheckpoint - 1,
            boundaryRejectedWithLimitExceeded: rejectedWithLimitExceeded,
            rootUnchangedAfterRejectedBoundary: rejectedRoot == initialRoot,
            segmentEntryCountAfterRejectedBoundary: rejectedEntryCount,
            authorityExactAfterRejectedBoundary: rejectedSnapshot == beforeBoundarySnapshot,
            sampleReadableAfterRejectedBoundary: sampleReadable,
            releasedOrphanCountBeforeRetry: 1,
            retrySucceeded: finalRoot.generation > initialRoot.generation,
            finalBaseChanged: finalRoot.base.fileName != initialRoot.base.fileName,
            finalRunCountWithDebt: finalRoot.runs.count,
            remainingImmutableDebtAfterRetry: finalOrphans,
            finalSegmentEntryCountWithDebt: finalEntryCount,
            physicalOwnershipExact: physicalExact,
            reopenWithDebtExact: reopenWithDebtExact,
            cleanupDeletedCountAfterFinalRepair: cleanup.deletedCount,
            cleanupRemainingDebtAfterFinalRepair: cleanup.remainingDebtCount,
            finalSegmentSetExactlyReferenced: segmentExact,
            finalReopenExact: finalReopenExact,
            observations: [
                "zero-rescue-slot-backpressures-before-authority-publication":
                    rejectedWithLimitExceeded
                        && rejectedRoot == initialRoot
                        && rejectedEntryCount
                            == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
                        && rejectedSnapshot == beforeBoundarySnapshot,
                "one-repaired-slot-restores-hardcap-progress":
                    finalRoot.base.fileName != initialRoot.base.fileName
                        && finalRoot.runs.count == 1
                        && finalOrphans == immutableDebtCount - 1
                        && finalEntryCount == 1 + 1 + (immutableDebtCount - 1),
                "single-slot-retry-preserves-physical-ownership": physicalExact,
                "remaining-debt-stays-bounded-and-reopenable": reopenWithDebtExact,
                "final-repair-repays-all-debt-without-authority-change":
                    cleanup.deletedCount == immutableDebtCount - 1
                        && cleanup.remainingDebtCount == 0
                        && segmentExact
                        && finalReopenExact,
            ],
            claims: [
                "minimumHardCapRescueSlot": true,
                "zeroSlotBackpressureIsRequired": true,
                "oneSlotFullBaseFallbackRestoresProgress": true,
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
            report.authorityExactAfterRejectedBoundary,
            report.sampleReadableAfterRejectedBoundary,
            report.physicalOwnershipExact,
            report.reopenWithDebtExact,
            report.finalSegmentSetExactlyReferenced,
            report.finalReopenExact
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

    private static func republishPrefix(
        store: FileBlobStore,
        identities: [Schema5StablePrefixIdentity],
        count: Int,
        epochBase: Double
    ) async throws {
        for index in 0..<count {
            let identity = identities[index]
            try await store.resourceProbeRepublishEntry(
                digest: identity.digest,
                partition: identity.partition,
                lastAccess: Date(timeIntervalSinceReferenceDate: epochBase + Double(index))
            )
        }
    }

    private static func republishBoundary(
        store: FileBlobStore,
        identity: Schema5StablePrefixIdentity,
        timestamp: Double
    ) async throws {
        try await store.resourceProbeRepublishEntry(
            digest: identity.digest,
            partition: identity.partition,
            lastAccess: Date(timeIntervalSinceReferenceDate: timestamp)
        )
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
