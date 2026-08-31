import AkashicCore
import AkashicDisk
import Foundation

private final class Schema5LocalityDirectoryHeadCounter: @unchecked Sendable {
    struct Snapshot: Codable {
        let recordSetCalls: Int
        let recordSetValueBytes: Int64
        let headSetCalls: Int
        let headSetValueBytes: Int64
        let otherSetCalls: Int
        let otherSetValueBytes: Int64
        let removeCalls: Int
        let synchronizeDirectoryCalls: Int
    }

    private let lock = NSLock()
    private var recordSetCalls = 0
    private var recordSetValueBytes: Int64 = 0
    private var headSetCalls = 0
    private var headSetValueBytes: Int64 = 0
    private var otherSetCalls = 0
    private var otherSetValueBytes: Int64 = 0
    private var removeCalls = 0
    private var synchronizeDirectoryCalls = 0

    func recordSet(name: String, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        if name.hasPrefix("dev.akashic.md1.") {
            recordSetCalls += 1
            recordSetValueBytes += Int64(bytes)
        } else if name.hasPrefix("dev.akashic.mh1.") {
            headSetCalls += 1
            headSetValueBytes += Int64(bytes)
        } else {
            otherSetCalls += 1
            otherSetValueBytes += Int64(bytes)
        }
    }

    func recordRemove() {
        lock.lock()
        removeCalls += 1
        lock.unlock()
    }

    func recordSynchronize() {
        lock.lock()
        synchronizeDirectoryCalls += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recordSetCalls = 0
        recordSetValueBytes = 0
        headSetCalls = 0
        headSetValueBytes = 0
        otherSetCalls = 0
        otherSetValueBytes = 0
        removeCalls = 0
        synchronizeDirectoryCalls = 0
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            recordSetCalls: recordSetCalls,
            recordSetValueBytes: recordSetValueBytes,
            headSetCalls: headSetCalls,
            headSetValueBytes: headSetValueBytes,
            otherSetCalls: otherSetCalls,
            otherSetValueBytes: otherSetValueBytes,
            removeCalls: removeCalls,
            synchronizeDirectoryCalls: synchronizeDirectoryCalls
        )
    }
}

private struct Schema5LocalityIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data

    var key: String {
        FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
    }
}

private struct Schema5LocalityIOCase: Codable {
    let workingSet: Int
    let pairCount: Int
    let authorityMutationCount: Int
    let foregroundPayloadBytesSubmitted: Int64
    let logicalRegularMetadataWriteBytes: Int64
    let logicalDirectoryHeadValueWriteBytes: Int64
    let logicalMetadataWriteBytes: Int64
    let logicalMetadataBytesPerSubmittedPayloadByte: Double
    let logicalMetadataBytesPerAuthorityMutation: Double
    let rootPublicationCount: Int
    let rootPublicationBytes: Int64
    let segmentPublicationCount: Int
    let segmentPublicationBytes: Int64
    let directoryHead: Schema5LocalityDirectoryHeadCounter.Snapshot
    let finalActiveDistinctKeys: Int
    let finalRootRunCount: Int
    let finalRootGeneration: UInt64
    let initialFootprint: Footprint
    let finalFootprint: Footprint
    let logicalAuthorityExactBeforeReopen: Bool
    let logicalReopenExact: Bool
    let physicalIDChangesBeforeReopen: Int
    let physicalIDChangesAfterReopen: Int
}

private struct Schema5LocalityIOReport: Codable {
    struct Claims: Codable {
        let formalPerformance: Bool
        let physicalDeviceIO: Bool
        let xattrPhysicalAllocation: Bool
        let crashConsistency: Bool
        let writeAmplificationMechanism: Bool
        let authoritySemanticsChanged: Bool
    }

    let schemaVersion: Int
    let seedEntryCount: Int
    let pairCountPerCase: Int
    let payloadBytesPerCommit: Int
    let workingSets: [Int]
    let cases: [Schema5LocalityIOCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: Claims
}

enum SegmentedSchema5LocalityIOProbe {
    private static let seedEntryCount = 512
    private static let pairCount = 512
    private static let payloadBytes = 64
    private static let workingSets = [1, 8, 32, 128, 256, 512]

    static func run(arguments: [String]) async throws {
        let root = try parseRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let identities = try makeIdentities(count: seedEntryCount)
        var rows: [Schema5LocalityIOCase] = []
        rows.reserveCapacity(workingSets.count)
        for workingSet in workingSets {
            trace("case-start ws=\(workingSet)")
            do {
                let row = try await runCase(
                    root: root.appendingPathComponent("ws-\(workingSet)", isDirectory: true),
                    identities: identities,
                    workingSet: workingSet
                )
                rows.append(row)
                trace("case-complete ws=\(workingSet)")
            } catch {
                trace("case-failed ws=\(workingSet) error=\(String(describing: error))")
                throw error
            }
        }

        let checks: [String: Bool] = [
            "all-logical-authority-exact-before-reopen": rows.allSatisfy(\.logicalAuthorityExactBeforeReopen),
            "all-logical-reopen-exact": rows.allSatisfy(\.logicalReopenExact),
            "all-foreground-payload-bytes-equal": Set(rows.map(\.foregroundPayloadBytesSubmitted)).count == 1,
            "all-authority-mutation-counts-equal": Set(rows.map(\.authorityMutationCount)).count == 1,
            "all-directory-head-set-byte-accounting-bounded": rows.allSatisfy {
                $0.logicalDirectoryHeadValueWriteBytes >= 0
                    && $0.directoryHead.otherSetCalls == 0
                    && $0.directoryHead.otherSetValueBytes == 0
            },
            "final-authority-cardinality-preserved": rows.allSatisfy {
                $0.finalFootprint.blobFileCount == seedEntryCount
            },
        ]
        let observations: [String: Bool] = [
            "working-set-512-publishes-segmented-runs": rows.first(where: { $0.workingSet == 512 })
                .map { $0.rootPublicationCount > 0 && $0.segmentPublicationCount > 0 } ?? false,
            "working-sets-below-checkpoint-cardinality-avoid-run-publication": rows.filter {
                $0.workingSet < 512
            }.allSatisfy { $0.rootPublicationCount == 0 && $0.segmentPublicationCount == 0 },
        ]

        let report = Schema5LocalityIOReport(
            schemaVersion: 2,
            seedEntryCount: seedEntryCount,
            pairCountPerCase: pairCount,
            payloadBytesPerCommit: payloadBytes,
            workingSets: workingSets,
            cases: rows,
            checks: checks,
            observations: observations,
            claims: .init(
                formalPerformance: false,
                physicalDeviceIO: false,
                xattrPhysicalAllocation: false,
                crashConsistency: false,
                writeAmplificationMechanism: true,
                authoritySemanticsChanged: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    private static func runCase(
        root: URL,
        identities: [Schema5LocalityIdentity],
        workingSet: Int
    ) async throws -> Schema5LocalityIOCase {
        try? FileManager.default.removeItem(at: root)
        let limits = FileBlobStoreLimits(
            softTotalBytes: 64 * 1_024 * 1_024,
            maximumBlobBytes: 1 * 1_024 * 1_024
        )
        var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        for identity in identities {
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw ProbeError.resourceSampleFailed
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        trace("ws=\(workingSet) stage=seed-migrate-complete")
        let expected = await store!.resourceProbeManifestShadowSnapshot()
        guard expected.entries.count == seedEntryCount else { throw ProbeError.resourceSampleFailed }
        store = nil

        let counter = Schema5LocalityDirectoryHeadCounter()
        let operations = instrumentedDirectoryHeadOperations(counter: counter)
        store = try await openWithOperations(root: root, limits: limits, operations: operations)
        trace("ws=\(workingSet) stage=instrumented-open-complete")
        let initialFootprint = try AkashicResourceProbe.measureFootprint(root: root)
        trace("ws=\(workingSet) stage=initial-footprint-complete")
        var previousMetadata = try regularCarrierSnapshot(root: root)
        counter.reset()

        var regularMetadataWriteBytes: Int64 = 0
        var rootPublicationCount = 0
        var rootPublicationBytes: Int64 = 0
        var segmentPublicationCount = 0
        var segmentPublicationBytes: Int64 = 0
        let manifestPath = root.appendingPathComponent("manifest.json", isDirectory: false).path
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        ).path + "/"

        for index in 0..<pairCount {
            let identity = identities[index % workingSet]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )

            let currentMetadata = try regularCarrierSnapshot(root: root)
            for (path, data) in currentMetadata {
                guard previousMetadata[path] != data else { continue }
                regularMetadataWriteBytes += Int64(data.count)
                if path == manifestPath {
                    rootPublicationCount += 1
                    rootPublicationBytes += Int64(data.count)
                } else if path.hasPrefix(segmentDirectory) {
                    segmentPublicationCount += 1
                    segmentPublicationBytes += Int64(data.count)
                }
            }
            previousMetadata = currentMetadata
        }
        trace("ws=\(workingSet) stage=mutation-loop-complete")

        let directoryHead = counter.snapshot()
        let directoryHeadValueWriteBytes = directoryHead.recordSetValueBytes
            + directoryHead.headSetValueBytes
            + directoryHead.otherSetValueBytes
        let logicalMetadataWriteBytes = regularMetadataWriteBytes + directoryHeadValueWriteBytes
        let foregroundPayloadBytesSubmitted = Int64(pairCount * payloadBytes)
        let authorityMutationCount = pairCount * 2
        let finalHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        trace("ws=\(workingSet) stage=final-head-complete distinct=\(finalHead.distinctKeyCount)")
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
        let logicalAuthorityExactBeforeReopen = logicalAuthorityEquivalent(expected, beforeReopen)
        let physicalIDChangesBeforeReopen = physicalIDChangeCount(expected, beforeReopen)
        let finalFootprint = try AkashicResourceProbe.measureFootprint(root: root)
        trace("ws=\(workingSet) stage=final-footprint-complete")
        store = nil
        trace("ws=\(workingSet) stage=writer-reference-released")

        store = try await FileBlobStore.open(root: root, limits: limits)
        trace("ws=\(workingSet) stage=final-reopen-complete")
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let logicalReopenExact = logicalAuthorityEquivalent(expected, reopened)
        let physicalIDChangesAfterReopen = physicalIDChangeCount(expected, reopened)
        store = nil

        return Schema5LocalityIOCase(
            workingSet: workingSet,
            pairCount: pairCount,
            authorityMutationCount: authorityMutationCount,
            foregroundPayloadBytesSubmitted: foregroundPayloadBytesSubmitted,
            logicalRegularMetadataWriteBytes: regularMetadataWriteBytes,
            logicalDirectoryHeadValueWriteBytes: directoryHeadValueWriteBytes,
            logicalMetadataWriteBytes: logicalMetadataWriteBytes,
            logicalMetadataBytesPerSubmittedPayloadByte: Double(logicalMetadataWriteBytes) / Double(foregroundPayloadBytesSubmitted),
            logicalMetadataBytesPerAuthorityMutation: Double(logicalMetadataWriteBytes) / Double(authorityMutationCount),
            rootPublicationCount: rootPublicationCount,
            rootPublicationBytes: rootPublicationBytes,
            segmentPublicationCount: segmentPublicationCount,
            segmentPublicationBytes: segmentPublicationBytes,
            directoryHead: directoryHead,
            finalActiveDistinctKeys: finalHead.distinctKeyCount,
            finalRootRunCount: finalRoot.runs.count,
            finalRootGeneration: finalRoot.generation,
            initialFootprint: initialFootprint,
            finalFootprint: finalFootprint,
            logicalAuthorityExactBeforeReopen: logicalAuthorityExactBeforeReopen,
            logicalReopenExact: logicalReopenExact,
            physicalIDChangesBeforeReopen: physicalIDChangesBeforeReopen,
            physicalIDChangesAfterReopen: physicalIDChangesAfterReopen
        )
    }

    private static func logicalAuthorityEquivalent(
        _ expected: FileBlobStoreManifestShadowSnapshot,
        _ observed: FileBlobStoreManifestShadowSnapshot
    ) -> Bool {
        guard expected.entries.count == observed.entries.count else { return false }
        return expected.entries.allSatisfy { key, lhs in
            guard let rhs = observed.entries[key] else { return false }
            return lhs.partition == rhs.partition
                && lhs.digest == rhs.digest
                && lhs.byteCount == rhs.byteCount
        }
    }

    private static func physicalIDChangeCount(
        _ expected: FileBlobStoreManifestShadowSnapshot,
        _ observed: FileBlobStoreManifestShadowSnapshot
    ) -> Int {
        expected.entries.reduce(into: 0) { count, item in
            guard let rhs = observed.entries[item.key],
                rhs.physicalID != item.value.physicalID
            else { return }
            count += 1
        }
    }

    /// Snapshot only the regular schema-5 metadata carriers whose bytes can change during the
    /// measured remove+commit loop. Directory-head xattr writes are counted exactly by the custom
    /// operation seam above. Avoiding the general resource snapshot keeps payload-name scans
    /// out of this write-locality mechanism experiment.
    private static func regularCarrierSnapshot(root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let manifest = root.appendingPathComponent("manifest.json", isDirectory: false)
        result[manifest.path] = try Data(contentsOf: manifest)

        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let names = try BoundedDirectoryReader.names(in: segmentDirectory, maximumCount: 256)
        for name in names {
            let url = segmentDirectory.appendingPathComponent(name, isDirectory: false)
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }

    private static func instrumentedDirectoryHeadOperations(
        counter: Schema5LocalityDirectoryHeadCounter
    ) -> FileBlobStoreDirectoryHeadOperations {
        let system = FileBlobStoreDirectoryHeadOperations.system
        return FileBlobStoreDirectoryHeadOperations(
            listAttributes: system.listAttributes,
            readAttribute: system.readAttribute,
            setAttribute: { name, value, url, flags in
                counter.recordSet(name: name, bytes: value.count)
                try system.setAttribute(name, value, url, flags)
            },
            removeAttribute: { name, url in
                counter.recordRemove()
                try system.removeAttribute(name, url)
            },
            synchronizeDirectory: { url in
                counter.recordSynchronize()
                try system.synchronizeDirectory(url)
            }
        )
    }

    private static func openWithOperations(
        root: URL,
        limits: FileBlobStoreLimits,
        operations: FileBlobStoreDirectoryHeadOperations
    ) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.open(
                    root: root,
                    limits: limits,
                    faultInjector: { _ in },
                    directoryHeadOperations: operations
                )
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw ProbeError.resourceSampleFailed
    }

    private static func makeIdentities(count: Int) throws -> [Schema5LocalityIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-locality-io-v1",
                material: Data("partition-\(index)".utf8)
            )
            var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: payloadBytes)
            withUnsafeBytes(of: UInt64(index).littleEndian) { encoded in
                for offset in 0..<min(encoded.count, bytes.count) {
                    bytes[offset] = encoded[offset]
                }
            }
            let data = Data(bytes)
            return Schema5LocalityIdentity(
                partition: partition,
                digest: BlobDigest.sha256(of: data),
                data: data
            )
        }
    }

    private static func trace(_ message: String) {
        FileHandle.standardError.write(Data("[schema5-locality] \(message)\n".utf8))
    }

    private static func parseRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }
}
