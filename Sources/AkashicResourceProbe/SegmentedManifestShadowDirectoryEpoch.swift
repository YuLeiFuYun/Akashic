import AkashicCore
import AkashicDisk
import Foundation

struct SegmentedDirectoryEpochReport: Codable {
    let schemaVersion: Int
    let checkpointRecordLimit: Int
    let hotMutationOperations: Int
    let hotActiveSequence: UInt64
    let hotDistinctKeyCount: Int
    let hotSealedRunRecords: Int
    let hotSealedRunBytes: Int
    let hotRunReconstructsManifest: Bool
    let distinctGenerationBeforeBoundary: UInt64
    let distinctActiveSequenceBeforeBoundary: UInt64
    let distinctKeyCountBeforeBoundary: Int
    let distinctSealedRunRecords: Int
    let distinctSealedRunBytes: Int
    let distinctRunReconstructsManifest: Bool
    let generationAfterBoundary: UInt64
    let activeDistinctKeysAfterBoundary: Int
    let liveEntriesAfterBoundary: Int
    let fullSnapshotBytesAfterBoundary: Int
    let boundaryAdvancedGenerationAndClearedActiveEpoch: Bool
    let syntheticHistoryEntries: Int
    let syntheticFinalEntries: Int
    let syntheticHistoryBaseBytes: Int
    let syntheticEpochRunBytes: Int
    let syntheticEquivalentFullBaseBytes: Int
    let epochRunPreservesLargeHistoryExactly: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let productionAuthorityChanged: Bool
        let checkpointReplacementQualified: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    private struct EpochIdentity {
        let data: Data
        let digest: BlobDigest
        let partition: CachePartitionID
    }

    static func directoryEpochShadow(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let checkpointLimit = FileBlobStore.resourceProbeManifestCheckpointRecordLimit
        guard checkpointLimit == maximumRunRecords else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let hot = try await directoryEpochHotCase(
            root: root.appendingPathComponent("hot", isDirectory: true)
        )
        let distinct = try await directoryEpochDistinctCase(
            root: root.appendingPathComponent("distinct", isDirectory: true),
            checkpointLimit: checkpointLimit
        )

        let syntheticHistoryEntries = try makeBaseEntries(count: 4_096)
        let syntheticHistory = Dictionary(
            uniqueKeysWithValues: syntheticHistoryEntries.map { ($0.key, $0) }
        )
        let syntheticFinal = try apply(distinct.mutations, to: syntheticHistory)
        let syntheticBaseData = try encodeBase(syntheticHistoryEntries)
        let syntheticFullData = try encodeBase(syntheticFinal.values.sorted { $0.key < $1.key })
        let epochRunPreservesLargeHistoryExactly = syntheticFinal.count
            == syntheticHistory.count + distinct.mutations.count
        guard epochRunPreservesLargeHistoryExactly else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let report = SegmentedDirectoryEpochReport(
            schemaVersion: 1,
            checkpointRecordLimit: checkpointLimit,
            hotMutationOperations: hot.operationCount,
            hotActiveSequence: hot.epoch.activeSequence,
            hotDistinctKeyCount: hot.epoch.distinctKeyCount,
            hotSealedRunRecords: hot.mutations.count,
            hotSealedRunBytes: hot.runBytes,
            hotRunReconstructsManifest: hot.exact,
            distinctGenerationBeforeBoundary: distinct.generationBefore,
            distinctActiveSequenceBeforeBoundary: distinct.epoch.activeSequence,
            distinctKeyCountBeforeBoundary: distinct.epoch.distinctKeyCount,
            distinctSealedRunRecords: distinct.mutations.count,
            distinctSealedRunBytes: distinct.runBytes,
            distinctRunReconstructsManifest: distinct.exact,
            generationAfterBoundary: distinct.generationAfter,
            activeDistinctKeysAfterBoundary: distinct.activeCountAfter,
            liveEntriesAfterBoundary: distinct.liveCountAfter,
            fullSnapshotBytesAfterBoundary: distinct.fullSnapshotBytesAfter,
            boundaryAdvancedGenerationAndClearedActiveEpoch: distinct.boundaryExact,
            syntheticHistoryEntries: syntheticHistory.count,
            syntheticFinalEntries: syntheticFinal.count,
            syntheticHistoryBaseBytes: syntheticBaseData.count,
            syntheticEpochRunBytes: distinct.runBytes,
            syntheticEquivalentFullBaseBytes: syntheticFullData.count,
            epochRunPreservesLargeHistoryExactly: true,
            claims: .init(
                productionFormat: false,
                productionAuthorityChanged: false,
                checkpointReplacementQualified: false,
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

    private static func directoryEpochHotCase(
        root: URL
    ) async throws -> (
        operationCount: Int,
        epoch: FileBlobStoreDirectoryHeadEpochShadowSnapshot,
        mutations: [SegmentedShadowMutation],
        runBytes: Int,
        exact: Bool
    ) {
        try StorageDirectorySecurity.prepareDirectory(root)
        let identity = try epochIdentity(label: "hot", payloadByte: 0x48)
        let store = try await FileBlobStore.open(root: root)
        guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store.commit(
            data: identity.data,
            digest: identity.digest,
            partition: identity.partition
        )
        var operationCount = 1
        for _ in 0..<64 {
            try await store.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
            operationCount += 2
        }
        let epoch = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let manifest = await store.resourceProbeManifestShadowSnapshot()
        let mutations = try segmentedMutations(epoch.mutations)
        let runData = try encodeRun(mutations)
        let reconstructed = try apply(mutations, to: [:])
        let exact = reconstructed == segmentedState(manifest.entries)
        guard epoch.distinctKeyCount == 1,
            epoch.activeSequence == UInt64(operationCount),
            mutations.count == 1,
            exact
        else { throw SegmentedManifestShadowError.invariantViolation }
        return (operationCount, epoch, mutations, runData.count, true)
    }

    private static func directoryEpochDistinctCase(
        root: URL,
        checkpointLimit: Int
    ) async throws -> (
        generationBefore: UInt64,
        epoch: FileBlobStoreDirectoryHeadEpochShadowSnapshot,
        mutations: [SegmentedShadowMutation],
        runBytes: Int,
        exact: Bool,
        generationAfter: UInt64,
        activeCountAfter: Int,
        liveCountAfter: Int,
        fullSnapshotBytesAfter: Int,
        boundaryExact: Bool
    ) {
        try StorageDirectorySecurity.prepareDirectory(root)
        let store = try await FileBlobStore.open(root: root)
        guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var identities: [EpochIdentity] = []
        identities.reserveCapacity(checkpointLimit)
        for index in 0..<checkpointLimit {
            let identity = try epochIdentity(label: "distinct-\(index)", payloadByte: 0x44)
            identities.append(identity)
        }
        for identity in identities.prefix(checkpointLimit - 1) {
            _ = try await store.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        let epoch = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let beforeManifest = await store.resourceProbeManifestShadowSnapshot()
        let mutations = try segmentedMutations(epoch.mutations)
        let runData = try encodeRun(mutations)
        let reconstructed = try apply(mutations, to: [:])
        let exact = reconstructed == segmentedState(beforeManifest.entries)
        guard epoch.distinctKeyCount == checkpointLimit - 1,
            epoch.activeSequence == UInt64(checkpointLimit - 1),
            mutations.count == checkpointLimit - 1,
            exact
        else { throw SegmentedManifestShadowError.invariantViolation }

        let boundaryIdentity = identities[checkpointLimit - 1]
        _ = try await store.commit(
            data: boundaryIdentity.data,
            digest: boundaryIdentity.digest,
            partition: boundaryIdentity.partition
        )
        let afterManifest = await store.resourceProbeManifestShadowSnapshot()
        let afterEpoch = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        let fullSnapshotBytes = try await store.resourceProbeEncodedManifestSnapshot().count
        let generationAdvance = beforeManifest.generation.addingReportingOverflow(1)
        guard !generationAdvance.overflow else { throw SegmentedManifestShadowError.invalidFormat }
        let boundaryExact = afterManifest.generation == generationAdvance.partialValue
            && afterEpoch.generation == afterManifest.generation
            && afterEpoch.distinctKeyCount == 0
            && afterEpoch.activeSequence == 0
            && afterManifest.entries.count == checkpointLimit
        guard boundaryExact else { throw SegmentedManifestShadowError.invariantViolation }
        return (
            beforeManifest.generation,
            epoch,
            mutations,
            runData.count,
            true,
            afterManifest.generation,
            afterEpoch.distinctKeyCount,
            afterManifest.entries.count,
            fullSnapshotBytes,
            true
        )
    }

    private static func epochIdentity(label: String, payloadByte: UInt8) throws -> EpochIdentity {
        let data = Data([payloadByte])
        let digest = BlobDigest.sha256(of: data)
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-directory-epoch-v1",
            material: Data(label.utf8)
        )
        return EpochIdentity(data: data, digest: digest, partition: partition)
    }

    private static func segmentedMutations(
        _ source: [FileBlobStoreRecordShadowMutation]
    ) throws -> [SegmentedShadowMutation] {
        try source.map { mutation in
            guard let entry = mutation.entry else {
                return .tombstone(key: mutation.key)
            }
            let converted = SegmentedShadowEntry(
                key: mutation.key,
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
            guard converted.key == FileBlobStore.resourceProbeManifestKey(
                digest: converted.digest,
                partition: converted.partition
            ) else { throw SegmentedManifestShadowError.invalidFormat }
            return .upsert(converted)
        }.sorted { $0.key < $1.key }
    }

    private static func segmentedState(
        _ source: [String: FileBlobStoreRecordShadowEntry]
    ) -> [String: SegmentedShadowEntry] {
        source.mapValues { entry in
            SegmentedShadowEntry(
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: entry.digest,
                    partition: entry.partition
                ),
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }
}
