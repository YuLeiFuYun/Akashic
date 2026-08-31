import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private enum RescueDebtSelfRestorationProbeError: Error {
    case injectedPreRootFailure
    case invariant(String)
}

private final class RescueDebtRootFaultArm: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var fired = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func shouldFail(_ point: FileBlobStoreSwitchPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard armed, !fired, point == .afterManifestFileSynced else { return false }
        fired = true
        return true
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

private struct RescueDebtSelfRestorationReport: Codable {
    let schemaVersion: Int
    let hardSegmentEntryLimit: Int
    let referencedSegmentsBeforeDebt: Int
    let immutableDebtCount: Int
    let segmentEntriesBeforeFailedRescue: Int
    let availableEntriesBeforeFailedRescue: Int
    let injectedFailurePoint: String
    let failureWasPreRoot: Bool
    let candidateSegmentName: String
    let segmentEntriesAfterFailedRescue: Int
    let candidateIsPhysicalOrphanAfterFailure: Bool
    let bootstrapWithImmutableCandidateSucceeded: Bool
    let immutableCandidateSurvivedBootstrapCleanup: Bool
    let availableEntriesAfterFailedCleanup: Int
    let zeroHeadroomBoundaryRejected: Bool
    let zeroHeadroomRootAndSegmentsUnchanged: Bool
    let zeroHeadroomAuthorityExact: Bool
    let candidateRemovedAfterExternalRepair: Bool
    let availableEntriesAfterCandidateRepair: Int
    let repairedBoundarySucceeded: Bool
    let physicalOwnershipExact: Bool
    let finalAuthorityExact: Bool
    let finalReopenExact: Bool
    let originalImmutableDebtStillPresent: Int
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum SegmentedSchema5RescueDebtSelfRestorationProbe {
    private static let recordsPerCheckpoint = 512
    private static let epochBase = 1_700_000_000.0

    static func run(arguments: [String]) async throws {
        let root = try parseRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        trace("prepare-start")

        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: SegmentedManifestPrototypeV1.maximumRunDescriptors
        )
        trace("prepare-complete")
        guard identities.count == recordsPerCheckpoint else {
            throw RescueDebtSelfRestorationProbeError.invariant("identity-count")
        }

        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let referencedBefore = referencedSegmentNames(root: initialRoot)
        let hardLimit = SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        guard referencedBefore.count < hardLimit else {
            throw RescueDebtSelfRestorationProbeError.invariant("referenced-hard-limit")
        }

        // Fill every materialization slot except one with immutable, non-authoritative debt.
        // The remaining slot can support the normal one-file full-base rescue, but cannot absorb a
        // second candidate when the first pre-root candidate becomes unreclaimable physical debt.
        let immutableDebtCount = hardLimit - referencedBefore.count - 1
        guard immutableDebtCount > 0 else {
            throw RescueDebtSelfRestorationProbeError.invariant("no-debt-room")
        }
        let immutableDebtURLs = try injectImmutableOrphans(
            count: immutableDebtCount,
            generation: initialRoot.generation,
            directory: segmentDirectory,
            sampleKey: identities[0].key
        )
        var immutableCandidateURL: URL?
        defer {
            for url in immutableDebtURLs {
                _ = url.path.withCString { Darwin.chflags($0, 0) }
            }
            if let immutableCandidateURL {
                _ = immutableCandidateURL.path.withCString { Darwin.chflags($0, 0) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let blockedCleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: initialRoot,
            directory: segmentDirectory
        )
        let availableBeforeFailure = try SegmentedManifestSegmentCleanupV1
            .availableMaterializationEntries(directory: segmentDirectory)
        guard blockedCleanup.remainingDebtCount == immutableDebtCount,
            availableBeforeFailure == 1
        else {
            throw RescueDebtSelfRestorationProbeError.invariant("initial-one-slot-headroom")
        }
        trace("one-slot-ready")

        let faultArm = RescueDebtRootFaultArm()
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseCrashProbe.openV4(
            root,
            faultInjector: { point in
                if faultArm.shouldFail(point) {
                    throw RescueDebtSelfRestorationProbeError.injectedPreRootFailure
                }
            }
        )
        let baseline = await store!.resourceProbeManifestShadowSnapshot()
        trace("fault-store-open")
        guard baseline.entries.count == recordsPerCheckpoint else {
            throw RescueDebtSelfRestorationProbeError.invariant("baseline-entry-count")
        }

        try await republishPrefix(
            store: store!,
            identities: identities,
            count: recordsPerCheckpoint - 1
        )
        trace("prefix-ready")
        let beforeBoundaryAuthority = await store!.resourceProbeManifestShadowSnapshot()
        let rootBeforeFailure = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let rootBytesBeforeFailure = try Data(contentsOf: manifestURL)
        let segmentsBeforeFailure = Set(try segmentEntryNames(directory: segmentDirectory))
        let segmentEntriesBeforeFailure = segmentsBeforeFailure.count
        guard hardLimit - segmentEntriesBeforeFailure == 1 else {
            throw RescueDebtSelfRestorationProbeError.invariant("boundary-headroom")
        }

        faultArm.arm()
        var injectedFailureObserved = false
        do {
            try await republishBoundary(store: store!, identity: identities[recordsPerCheckpoint - 1])
            throw RescueDebtSelfRestorationProbeError.invariant("failure-not-injected")
        } catch RescueDebtSelfRestorationProbeError.injectedPreRootFailure {
            injectedFailureObserved = true
        }
        trace("fault-fired")
        guard injectedFailureObserved, faultArm.didFire else {
            throw RescueDebtSelfRestorationProbeError.invariant("fault-not-fired")
        }

        let segmentsAfterFailure = Set(try segmentEntryNames(directory: segmentDirectory))
        let newSegments = segmentsAfterFailure.subtracting(segmentsBeforeFailure)
        guard newSegments.count == 1, let candidateName = newSegments.first else {
            throw RescueDebtSelfRestorationProbeError.invariant("candidate-count")
        }
        let candidateURL = segmentDirectory.appendingPathComponent(candidateName, isDirectory: false)
        immutableCandidateURL = candidateURL
        guard candidateURL.path.withCString({ Darwin.chflags($0, UInt32(UF_IMMUTABLE)) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        trace("candidate-immutable")

        let rootBytesAfterFailure = try Data(contentsOf: manifestURL)
        let rootAfterFailure = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        trace("post-fault-root-readable")
        let failureWasPreRoot = rootBytesAfterFailure == rootBytesBeforeFailure
            && rootAfterFailure == rootBeforeFailure
        let candidateOrphanAfterFailure = !referencedSegmentNames(root: rootAfterFailure)
            .contains(candidateName)
        store = nil

        // Bootstrap must preserve logical authority even when immutable debt prevents cleanup of
        // both the original debt and the failed rescue candidate.
        trace("immutable-candidate-reopen-start")
        var reopened: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        trace("immutable-candidate-reopen-complete")
        let reopenedAuthority = await reopened!.resourceProbeManifestShadowSnapshot()
        let bootstrapSucceeded = reopenedAuthority == beforeBoundaryAuthority
        let candidateSurvivedBootstrap = FileManager.default.fileExists(atPath: candidateURL.path)
        let availableAfterFailedCleanup = try SegmentedManifestSegmentCleanupV1
            .availableMaterializationEntries(directory: segmentDirectory)

        let zeroRootBytesBefore = try Data(contentsOf: manifestURL)
        let zeroSegmentsBefore = try segmentEntryNames(directory: segmentDirectory)
        let zeroAuthorityBefore = await reopened!.resourceProbeManifestShadowSnapshot()
        var zeroBoundaryRejected = false
        trace("zero-headroom-boundary-start")
        do {
            try await republishBoundary(
                store: reopened!,
                identity: identities[recordsPerCheckpoint - 1]
            )
        } catch AkashicError.limitExceeded {
            zeroBoundaryRejected = true
        }
        trace("zero-headroom-boundary-complete")
        let zeroRootBytesAfter = try Data(contentsOf: manifestURL)
        let zeroSegmentsAfter = try segmentEntryNames(directory: segmentDirectory)
        let zeroAuthorityAfter = await reopened!.resourceProbeManifestShadowSnapshot()
        let zeroRootAndSegmentsUnchanged = zeroRootBytesAfter == zeroRootBytesBefore
            && zeroSegmentsAfter == zeroSegmentsBefore
        let zeroAuthorityExact = zeroAuthorityAfter == zeroAuthorityBefore
            && zeroAuthorityAfter == beforeBoundaryAuthority
        reopened = nil

        // Repair only the failed rescue candidate. The original immutable debt remains, so
        // recovering exactly one slot must be sufficient for the same boundary operation.
        guard candidateURL.path.withCString({ Darwin.chflags($0, 0) }) == 0 else {
            throw RescueDebtSelfRestorationProbeError.invariant("candidate-clear-immutable")
        }
        trace("candidate-repair-reopen-start")
        var repaired: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        trace("candidate-repair-reopen-complete")
        let candidateRemovedAfterRepair = !FileManager.default.fileExists(atPath: candidateURL.path)
        let repairedAuthority = await repaired!.resourceProbeManifestShadowSnapshot()
        let availableAfterRepair = try SegmentedManifestSegmentCleanupV1
            .availableMaterializationEntries(directory: segmentDirectory)
        guard repairedAuthority == beforeBoundaryAuthority,
            candidateRemovedAfterRepair,
            availableAfterRepair == 1
        else {
            throw RescueDebtSelfRestorationProbeError.invariant("candidate-repair")
        }

        try await republishBoundary(store: repaired!, identity: identities[recordsPerCheckpoint - 1])
        let finalAuthority = await repaired!.resourceProbeManifestShadowSnapshot()
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        let physicalOwnershipExact = baseline.entries.allSatisfy { key, before in
            finalAuthority.entries[key]?.physicalID == before.physicalID
        }
        let finalAuthorityExact = finalAuthority.entries.count == recordsPerCheckpoint
            && finalRoot.generation > rootBeforeFailure.generation
        repaired = nil

        var finalReopen: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let finalReopenedAuthority = await finalReopen!.resourceProbeManifestShadowSnapshot()
        let finalReopenExact = finalReopenedAuthority == finalAuthority
        finalReopen = nil

        let finalOrphanDebt = try orphanCount(root: finalRoot, directory: segmentDirectory)
        let checks: [String: Bool] = [
            "initial-headroom-is-exactly-one-slot": availableBeforeFailure == 1,
            "pre-root-failure-materializes-one-candidate":
                segmentsAfterFailure.count == segmentEntriesBeforeFailure + 1,
            "fault-leaves-root-authority-unchanged": failureWasPreRoot,
            "failed-candidate-is-physical-not-logical-authority": candidateOrphanAfterFailure,
            "bootstrap-preserves-authority-with-unrepayable-candidate": bootstrapSucceeded,
            "failed-candidate-survives-bootstrap-cleanup": candidateSurvivedBootstrap,
            "failed-candidate-consumes-last-rescue-slot": availableAfterFailedCleanup == 0,
            "zero-headroom-boundary-rejects-before-new-work":
                zeroBoundaryRejected && zeroRootAndSegmentsUnchanged,
            "zero-headroom-rejection-preserves-authority": zeroAuthorityExact,
            "repairing-only-failed-candidate-restores-one-slot":
                candidateRemovedAfterRepair && availableAfterRepair == 1,
            "repaired-boundary-preserves-physical-ownership": physicalOwnershipExact,
            "repaired-boundary-publishes-new-root-authority": finalAuthorityExact,
            "final-reopen-is-exact": finalReopenExact,
            "original-immutable-debt-remains-independent": finalOrphanDebt >= immutableDebtCount,
        ]
        let observations: [String: Bool] = [
            "one-rescue-slot-is-not-self-restoring-under-unrepayable-pre-root-candidate-debt":
                availableBeforeFailure == 1
                    && availableAfterFailedCleanup == 0
                    && zeroBoundaryRejected,
            "physical-candidate-debt-does-not-acquire-logical-authority":
                candidateOrphanAfterFailure && bootstrapSucceeded && zeroAuthorityExact,
            "candidate-debt-alone-moves-progress-from-one-slot-to-zero-slot":
                availableBeforeFailure == 1
                    && availableAfterFailedCleanup == 0
                    && availableAfterRepair == 1,
            "external-candidate-debt-repair-restores-progress-without-changing-payload-ownership":
                candidateRemovedAfterRepair && physicalOwnershipExact && finalReopenExact,
        ]

        let report = RescueDebtSelfRestorationReport(
            schemaVersion: 2,
            hardSegmentEntryLimit: hardLimit,
            referencedSegmentsBeforeDebt: referencedBefore.count,
            immutableDebtCount: immutableDebtCount,
            segmentEntriesBeforeFailedRescue: segmentEntriesBeforeFailure,
            availableEntriesBeforeFailedRescue: availableBeforeFailure,
            injectedFailurePoint: FileBlobStoreSwitchPoint.afterManifestFileSynced.rawValue,
            failureWasPreRoot: failureWasPreRoot,
            candidateSegmentName: candidateName,
            segmentEntriesAfterFailedRescue: segmentsAfterFailure.count,
            candidateIsPhysicalOrphanAfterFailure: candidateOrphanAfterFailure,
            bootstrapWithImmutableCandidateSucceeded: bootstrapSucceeded,
            immutableCandidateSurvivedBootstrapCleanup: candidateSurvivedBootstrap,
            availableEntriesAfterFailedCleanup: availableAfterFailedCleanup,
            zeroHeadroomBoundaryRejected: zeroBoundaryRejected,
            zeroHeadroomRootAndSegmentsUnchanged: zeroRootAndSegmentsUnchanged,
            zeroHeadroomAuthorityExact: zeroAuthorityExact,
            candidateRemovedAfterExternalRepair: candidateRemovedAfterRepair,
            availableEntriesAfterCandidateRepair: availableAfterRepair,
            repairedBoundarySucceeded: finalAuthorityExact,
            physicalOwnershipExact: physicalOwnershipExact,
            finalAuthorityExact: finalAuthorityExact,
            finalReopenExact: finalReopenExact,
            originalImmutableDebtStillPresent: finalOrphanDebt,
            checks: checks,
            observations: observations,
            claims: [
                "logicalAuthorityPhysicalDebtSeparated": true,
                "oneRescueSlotUnconditionallySelfRestoring": false,
                "oneRescueSlotSufficientWhenCandidateDebtRepayable": true,
                "physicalPowerLoss": false,
                "formalPerformance": false,
                "productionReservePolicyRecommendation": false,
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw RescueDebtSelfRestorationProbeError.invariant("report-check")
        }
    }

    private static func republishPrefix(
        store: FileBlobStore,
        identities: [Schema5StablePrefixIdentity],
        count: Int
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
        identity: Schema5StablePrefixIdentity
    ) async throws {
        try await store.resourceProbeRepublishEntry(
            digest: identity.digest,
            partition: identity.partition,
            lastAccess: Date(
                timeIntervalSinceReferenceDate: epochBase + Double(recordsPerCheckpoint - 1)
            )
        )
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

    private static func referencedSegmentNames(root: SegmentedManifestRootV1) -> Set<String> {
        Set([root.base.fileName] + root.runs.map(\.fileName))
    }

    private static func segmentEntryNames(directory: URL) throws -> [String] {
        try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
    }

    private static func orphanCount(
        root: SegmentedManifestRootV1,
        directory: URL
    ) throws -> Int {
        let names = Set(try segmentEntryNames(directory: directory))
        return names.subtracting(referencedSegmentNames(root: root)).count
    }

    private static func parseRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw RescueDebtSelfRestorationProbeError.invariant("arguments") }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    private static func trace(_ phase: String) {
        FileHandle.standardError.write(Data("[rescue-debt] \(phase)\n".utf8))
    }
}
