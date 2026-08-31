import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5CapacityPreflightReport: Codable {
    struct Case: Codable {
        let limitExceeded: Bool
        let rootUnchanged: Bool
        let segmentCountBefore: Int
        let segmentCountAfter: Int
        let activeDistinctKeys: Int
        let identityCommitmentBefore: String
        let identityCommitmentAfterReopen: String
        let reopenExact: Bool
    }

    struct Claims: Codable {
        let backgroundCompaction: Bool
        let productionBackpressurePolicy: Bool
        let formalPerformance: Bool
        let powerLoss: Bool
    }

    let schemaVersion: Int
    let multiKeyOver512: Case
    let runCap64: Case
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5CapacityPreflight(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let multi = try await schema5MultiKeyCapacityCase(
            root: root.appendingPathComponent("multi-key", isDirectory: true)
        )
        let runCap = try await schema5RunCapCase(
            root: root.appendingPathComponent("run-cap", isDirectory: true)
        )
        guard multi.limitExceeded,
            multi.rootUnchanged,
            multi.segmentCountBefore == multi.segmentCountAfter,
            multi.reopenExact,
            runCap.limitExceeded,
            runCap.rootUnchanged,
            runCap.segmentCountBefore == runCap.segmentCountAfter,
            runCap.activeDistinctKeys == 511,
            runCap.reopenExact
        else { throw SegmentedManifestShadowError.invariantViolation }

        let report = Schema5CapacityPreflightReport(
            schemaVersion: 1,
            multiKeyOver512: multi,
            runCap64: runCap,
            claims: .init(
                backgroundCompaction: false,
                productionBackpressurePolicy: false,
                formalPerformance: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5MultiKeyCapacityCase(
        root: URL
    ) async throws -> Schema5CapacityPreflightReport.Case {
        let partition = try CachePartitionID.derive(
            domain: "schema5-capacity-multikey-v1",
            material: Data("shared-partition".utf8)
        )
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        for index in 0..<513 {
            let data = Data("schema5-capacity-multi-\(index)".utf8)
            let digest = BlobDigest.sha256(of: data)
            _ = try await store!.commit(data: data, digest: digest, partition: partition)
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
        store = try await schema5CapacityOpen(root: root)

        let before = await store!.resourceProbeManifestShadowSnapshot()
        guard before.entries.count == 513 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let rootDataBefore = try Data(contentsOf: manifestURL)
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let segmentCountBefore = try BoundedDirectoryReader.names(
            in: segments,
            maximumCount: 256
        ).count

        let limitExceeded: Bool
        do {
            try await store!.removeAll(partition: partition)
            limitExceeded = false
        } catch AkashicError.limitExceeded {
            limitExceeded = true
        }
        let afterFailure = await store!.resourceProbeManifestShadowSnapshot()
        let rootDataAfter = try Data(contentsOf: manifestURL)
        let segmentCountAfter = try BoundedDirectoryReader.names(
            in: segments,
            maximumCount: 256
        ).count
        guard afterFailure.entries == before.entries else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        store = nil
        store = try await schema5CapacityOpen(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let afterCommitment = try schema5IdentityCommitment(reopened.entries)
        let active = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        return .init(
            limitExceeded: limitExceeded,
            rootUnchanged: rootDataAfter == rootDataBefore,
            segmentCountBefore: segmentCountBefore,
            segmentCountAfter: segmentCountAfter,
            activeDistinctKeys: active.distinctKeyCount,
            identityCommitmentBefore: beforeCommitment,
            identityCommitmentAfterReopen: afterCommitment,
            reopenExact: reopened.entries == before.entries && afterCommitment == beforeCommitment
        )
    }

    private static func schema5RunCapCase(
        root: URL
    ) async throws -> Schema5CapacityPreflightReport.Case {
        let baseIdentity = try schema5IntegrationIdentities(prefix: "run-cap-base", count: 1)[0]
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        _ = try await store!.commit(
            data: baseIdentity.data,
            digest: baseIdentity.digest,
            partition: baseIdentity.partition
        )
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let baseShadow = await store!.resourceProbeManifestShadowSnapshot()
        let migration = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil

        guard let baseEntry = baseShadow.entries[baseIdentity.key] else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var currentRoot = migration.root
        let segments = migration.segmentDirectory
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        for index in 0..<SegmentedManifestPrototypeV1.maximumRunDescriptors {
            let entry = SegmentedManifestEntry(
                key: baseIdentity.key,
                physicalID: baseEntry.physicalID,
                partition: baseEntry.partition,
                digest: baseEntry.digest,
                byteCount: baseEntry.byteCount,
                lastAccess: Date(timeIntervalSinceReferenceDate: Double(index + 1))
            )
            currentRoot = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: [.upsert(entry)],
                runFileName: String(format: "run-cap-%03d.seg", index),
                currentRoot: currentRoot,
                rootURL: manifestURL,
                segmentDirectory: segments
            )
        }
        guard currentRoot.runs.count == SegmentedManifestPrototypeV1.maximumRunDescriptors else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        _ = try SegmentedManifestDirectoryHeadPrototypeV1.repairEmptyGeneration(
            generation: currentRoot.generation,
            blobsDirectory: blobs
        )
        store = try await schema5CapacityOpen(root: root)
        let hot = try schema5IntegrationIdentities(prefix: "run-cap-hot", count: 512)
        for index in 0...510 {
            _ = try await store!.commit(
                data: hot[index].data,
                digest: hot[index].digest,
                partition: hot[index].partition
            )
        }
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let activeBefore = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        guard activeBefore.distinctKeyCount == 511 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let beforeCommitment = try schema5IdentityCommitment(before.entries)
        let rootDataBefore = try Data(contentsOf: manifestURL)
        let segmentCountBefore = try BoundedDirectoryReader.names(
            in: segments,
            maximumCount: 256
        ).count
        let limitExceeded: Bool
        do {
            _ = try await store!.commit(
                data: hot[511].data,
                digest: hot[511].digest,
                partition: hot[511].partition
            )
            limitExceeded = false
        } catch AkashicError.limitExceeded {
            limitExceeded = true
        }
        let afterFailure = await store!.resourceProbeManifestShadowSnapshot()
        let activeAfter = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let rootDataAfter = try Data(contentsOf: manifestURL)
        let segmentCountAfter = try BoundedDirectoryReader.names(
            in: segments,
            maximumCount: 256
        ).count
        guard afterFailure.entries == before.entries,
            activeAfter.distinctKeyCount == 511
        else { throw SegmentedManifestShadowError.invariantViolation }
        store = nil
        store = try await schema5CapacityOpen(root: root)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenedActive = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let afterCommitment = try schema5IdentityCommitment(reopened.entries)
        return .init(
            limitExceeded: limitExceeded,
            rootUnchanged: rootDataAfter == rootDataBefore,
            segmentCountBefore: segmentCountBefore,
            segmentCountAfter: segmentCountAfter,
            activeDistinctKeys: reopenedActive.distinctKeyCount,
            identityCommitmentBefore: beforeCommitment,
            identityCommitmentAfterReopen: afterCommitment,
            reopenExact: reopened.entries == before.entries
                && afterCommitment == beforeCommitment
                && reopenedActive.distinctKeyCount == 511
        )
    }

    private static func schema5CapacityOpen(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do { return try await FileBlobStore.open(root: root) }
            catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }
}
