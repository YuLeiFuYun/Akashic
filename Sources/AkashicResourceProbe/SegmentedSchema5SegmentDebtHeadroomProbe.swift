import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct Schema5SegmentDebtHeadroomReport: Codable {
    let schemaVersion: Int
    let maximumDirectoryEntries: Int
    let initialReferencedSegmentCount: Int
    let injectedImmutableOrphanCount: Int
    let cleanupRemainingDebtBeforeOpen: Int
    let cleanupFailureCodesBeforeOpen: [Int32]
    let reopenWithDebtSucceeded: Bool
    let orphanCountAfterDebtReopen: Int
    let firstCheckpointSucceeded: Bool
    let runCountAfterFirstCheckpoint: Int
    let segmentEntryCountAfterFirstCheckpoint: Int
    let secondEpochPreBoundaryMutationCount: Int
    let boundaryMutationRejectedWithLimitExceeded: Bool
    let runCountAfterRejectedBoundary: Int
    let segmentEntryCountAfterRejectedBoundary: Int
    let authorityExactAfterRejectedBoundary: Bool
    let sampleReadableAfterRejectedBoundary: Bool
    let retryAfterDebtRepairSucceeded: Bool
    let runCountAfterDebtRepair: Int
    let orphanCountAfterDebtRepair: Int
    let segmentEntryCountAfterDebtRepair: Int
    let physicalOwnershipExact: Bool
    let finalAuthorityCount: Int
    let finalReopenExact: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum SegmentedSchema5SegmentDebtHeadroomProbe {
    private static let recordsPerCheckpoint = 512
    private static let immutableOrphanCount = 128

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: 0
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
        guard initialRoot.runs.isEmpty else { throw ProbeError.resourceSampleFailed }
        let initialReferenced = Set([initialRoot.base.fileName] + initialRoot.runs.map(\.fileName))
        guard initialReferenced.count == 1 else { throw ProbeError.resourceSampleFailed }

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
        guard initialEntryCount == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries - 1
        else { throw ProbeError.resourceSampleFailed }

        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let baseline = await store!.resourceProbeManifestShadowSnapshot()
        let debtRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let debtOrphans = try orphanCount(root: debtRoot, directory: segmentDirectory)
        let reopenWithDebtSucceeded = baseline.entries.count == recordsPerCheckpoint
            && debtOrphans == immutableOrphanCount

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_400_000_000,
            count: recordsPerCheckpoint
        )
        let firstRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let firstEntryCount = try segmentEntryCount(segmentDirectory)
        let firstSnapshot = await store!.resourceProbeManifestShadowSnapshot()

        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 1_401_000_000,
            count: recordsPerCheckpoint - 1
        )
        let beforeBoundarySnapshot = await store!.resourceProbeManifestShadowSnapshot()
        var rejectedWithLimitExceeded = false
        do {
            let finalIdentity = identities[recordsPerCheckpoint - 1]
            try await store!.resourceProbeRepublishEntry(
                digest: finalIdentity.digest,
                partition: finalIdentity.partition,
                lastAccess: Date(
                    timeIntervalSinceReferenceDate:
                        1_401_000_000 + Double(recordsPerCheckpoint - 1)
                )
            )
        } catch AkashicError.limitExceeded {
            rejectedWithLimitExceeded = true
        }
        let rejectedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let rejectedEntryCount = try segmentEntryCount(segmentDirectory)
        let rejectedSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let sample = identities[0]
        let sampleReadableAfterRejected = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data

        for url in orphanURLs {
            guard url.path.withCString({ Darwin.chflags($0, 0) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let finalIdentity = identities[recordsPerCheckpoint - 1]
        try await store!.resourceProbeRepublishEntry(
            digest: finalIdentity.digest,
            partition: finalIdentity.partition,
            lastAccess: Date(
                timeIntervalSinceReferenceDate:
                    1_401_000_000 + Double(recordsPerCheckpoint - 1)
            )
        )
        let repairedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let repairedSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let repairedOrphans = try orphanCount(root: repairedRoot, directory: segmentDirectory)
        let repairedEntryCount = try segmentEntryCount(segmentDirectory)
        let physicalOwnershipExact = baseline.entries.allSatisfy { key, before in
            repairedSnapshot.entries[key]?.physicalID == before.physicalID
        }
        let repairedSegmentExact = try segmentSetExactlyReferenced(
            root: repairedRoot,
            directory: segmentDirectory
        )
        store = nil

        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
        let finalReopenExact = reopenedSnapshot == repairedSnapshot && reopenedRoot == repairedRoot

        let report = Schema5SegmentDebtHeadroomReport(
            schemaVersion: 1,
            maximumDirectoryEntries: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries,
            initialReferencedSegmentCount: initialReferenced.count,
            injectedImmutableOrphanCount: immutableOrphanCount,
            cleanupRemainingDebtBeforeOpen: blockedCleanup.remainingDebtCount,
            cleanupFailureCodesBeforeOpen: blockedCleanup.failures.map(\.posixCode).sorted(),
            reopenWithDebtSucceeded: reopenWithDebtSucceeded,
            orphanCountAfterDebtReopen: debtOrphans,
            firstCheckpointSucceeded: firstRoot.runs.count == 1,
            runCountAfterFirstCheckpoint: firstRoot.runs.count,
            segmentEntryCountAfterFirstCheckpoint: firstEntryCount,
            secondEpochPreBoundaryMutationCount: recordsPerCheckpoint - 1,
            boundaryMutationRejectedWithLimitExceeded: rejectedWithLimitExceeded,
            runCountAfterRejectedBoundary: rejectedRoot.runs.count,
            segmentEntryCountAfterRejectedBoundary: rejectedEntryCount,
            authorityExactAfterRejectedBoundary: rejectedSnapshot == beforeBoundarySnapshot,
            sampleReadableAfterRejectedBoundary: sampleReadableAfterRejected,
            retryAfterDebtRepairSucceeded: repairedRoot.runs.count == 2,
            runCountAfterDebtRepair: repairedRoot.runs.count,
            orphanCountAfterDebtRepair: repairedOrphans,
            segmentEntryCountAfterDebtRepair: repairedEntryCount,
            physicalOwnershipExact: physicalOwnershipExact,
            finalAuthorityCount: repairedSnapshot.entries.count,
            finalReopenExact: finalReopenExact,
            finalSegmentSetExactlyReferenced: repairedSegmentExact,
            observations: [
                "bounded-owned-orphan-debt-does-not-become-authority":
                    blockedCleanup.remainingDebtCount == immutableOrphanCount
                        && blockedCleanup.failures.allSatisfy { $0.posixCode == EPERM }
                        && reopenWithDebtSucceeded,
                "debt-consumes-same-segment-directory-headroom":
                    firstRoot.runs.count == 1
                        && firstEntryCount
                            == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries,
                "next-checkpoint-is-backpressured-before-new-segment-write":
                    rejectedWithLimitExceeded
                        && rejectedRoot.runs.count == 1
                        && rejectedEntryCount
                            == SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
                        && rejectedSnapshot == beforeBoundarySnapshot,
                "repairing-external-condition-repays-debt-and-restores-progress":
                    repairedRoot.runs.count == 2
                        && repairedOrphans == 0
                        && repairedEntryCount == 3,
            ],
            claims: [
                "boundedPhysicalSegmentDebt": true,
                "logicalAuthorityIndependentOfCleanupDebt": true,
                "segmentDebtConsumesRecoveryHeadroom": true,
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
            report.finalAuthorityCount == recordsPerCheckpoint,
            report.finalReopenExact,
            report.finalSegmentSetExactlyReferenced,
            firstSnapshot.entries.count == recordsPerCheckpoint
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
        epochBase: Double,
        count: Int
    ) async throws {
        guard count >= 0, count <= identities.count else { throw ProbeError.invalidArguments }
        for index in 0..<count {
            let identity = identities[index]
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
