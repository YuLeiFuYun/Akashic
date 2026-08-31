import AkashicCore
import AkashicDisk
import Foundation

enum SegmentedSchema5EpochOperationProbe {
    private static let keyCount = 512
    private static let limits = FileBlobStoreLimits(
        softTotalBytes: 64 * 1_024 * 1_024,
        maximumBlobBytes: 1 * 1_024 * 1_024
    )

    static func run(arguments: [String]) async throws {
        if arguments.count == 3,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/"),
            arguments[2] == "--phase-aliasing"
        {
            try await runPhaseAliasing(
                root: URL(fileURLWithPath: arguments[1], isDirectory: true)
            )
            return
        }
        let root = try parseRoot(arguments)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try identities(prefix: "old", count: keyCount)
        let new = try identities(prefix: "new", count: keyCount)
        let template = root.appendingPathComponent("seed-template", isDirectory: true)
        try await prepareTemplate(root: template, old: old)

        let cases: [(String, [EpochOperation])] = [
            ("remove-512-unique", (0..<512).map(EpochOperation.removeOld)),
            ("add-512-unique", (0..<512).map(EpochOperation.addNew)),
            ("mixed-256-remove-256-add", (0..<256).flatMap { [.removeOld($0), .addNew($0)] }),
            ("remove-readd-256-same-keys", (0..<256).flatMap { [.removeOld($0), .readdOld($0)] }),
            ("remove-readd-512-same-keys", (0..<512).flatMap { [.removeOld($0), .readdOld($0)] }),
            (
                "remove-readd-512-two-rounds",
                (0..<512).flatMap { [.removeOld($0), .readdOld($0)] }
                    + (0..<512).flatMap { [.removeOld($0), .readdOld($0)] }
            ),
            ("remove-one-then-511-noop-removes", [.removeOld(0)] + Array(repeating: .removeOld(0), count: 511)),
            ("add-one-then-511-idempotent-commits", [.addNew(0)] + Array(repeating: .addNew(0), count: 511)),
        ]
        var rows: [EpochOperationCase] = []
        for (name, operations) in cases {
            let caseRoot = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: template, to: caseRoot)
            rows.append(try await runCase(name: name, root: caseRoot, old: old, new: new, operations: operations))
        }

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        let report = EpochOperationReport(
            schemaVersion: 2,
            thresholdDistinctKeysPerEpoch: SegmentedManifestPrototypeV1.maximumRunRecords,
            cases: rows,
            checks: [
                "all-authority-exact-before-reopen": rows.allSatisfy(\.authorityExactBeforeReopen),
                "all-reopen-exact": rows.allSatisfy(\.reopenExact),
                "all-cases-match-effective-distinct-epoch-prediction": rows.allSatisfy(\.exactEpochPrediction),
            ],
            observations: [
                "remove-only-512-checkpoints": byName["remove-512-unique"]?.actualRootGenerationDelta == 1,
                "add-only-512-checkpoints": byName["add-512-unique"]?.actualRootGenerationDelta == 1,
                "mixed-512-distinct-keys-checkpoints": byName["mixed-256-remove-256-add"]?.actualRootGenerationDelta == 1,
                "remove-readd-same-256-keys-does-not-checkpoint": byName["remove-readd-256-same-keys"]?.actualRootGenerationDelta == 0,
                "remove-readd-512-checkpoints-between-remove-and-readd":
                    byName["remove-readd-512-same-keys"]?.actualRootGenerationDelta == 1
                        && byName["remove-readd-512-same-keys"]?.actualFinalActiveDistinctKeys == 1,
                "remove-readd-512-two-rounds-leaves-two-post-checkpoint-keys":
                    byName["remove-readd-512-two-rounds"]?.actualRootGenerationDelta == 2
                        && byName["remove-readd-512-two-rounds"]?.actualFinalActiveDistinctKeys == 2,
                "repeated-noop-remove-does-not-inflate-active-distinct": byName["remove-one-then-511-noop-removes"]?.actualFinalActiveDistinctKeys == 1,
                "idempotent-existing-commit-does-not-inflate-active-distinct": byName["add-one-then-511-idempotent-commits"]?.actualFinalActiveDistinctKeys == 1,
            ],
            claims: [
                "universalSchema5Theorem": false,
                "physicalDeviceIO": false,
                "formalPerformance": false,
                "effectiveAuthorityMutationEpochMechanism": true,
                "productionPolicyRecommendation": false,
            ]
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report)); FileHandle.standardOutput.write(Data([0x0A]))
        guard report.checks.values.allSatisfy({ $0 }) else { throw ProbeError.resourceSampleFailed }
    }

    private static func runPhaseAliasing(root: URL) async throws {
        let preconditionKeyCount = 512
        let futureKeyCount = 510
        let totalKeyCount = preconditionKeyCount + futureKeyCount
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let all = try identities(prefix: "phase", count: totalKeyCount)
        let template = root.appendingPathComponent("seed-template", isDirectory: true)
        try await preparePhaseTemplate(root: template, identities: all)

        let preconditions: [(String, [Int])] = [
            (
                "two-rounds-precondition",
                Array(0..<preconditionKeyCount) + Array(0..<preconditionKeyCount)
            ),
            (
                "paired-precondition",
                (0..<preconditionKeyCount).flatMap { [$0, $0] }
            ),
        ]
        let future = Array(preconditionKeyCount..<totalKeyCount)
        var rows: [EpochPhaseAliasingCase] = []
        for (name, precondition) in preconditions {
            let caseRoot = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: template, to: caseRoot)
            rows.append(
                try await runPhaseAliasingCase(
                    name: name,
                    root: caseRoot,
                    identities: all,
                    precondition: precondition,
                    future: future
                )
            )
        }

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        let rounds = byName["two-rounds-precondition"]!
        let paired = byName["paired-precondition"]!
        let report = EpochPhaseAliasingReport(
            schemaVersion: 1,
            thresholdDistinctKeysPerEpoch: SegmentedManifestPrototypeV1.maximumRunRecords,
            preconditionKeyCount: preconditionKeyCount,
            futureUniqueKeyCount: futureKeyCount,
            cases: rows,
            checks: [
                "both-preconditions-restore-logical-authority": rows.allSatisfy(\.preconditionLogicalAuthorityExact),
                "both-preconditions-rewrite-the-same-key-count":
                    rows.allSatisfy { $0.preconditionPhysicalIDChanges == preconditionKeyCount },
                "identical-future-request-count":
                    rows.allSatisfy { $0.futureRequestCount == futureKeyCount && $0.futureUniqueKeyCount == futureKeyCount },
                "all-final-authority-exact": rows.allSatisfy(\.finalLogicalAuthorityExact),
                "all-reopen-exact": rows.allSatisfy(\.reopenExact),
                "same-final-physical-rewrite-extent":
                    rows.allSatisfy { $0.finalPhysicalIDChanges == totalKeyCount },
            ],
            observations: [
                "preconditions-end-at-different-epoch-phase":
                    rounds.preconditionActiveDistinctKeys == 2
                        && paired.preconditionActiveDistinctKeys == 1,
                "identical-future-stream-checkpoints-only-from-higher-phase":
                    rounds.futureRootGenerationDelta == 1
                        && paired.futureRootGenerationDelta == 0,
                "identical-future-stream-publishes-root-and-run-only-from-higher-phase":
                    rounds.futureRootPublicationCount == 1
                        && rounds.futureSegmentPublicationCount == 1
                        && paired.futureRootPublicationCount == 0
                        && paired.futureSegmentPublicationCount == 0,
                "epoch-phase-changes-future-regular-carrier-work":
                    rounds.futureRegularMetadataWriteBytes > paired.futureRegularMetadataWriteBytes,
            ],
            claims: [
                "formalPerformance": false,
                "physicalDeviceIO": false,
                "crashConsistency": false,
                "epochPhaseIsResourceExplainabilityState": true,
                "productionPolicyRecommendation": false,
                "foveaBusinessSemantics": false,
            ]
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report)); FileHandle.standardOutput.write(Data([0x0A]))
        guard report.checks.values.allSatisfy({ $0 }), report.observations.values.allSatisfy({ $0 })
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runPhaseAliasingCase(
        name: String,
        root: URL,
        identities: [EpochOperationIdentity],
        precondition: [Int],
        future: [Int]
    ) async throws -> EpochPhaseAliasingCase {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        let expected = await store!.resourceProbeManifestShadowSnapshot()

        for index in precondition {
            let identity = identities[index]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
        }

        let afterPrecondition = await store!.resourceProbeManifestShadowSnapshot()
        let preconditionLogicalAuthorityExact = logicalAuthorityEquivalent(
            expected,
            afterPrecondition
        )
        let preconditionPhysicalIDChanges = physicalIDChangeCount(expected, afterPrecondition)
        let preconditionHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let preconditionRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )

        var previous = try phaseRegularCarrierSnapshot(root: root)
        var regularBytes: Int64 = 0
        var rootCount = 0
        var rootBytes: Int64 = 0
        var segmentCount = 0
        var segmentBytes: Int64 = 0
        let manifestPath = root.appendingPathComponent("manifest.json", isDirectory: false).path
        let segmentPrefix = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        ).path + "/"

        for index in future {
            let identity = identities[index]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
            let current = try phaseRegularCarrierSnapshot(root: root)
            for (path, data) in current where previous[path] != data {
                regularBytes += Int64(data.count)
                if path == manifestPath {
                    rootCount += 1
                    rootBytes += Int64(data.count)
                } else if path.hasPrefix(segmentPrefix) {
                    segmentCount += 1
                    segmentBytes += Int64(data.count)
                }
            }
            previous = current
        }

        let final = await store!.resourceProbeManifestShadowSnapshot()
        let finalHead = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let finalLogicalAuthorityExact = logicalAuthorityEquivalent(expected, final)
        let finalPhysicalIDChanges = physicalIDChangeCount(expected, final)
        store = nil
        store = try await FileBlobStore.open(root: root, limits: limits)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenExact = logicalAuthorityEquivalent(expected, reopened)
        store = nil

        return .init(
            name: name,
            preconditionRequestCount: precondition.count,
            preconditionLogicalAuthorityExact: preconditionLogicalAuthorityExact,
            preconditionPhysicalIDChanges: preconditionPhysicalIDChanges,
            preconditionActiveDistinctKeys: preconditionHead.distinctKeyCount,
            preconditionRootRunCount: preconditionRoot.runs.count,
            futureRequestCount: future.count,
            futureUniqueKeyCount: Set(future).count,
            futureRegularMetadataWriteBytes: regularBytes,
            futureRootPublicationCount: rootCount,
            futureRootPublicationBytes: rootBytes,
            futureSegmentPublicationCount: segmentCount,
            futureSegmentPublicationBytes: segmentBytes,
            futureRootGenerationDelta: finalRoot.generation - preconditionRoot.generation,
            finalActiveDistinctKeys: finalHead.distinctKeyCount,
            finalLogicalAuthorityExact: finalLogicalAuthorityExact,
            reopenExact: reopenExact,
            finalPhysicalIDChanges: finalPhysicalIDChanges
        )
    }

    private static func preparePhaseTemplate(
        root: URL,
        identities: [EpochOperationIdentity]
    ) async throws {
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
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        guard snapshot.entries.count == identities.count else {
            throw ProbeError.resourceSampleFailed
        }
        store = nil
    }

    private static func phaseRegularCarrierSnapshot(root: URL) throws -> [String: Data] {
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

    private static func runCase(
        name: String,
        root: URL,
        old: [EpochOperationIdentity],
        new: [EpochOperationIdentity],
        operations: [EpochOperation]
    ) async throws -> EpochOperationCase {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        let initial = await store!.resourceProbeManifestShadowSnapshot()
        let initialRoot = try SegmentedManifestPrototypeV1.readRoot(from: root.appendingPathComponent("manifest.json", isDirectory: false))
        var expected = initial.entries
        var activeDistinct = Set<String>()
        var effectiveDistinct = Set<String>()
        var predictedCheckpoints = 0
        var effectiveMutations = 0

        for operation in operations {
            let identity: EpochOperationIdentity
            let removes: Bool
            switch operation {
            case let .removeOld(index): identity = old[index]; removes = true
            case let .addNew(index): identity = new[index]; removes = false
            case let .readdOld(index): identity = old[index]; removes = false
            }
            let before = expected[identity.key]
            if removes {
                try await store!.remove(digest: identity.digest, partition: identity.partition)
                expected.removeValue(forKey: identity.key)
            } else {
                _ = try await store!.commit(data: identity.data, digest: identity.digest, partition: identity.partition)
                // Pull the authoritative descriptor from the real store after the first effective
                // insertion; equality is checked against the final snapshot below.
                if before == nil {
                    let snapshot = await store!.resourceProbeManifestShadowSnapshot()
                    expected[identity.key] = snapshot.entries[identity.key]
                }
            }
            let after = expected[identity.key]
            if before != after {
                effectiveMutations += 1
                effectiveDistinct.insert(identity.key)
                activeDistinct.insert(identity.key)
                if activeDistinct.count == SegmentedManifestPrototypeV1.maximumRunRecords {
                    predictedCheckpoints += 1
                    activeDistinct.removeAll(keepingCapacity: true)
                }
            }
        }

        let final = await store!.resourceProbeManifestShadowSnapshot()
        let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(from: root.appendingPathComponent("manifest.json", isDirectory: false))
        let authorityExactBeforeReopen = final.entries == expected
        store = nil
        store = try await FileBlobStore.open(root: root, limits: limits)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let reopenExact = reopened.entries == expected
        store = nil

        let generationDelta = finalRoot.generation - initialRoot.generation
        let exactPrediction = Int(generationDelta) == predictedCheckpoints && head.distinctKeyCount == activeDistinct.count
        return .init(
            name: name,
            requestOperationCount: operations.count,
            effectiveAuthorityMutationCount: effectiveMutations,
            effectiveDistinctManifestKeyCount: effectiveDistinct.count,
            predictedCheckpointCount: predictedCheckpoints,
            actualRootGenerationDelta: generationDelta,
            predictedFinalActiveDistinctKeys: activeDistinct.count,
            actualFinalActiveDistinctKeys: head.distinctKeyCount,
            expectedFinalAuthorityCount: expected.count,
            actualFinalAuthorityCount: final.entries.count,
            authorityExactBeforeReopen: authorityExactBeforeReopen,
            reopenExact: reopenExact,
            exactEpochPrediction: exactPrediction
        )
    }

    private static func prepareTemplate(root: URL, old: [EpochOperationIdentity]) async throws {
        var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        for identity in old {
            _ = try await store!.commit(data: identity.data, digest: identity.digest, partition: identity.partition)
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else { throw ProbeError.resourceSampleFailed }
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
    }

    private static func identities(prefix: String, count: Int) throws -> [EpochOperationIdentity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "schema5-epoch-operation-v1",
                material: Data("\(prefix)-partition-\(index)".utf8)
            )
            let data = Data("\(prefix)-payload-\(index)".utf8)
            return .init(partition: partition, digest: BlobDigest.sha256(of: data), data: data)
        }
    }

    private static func parseRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--root", arguments[1].hasPrefix("/") else {
            throw ProbeError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }
}
