import AkashicCore
import AkashicDisk
import Foundation

private final class Schema5LocalityOrderHeadCounter: @unchecked Sendable {
    struct Snapshot: Codable {
        let recordSetCalls: Int
        let recordSetValueBytes: Int64
        let headSetCalls: Int
        let headSetValueBytes: Int64
        let removeCalls: Int
        let synchronizeDirectoryCalls: Int
    }
    private let lock = NSLock()
    private var recordSetCalls = 0
    private var recordSetValueBytes: Int64 = 0
    private var headSetCalls = 0
    private var headSetValueBytes: Int64 = 0
    private var removeCalls = 0
    private var synchronizeDirectoryCalls = 0

    func recordSet(name: String, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        if name.hasPrefix("dev.akashic.md1.") {
            recordSetCalls += 1; recordSetValueBytes += Int64(bytes)
        } else if name.hasPrefix("dev.akashic.mh1.") {
            headSetCalls += 1; headSetValueBytes += Int64(bytes)
        }
    }
    func recordRemove() { lock.lock(); removeCalls += 1; lock.unlock() }
    func recordSynchronize() { lock.lock(); synchronizeDirectoryCalls += 1; lock.unlock() }
    func reset() {
        lock.lock()
        recordSetCalls = 0; recordSetValueBytes = 0
        headSetCalls = 0; headSetValueBytes = 0
        removeCalls = 0; synchronizeDirectoryCalls = 0
        lock.unlock()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(
            recordSetCalls: recordSetCalls,
            recordSetValueBytes: recordSetValueBytes,
            headSetCalls: headSetCalls,
            headSetValueBytes: headSetValueBytes,
            removeCalls: removeCalls,
            synchronizeDirectoryCalls: synchronizeDirectoryCalls
        )
    }
}

private struct Schema5LocalityOrderIdentity {
    let partition: CachePartitionID
    let digest: BlobDigest
    let data: Data
    var key: String { FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition) }
}

private struct Schema5LocalityOrderCase: Codable {
    let name: String
    let pairCount: Int
    let uniqueKeyCount: Int
    let perKeyFrequency: Int
    let foregroundPayloadBytesSubmitted: Int64
    let directoryHeadValueWriteBytes: Int64
    let regularMetadataWriteBytes: Int64
    let totalLogicalMetadataCarrierBytes: Int64
    let rootPublicationCount: Int
    let rootPublicationBytes: Int64
    let segmentPublicationCount: Int
    let segmentPublicationBytes: Int64
    let finalActiveDistinctKeys: Int
    let finalRootRunCount: Int
    let finalRootGeneration: UInt64
    let directoryHead: Schema5LocalityOrderHeadCounter.Snapshot
    let logicalAuthorityExactBeforeReopen: Bool
    let logicalReopenExact: Bool
    let physicalIDChangesBeforeReopen: Int
    let physicalIDChangesAfterReopen: Int
}

private struct Schema5LocalityOrderReport: Codable {
    let schemaVersion: Int
    let thresholdDistinctKeysPerEpoch: Int
    let cases: [Schema5LocalityOrderCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum SegmentedSchema5LocalityOrderIOProbe {
    private static let payloadBytes = 64
    private static let defaultKeyCount = 512
    private static let maximumResearchKeyCount = 2_048
    private static let limits = FileBlobStoreLimits(
        softTotalBytes: 64 * 1_024 * 1_024,
        maximumBlobBytes: 1 * 1_024 * 1_024
    )

    static func run(arguments: [String]) async throws {
        let (root, keyCount) = try parseArguments(arguments)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identities = try makeIdentities(count: keyCount)
        let template = root.appendingPathComponent("seed-template", isDirectory: true)
        try await prepareTemplate(root: template, identities: identities)

        let sequences: [(String, [Int])] = [
            ("two-rounds", Array(0..<keyCount) + Array(0..<keyCount)),
            ("paired", (0..<keyCount).flatMap { [$0, $0] }),
        ]
        var rows: [Schema5LocalityOrderCase] = []
        for (name, sequence) in sequences {
            let caseRoot = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: template, to: caseRoot)
            rows.append(
                try await runCase(
                    name: name,
                    root: caseRoot,
                    identities: identities,
                    sequence: sequence
                )
            )
        }

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        let rounds = byName["two-rounds"]!
        let paired = byName["paired"]!
        let checks: [String: Bool] = [
            "same-pair-count": rounds.pairCount == paired.pairCount && rounds.pairCount == 2 * keyCount,
            "same-unique-key-count": rounds.uniqueKeyCount == paired.uniqueKeyCount && rounds.uniqueKeyCount == keyCount,
            "same-per-key-frequency": rounds.perKeyFrequency == paired.perKeyFrequency && rounds.perKeyFrequency == 2,
            "same-foreground-payload-bytes-submitted": rounds.foregroundPayloadBytesSubmitted == paired.foregroundPayloadBytesSubmitted,
            "both-logical-authority-exact-before-reopen": rows.allSatisfy(\.logicalAuthorityExactBeforeReopen),
            "both-logical-reopen-exact": rows.allSatisfy(\.logicalReopenExact),
        ]
        let observations: [String: Bool] = [
            "two-rounds-materializes-more-root-publications-than-paired": rounds.rootPublicationCount > paired.rootPublicationCount,
            "two-rounds-materializes-more-segments-than-paired": rounds.segmentPublicationCount > paired.segmentPublicationCount,
            "two-rounds-ends-with-fewer-active-head-keys": rounds.finalActiveDistinctKeys < paired.finalActiveDistinctKeys,
            "arrival-order-changes-logical-metadata-carrier-bytes": rounds.totalLogicalMetadataCarrierBytes != paired.totalLogicalMetadataCarrierBytes,
        ]
        let report = Schema5LocalityOrderReport(
            schemaVersion: 2,
            thresholdDistinctKeysPerEpoch: SegmentedManifestPrototypeV1.maximumRunRecords,
            cases: rows,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "physicalDeviceIO": false,
                "xattrPhysicalAllocation": false,
                "crashConsistency": false,
                "arrivalOrderWriteAmplificationMechanism": true,
                "productionPolicyRecommendation": false,
            ]
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report)); FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else { throw ProbeError.resourceSampleFailed }
    }

    private static func prepareTemplate(
        root: URL,
        identities: [Schema5LocalityOrderIdentity]
    ) async throws {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        for identity in identities {
            _ = try await store!.commit(data: identity.data, digest: identity.digest, partition: identity.partition)
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw ProbeError.resourceSampleFailed
        }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        let baseline = await store!.resourceProbeManifestShadowSnapshot()
        guard baseline.entries.count == identities.count else { throw ProbeError.resourceSampleFailed }
        store = nil
    }

    private static func runCase(
        name: String,
        root: URL,
        identities: [Schema5LocalityOrderIdentity],
        sequence: [Int]
    ) async throws -> Schema5LocalityOrderCase {
        var baseline: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        let expected = await baseline!.resourceProbeManifestShadowSnapshot()
        guard expected.entries.count == identities.count else { throw ProbeError.resourceSampleFailed }
        baseline = nil

        let counter = Schema5LocalityOrderHeadCounter()
        var store: FileBlobStore? = try await openWithOperations(
            root: root,
            operations: instrumentedOperations(counter: counter)
        )
        counter.reset()
        var previous = try regularCarrierSnapshot(root: root)
        var regularBytes: Int64 = 0
        var rootCount = 0, segmentCount = 0
        var rootBytes: Int64 = 0, segmentBytes: Int64 = 0
        let manifestPath = root.appendingPathComponent("manifest.json", isDirectory: false).path
        let segmentPrefix = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        ).path + "/"

        for index in sequence {
            let identity = identities[index]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store!.commit(data: identity.data, digest: identity.digest, partition: identity.partition)
            let current = try regularCarrierSnapshot(root: root)
            for (path, data) in current where previous[path] != data {
                regularBytes += Int64(data.count)
                if path == manifestPath { rootCount += 1; rootBytes += Int64(data.count) }
                else if path.hasPrefix(segmentPrefix) { segmentCount += 1; segmentBytes += Int64(data.count) }
            }
            previous = current
        }

        let headWrites = counter.snapshot()
        let xattrBytes = headWrites.recordSetValueBytes + headWrites.headSetValueBytes
        let beforeReopen = await store!.resourceProbeManifestShadowSnapshot()
        let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let logicalAuthorityExactBeforeReopen = logicalAuthorityEquivalent(expected, beforeReopen)
        let physicalIDChangesBeforeReopen = physicalIDChangeCount(expected, beforeReopen)
        store = nil
        store = try await FileBlobStore.open(root: root, limits: limits)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let logicalReopenExact = logicalAuthorityEquivalent(expected, reopened)
        let physicalIDChangesAfterReopen = physicalIDChangeCount(expected, reopened)
        store = nil

        return .init(
            name: name,
            pairCount: sequence.count,
            uniqueKeyCount: Set(sequence).count,
            perKeyFrequency: sequence.count / Set(sequence).count,
            foregroundPayloadBytesSubmitted: Int64(sequence.count * payloadBytes),
            directoryHeadValueWriteBytes: xattrBytes,
            regularMetadataWriteBytes: regularBytes,
            totalLogicalMetadataCarrierBytes: xattrBytes + regularBytes,
            rootPublicationCount: rootCount,
            rootPublicationBytes: rootBytes,
            segmentPublicationCount: segmentCount,
            segmentPublicationBytes: segmentBytes,
            finalActiveDistinctKeys: head.distinctKeyCount,
            finalRootRunCount: finalRoot.runs.count,
            finalRootGeneration: finalRoot.generation,
            directoryHead: headWrites,
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

    private static func regularCarrierSnapshot(root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let manifest = root.appendingPathComponent("manifest.json", isDirectory: false)
        result[manifest.path] = try Data(contentsOf: manifest)
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        for name in try BoundedDirectoryReader.names(in: directory, maximumCount: 256) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }

    private static func instrumentedOperations(
        counter: Schema5LocalityOrderHeadCounter
    ) -> FileBlobStoreDirectoryHeadOperations {
        let system = FileBlobStoreDirectoryHeadOperations.system
        return .init(
            listAttributes: system.listAttributes,
            readAttribute: system.readAttribute,
            setAttribute: { name, value, url, flags in
                counter.recordSet(name: name, bytes: value.count)
                try system.setAttribute(name, value, url, flags)
            },
            removeAttribute: { name, url in counter.recordRemove(); try system.removeAttribute(name, url) },
            synchronizeDirectory: { url in counter.recordSynchronize(); try system.synchronizeDirectory(url) }
        )
    }

    private static func openWithOperations(
        root: URL,
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
                await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw ProbeError.resourceSampleFailed
    }

    private static func makeIdentities(count: Int) throws -> [Schema5LocalityOrderIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-locality-order-io-v1",
                material: Data("partition-\(index)".utf8)
            )
            var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: payloadBytes)
            withUnsafeBytes(of: UInt64(index).littleEndian) { encoded in
                for offset in 0..<min(encoded.count, bytes.count) { bytes[offset] = encoded[offset] }
            }
            let data = Data(bytes)
            return .init(partition: partition, digest: BlobDigest.sha256(of: data), data: data)
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> (URL, Int) {
        guard arguments.count == 2 || arguments.count == 4,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }

        var keyCount = defaultKeyCount
        if arguments.count == 4 {
            guard arguments[2] == "--key-count",
                let parsed = Int(arguments[3]),
                parsed > 0,
                parsed <= maximumResearchKeyCount
            else { throw ProbeError.invalidArguments }
            keyCount = parsed
        }
        return (URL(fileURLWithPath: arguments[1], isDirectory: true), keyCount)
    }
}
