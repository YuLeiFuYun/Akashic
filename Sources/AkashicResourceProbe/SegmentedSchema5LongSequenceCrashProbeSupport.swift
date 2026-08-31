import AkashicCore
import AkashicDisk
import Foundation

extension SegmentedManifestShadowProbe {
    static func schema5LongSequenceSuffixSteps() -> [Schema5LongSequenceStep] {
        var steps: [Schema5LongSequenceStep] = []
        func append(_ kind: Schema5LongSequenceStepKind, _ poolIndex: Int? = nil) {
            steps.append(Schema5LongSequenceStep(index: steps.count, kind: kind, poolIndex: poolIndex))
        }
        for index in 0..<64 { append(.removePresent, index) }
        append(.compact)
        for index in 320..<384 { append(.commitAbsent, index) }
        append(.reopen)
        for index in 512..<576 { append(.removePresent, index) }
        append(.compact)
        for index in 0..<64 { append(.commitAbsent, index) }
        append(.reopen)
        return steps
    }

    static func schema5LongSequenceCommitAbsent(
        index: Int,
        pool: [MigrationIdentity],
        store: FileBlobStore,
        model: inout [String: String]
    ) async throws {
        let label = schema5LongSequencePoolLabel(index)
        guard model[label] == nil else { throw Schema5LongSequenceCrashError.invalidFixture }
        let identity = pool[index]
        let publication = try await store.commit(
            data: identity.data,
            digest: identity.digest,
            partition: identity.partition
        )
        model[label] = publication.physicalID.rawValue.uuidString.lowercased()
    }

    static func schema5LongSequenceRemovePresent(
        index: Int,
        pool: [MigrationIdentity],
        store: FileBlobStore,
        model: inout [String: String]
    ) async throws {
        let label = schema5LongSequencePoolLabel(index)
        guard model[label] != nil else { throw Schema5LongSequenceCrashError.invalidFixture }
        let identity = pool[index]
        try await store.remove(digest: identity.digest, partition: identity.partition)
        model.removeValue(forKey: label)
    }

    static func schema5LongSequenceTransitionV1ToV3(root: URL) throws {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let frozenRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard frozenRoot.profile == SegmentedManifestPrototypeV1.profileV1,
            frozenRoot.base.kind == .baseJSON
        else { throw Schema5LongSequenceCrashError.invalidFixture }

        let frozenState = try SegmentedManifestPrototypeV1.recover(
            root: frozenRoot,
            segmentDirectory: segmentDirectory
        )
        let frozenCommitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(
            frozenState
        )
        let candidate = try SegmentedManifestBinaryBaseTransitionV3.prepare(
            frozenRoot: frozenRoot,
            segmentDirectory: segmentDirectory,
            candidateFileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        )
        guard candidate.semanticCommitment == frozenCommitment else {
            throw Schema5LongSequenceCrashError.invalidFixture
        }
        try SegmentedManifestPrototypeV1.writeRoot(candidate.root, to: manifestURL)

        let publishedRoot = try SegmentedManifestPrototypeV1.readRoot(from: manifestURL)
        guard publishedRoot.profile == SegmentedManifestPrototypeV1.profileV3,
            publishedRoot.base.kind == .baseBinaryV2,
            publishedRoot.generation == frozenRoot.generation
        else { throw Schema5LongSequenceCrashError.invalidFixture }
        let publishedState = try SegmentedManifestPrototypeV1.recover(
            root: publishedRoot,
            segmentDirectory: segmentDirectory
        )
        guard try SegmentedManifestPrototypeV1.semanticStateCommitment(publishedState)
            == frozenCommitment
        else { throw Schema5LongSequenceCrashError.invalidFixture }

        let cleanup = try SegmentedManifestSegmentCleanupV1.reclaimUnreferenced(
            root: publishedRoot,
            directory: segmentDirectory
        )
        guard cleanup.remainingDebtCount == 0 else {
            throw Schema5LongSequenceCrashError.invalidFixture
        }
    }

    static func schema5LongSequenceOpenV3(root: URL) async throws -> FileBlobStore {
        for _ in 0..<500 {
            do {
                let store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
                let metadata = try SegmentedManifestPrototypeV1.readRoot(
                    from: root.appendingPathComponent("manifest.json", isDirectory: false)
                )
                guard metadata.profile == SegmentedManifestPrototypeV1.profileV3,
                    metadata.base.kind == .baseBinaryV2
                else { throw Schema5LongSequenceCrashError.invalidFixture }
                return store
            } catch AkashicError.transactionConflict {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5LongSequenceCrashError.writerLeaseDidNotRelease
    }

    static func schema5LongSequenceValidateStore(
        store: FileBlobStore,
        scaffolding: [MigrationIdentity],
        pool: [MigrationIdentity],
        expected: [String: String]
    ) async throws {
        let snapshot = await store.resourceProbeManifestShadowSnapshot()
        var actual: [String: String] = [:]
        var mapping: [String: (String, MigrationIdentity)] = [:]
        for index in scaffolding.indices {
            mapping[scaffolding[index].key] = (schema5LongSequenceScaffoldLabels[index], scaffolding[index])
        }
        for index in pool.indices {
            mapping[pool[index].key] = (schema5LongSequencePoolLabel(index), pool[index])
        }
        for (key, entry) in snapshot.entries {
            guard let mapped = mapping[key] else { throw Schema5LongSequenceCrashError.invalidFixture }
            guard !mapped.0.hasPrefix("long-sequence-scaffold-") else {
                throw Schema5LongSequenceCrashError.invalidFixture
            }
            let data = try await store.read(
                digest: mapped.1.digest,
                partition: mapped.1.partition
            )
            guard data == mapped.1.data else { throw Schema5LongSequenceCrashError.invalidFixture }
            actual[mapped.0] = entry.physicalID.rawValue.uuidString.lowercased()
        }
        guard actual == expected else { throw Schema5LongSequenceCrashError.invalidFixture }
    }

    static func schema5LongSequenceWrite<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFileWriter.writeReplacing(encoder.encode(value), to: url)
    }

    static func schema5LongSequenceArguments(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw Schema5LongSequenceCrashError.invalidArguments
        }
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), result[key] == nil else {
                throw Schema5LongSequenceCrashError.invalidArguments
            }
            result[key] = arguments[index + 1]
            index += 2
        }
        return result
    }

    static func identityLabel(
        _ identity: MigrationIdentity,
        scaffolding: [MigrationIdentity],
        pool: [MigrationIdentity]
    ) -> String {
        if let index = scaffolding.firstIndex(where: { $0.key == identity.key }) {
            return schema5LongSequenceScaffoldLabels[index]
        }
        if let index = pool.firstIndex(where: { $0.key == identity.key }) {
            return schema5LongSequencePoolLabel(index)
        }
        preconditionFailure("unknown long-sequence identity")
    }
}
