import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5StablePrefixResourceCase: Codable {
    let name: String
    let preparedPrefixRunCount: Int?
    let suffixSlackRunCount: Int
    let sourceReplayBytesAtPreparation: Int
    let preparedReplacementWriteBytes: Int
    let boundaryValidationReadBytes: Int
    let boundaryTopologyRootWriteBytes: Int
    let boundaryEpochRunWriteBytes: Int
    let boundaryEpochRootWriteBytes: Int
    let totalBoundaryRegularWriteBytes: Int
    let totalInterventionRegularWriteBytes: Int
    let finalRunCount: Int
    let finalReferencedRunBytes: Int
    let finalRootBytes: Int
    let finalAuthorityExact: Bool
    let reopenExact: Bool
    let finalSegmentSetExactlyReferenced: Bool
    let sampleReadable: Bool
}

private struct Schema5StablePrefixResourceReport: Codable {
    struct Claims: Codable {
        let exactMechanismBytes: Bool
        let automaticSchedulingSelected: Bool
        let formalLatency: Bool
        let physicalDeviceIO: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let maximumRunDescriptors: Int
    let preparedPrefixCounts: [Int]
    let cases: [Schema5StablePrefixResourceCase]
    let allChecksPass: Bool
    let claims: Claims
}

enum SegmentedSchema5StablePrefixResourceProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let prefixCounts = [48, 56, 60, 62]
        var rows: [Schema5StablePrefixResourceCase] = []
        for prefixCount in prefixCounts {
            rows.append(
                try await preparedCase(
                    root: root.appendingPathComponent("prefix-\(prefixCount)", isDirectory: true),
                    prefixCount: prefixCount
                )
            )
        }
        rows.append(
            try await synchronousControl(
                root: root.appendingPathComponent("sync-64-control", isDirectory: true)
            )
        )

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        guard let control = byName["sync-64-control"] else { throw ProbeError.resourceSampleFailed }
        let all = rows.allSatisfy { row in
            row.finalAuthorityExact
                && row.reopenExact
                && row.finalSegmentSetExactlyReferenced
                && row.sampleReadable
                && row.finalRunCount > 0
                && row.finalRunCount <= SegmentedManifestPrototypeV1.maximumRunDescriptors
                && row.totalBoundaryRegularWriteBytes > 0
        } && prefixCounts.allSatisfy { prefix in
            guard let row = byName["prefix-\(prefix)"] else { return false }
            return row.preparedPrefixRunCount == prefix
                && row.suffixSlackRunCount == 64 - prefix
                && row.finalRunCount == 67 - prefix
                && row.preparedReplacementWriteBytes > 0
                && row.boundaryValidationReadBytes == row.preparedReplacementWriteBytes
                && row.sourceReplayBytesAtPreparation > 0
                && row.totalBoundaryRegularWriteBytes < control.totalBoundaryRegularWriteBytes
                && row.sourceReplayBytesAtPreparation
                    + row.boundaryValidationReadBytes
                    <= control.boundaryValidationReadBytes
        } && control.preparedPrefixRunCount == nil
            && control.suffixSlackRunCount == 0
            && control.finalRunCount == 3
            && control.preparedReplacementWriteBytes == 0
            && control.sourceReplayBytesAtPreparation == 0

        let report = Schema5StablePrefixResourceReport(
            schemaVersion: 1,
            maximumRunDescriptors: SegmentedManifestPrototypeV1.maximumRunDescriptors,
            preparedPrefixCounts: prefixCounts,
            cases: rows,
            allChecksPass: all,
            claims: .init(
                exactMechanismBytes: true,
                automaticSchedulingSelected: false,
                formalLatency: false,
                physicalDeviceIO: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw ProbeError.resourceSampleFailed }
    }

    private static func preparedCase(
        root: URL,
        prefixCount: Int
    ) async throws -> Schema5StablePrefixResourceCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: prefixCount
        )
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let prepared = try await store!.resourceProbePrepareSegmentedRunPrefixCollapseV4(
            prefixRunCount: prefixCount
        )
        guard let prepared else { throw ProbeError.resourceSampleFailed }
        let suffixCount = SegmentedManifestPrototypeV1.maximumRunDescriptors - prefixCount
        for epoch in 0..<suffixCount {
            try await republishEpoch(
                store: store!,
                identities: identities,
                epochBase: 990_000_000 + Double(epoch * identities.count)
            )
        }
        let hardCapRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        guard hardCapRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors else {
            throw ProbeError.resourceSampleFailed
        }
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 991_000_000 + Double(suffixCount * identities.count)
        )
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let expectedKeys = Set(identities.map(\.key))
        let finalAuthorityExact = finalSnapshot.entries.count == identities.count
            && Set(finalSnapshot.entries.keys) == expectedKeys
        guard let boundaryRun = finalRoot.runs.last else { throw ProbeError.resourceSampleFailed }
        let topologyRuns = Array(finalRoot.runs.dropLast())
        let topologyRoot = try SegmentedManifestPrototypeV1.makeRootPreservingProfile(
            of: finalRoot,
            generation: hardCapRoot.generation,
            base: finalRoot.base,
            runs: topologyRuns
        )
        let topologyRootBytes = try SegmentedManifestPrototypeV1.encodeRoot(topologyRoot).count
        let finalRootBytes = try SegmentedManifestPrototypeV1.encodeRoot(finalRoot).count
        let boundaryWriteBytes = topologyRootBytes + boundaryRun.byteCount + finalRootBytes
        let finalRunBytes = finalRoot.runs.reduce(0) { $0 + $1.byteCount }
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil
        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot

        return .init(
            name: "prefix-\(prefixCount)",
            preparedPrefixRunCount: prefixCount,
            suffixSlackRunCount: suffixCount,
            sourceReplayBytesAtPreparation: prepared.inputRunBytes,
            preparedReplacementWriteBytes: prepared.outputRunBytes,
            boundaryValidationReadBytes: prepared.outputRunBytes,
            boundaryTopologyRootWriteBytes: topologyRootBytes,
            boundaryEpochRunWriteBytes: boundaryRun.byteCount,
            boundaryEpochRootWriteBytes: finalRootBytes,
            totalBoundaryRegularWriteBytes: boundaryWriteBytes,
            totalInterventionRegularWriteBytes: prepared.outputRunBytes + boundaryWriteBytes,
            finalRunCount: finalRoot.runs.count,
            finalReferencedRunBytes: finalRunBytes,
            finalRootBytes: finalRootBytes,
            finalAuthorityExact: finalAuthorityExact,
            reopenExact: reopenExact,
            finalSegmentSetExactlyReferenced: segmentExact,
            sampleReadable: sampleReadable
        )
    }

    private static func synchronousControl(root: URL) async throws -> Schema5StablePrefixResourceCase {
        let identities = try await SegmentedSchema5StablePrefixCollapseProbe.prepareV4Root(
            root: root,
            runCount: SegmentedManifestPrototypeV1.maximumRunDescriptors
        )
        var store: FileBlobStore? = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let hardCapRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let synchronousReplayBytes = hardCapRoot.runs.reduce(0) { $0 + $1.byteCount }
        try await republishEpoch(
            store: store!,
            identities: identities,
            epochBase: 992_000_000
        )
        let finalRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let finalSnapshot = await store!.resourceProbeManifestShadowSnapshot()
        let expectedKeys = Set(identities.map(\.key))
        let finalAuthorityExact = finalSnapshot.entries.count == identities.count
            && Set(finalSnapshot.entries.keys) == expectedKeys
        guard finalRoot.runs.count == 3,
            let boundaryRun = finalRoot.runs.last
        else { throw ProbeError.resourceSampleFailed }
        let collapsedRuns = Array(finalRoot.runs.dropLast())
        let collapseOutputBytes = collapsedRuns.reduce(0) { $0 + $1.byteCount }
        let collapsedRoot = try SegmentedManifestPrototypeV1.makeRootPreservingProfile(
            of: finalRoot,
            generation: hardCapRoot.generation,
            base: finalRoot.base,
            runs: collapsedRuns
        )
        let collapsedRootBytes = try SegmentedManifestPrototypeV1.encodeRoot(collapsedRoot).count
        let finalRootBytes = try SegmentedManifestPrototypeV1.encodeRoot(finalRoot).count
        let boundaryWriteBytes = collapseOutputBytes
            + collapsedRootBytes
            + boundaryRun.byteCount
            + finalRootBytes
        let finalRunBytes = finalRoot.runs.reduce(0) { $0 + $1.byteCount }
        let segmentExact = try segmentSetExactlyReferenced(root: root, manifestRoot: finalRoot)
        let sample = try sampleIdentity(identities)
        let sampleReadable = try await store!.read(
            digest: sample.digest,
            partition: sample.partition
        ) == sample.data
        store = nil
        let reopened = try await SegmentedSchema5StablePrefixCollapseProbe.openV4(root)
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedRoot = try SegmentedSchema5StablePrefixCollapseProbe.readRoot(root)
        let reopenExact = reopenedSnapshot == finalSnapshot && reopenedRoot == finalRoot

        return .init(
            name: "sync-64-control",
            preparedPrefixRunCount: nil,
            suffixSlackRunCount: 0,
            sourceReplayBytesAtPreparation: 0,
            preparedReplacementWriteBytes: 0,
            boundaryValidationReadBytes: synchronousReplayBytes,
            boundaryTopologyRootWriteBytes: collapsedRootBytes,
            boundaryEpochRunWriteBytes: boundaryRun.byteCount,
            boundaryEpochRootWriteBytes: finalRootBytes,
            totalBoundaryRegularWriteBytes: boundaryWriteBytes,
            totalInterventionRegularWriteBytes: boundaryWriteBytes,
            finalRunCount: finalRoot.runs.count,
            finalReferencedRunBytes: finalRunBytes,
            finalRootBytes: finalRootBytes,
            finalAuthorityExact: finalAuthorityExact,
            reopenExact: reopenExact,
            finalSegmentSetExactlyReferenced: segmentExact,
            sampleReadable: sampleReadable
        )
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

    private static func sampleIdentity(
        _ identities: [Schema5StablePrefixIdentity]
    ) throws -> Schema5StablePrefixIdentity {
        guard let first = identities.first else { throw ProbeError.resourceSampleFailed }
        return first
    }

    private static func segmentSetExactlyReferenced(
        root: URL,
        manifestRoot: SegmentedManifestRootV1
    ) throws -> Bool {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        ).filter { SegmentedManifestSegmentCleanupV1.isProductionCanonical($0) }
        let referenced = Set([manifestRoot.base.fileName] + manifestRoot.runs.map(\.fileName))
        return Set(names) == referenced && names.count == referenced.count
    }
}
