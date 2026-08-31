import AkashicCore
import AkashicDisk
import Foundation

enum Schema5LongSequenceCrashError: Error {
    case invalidArguments
    case invalidFixture
    case writerLeaseDidNotRelease
}

enum Schema5LongSequenceStepKind: String, Codable {
    case commitAbsent
    case removePresent
    case compact
    case reopen
}

struct Schema5LongSequenceStep: Codable {
    let index: Int
    let kind: Schema5LongSequenceStepKind
    let poolIndex: Int?

    var label: String? {
        poolIndex.map(SegmentedManifestShadowProbe.schema5LongSequencePoolLabel)
    }
}

struct Schema5LongSequenceIntent: Codable {
    let schemaVersion: Int
    let step: Schema5LongSequenceStep
}

struct Schema5LongSequenceModel: Codable {
    let schemaVersion: Int
    let prefixLogicalMutations: Int
    let acknowledgedSuffixStep: Int?
    let entries: [String: String]
}

struct Schema5LongSequenceReady: Codable {
    let schemaVersion: Int
    let prefixLogicalMutations: Int
    let activeEntryCount: Int
    let generation: UInt64
    let profile: String
    let baseKind: String
    let baseRecordCount: Int
    let runCount: Int
    let recreatedWithChangedPhysicalIDCount: Int
    let targetStep: Int
}

struct Schema5LongSequenceTargetReady: Codable {
    let schemaVersion: Int
    let targetStep: Int
    let kind: Schema5LongSequenceStepKind
    let label: String?
}

struct Schema5LongSequenceCompleted: Codable {
    let schemaVersion: Int
    let completedSuffixSteps: Int
}

struct Schema5LongSequenceInspectEntry: Codable {
    let label: String
    let physicalID: String
    let byteCount: Int
}

struct Schema5LongSequenceInspectReport: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let profile: String
    let baseKind: String
    let baseRecordCount: Int
    let runCount: Int
    let activeEntryCount: Int
    let allPayloadsExact: Bool
    let scaffoldingAbsent: Bool
    let segmentDirectoryEntryCount: Int
    let entries: [Schema5LongSequenceInspectEntry]
}
extension SegmentedManifestShadowProbe {
    private static let schema5LongSequencePrefixLogicalMutations = 1_347
    private static let schema5LongSequencePoolCount = 640
    static let schema5LongSequenceScaffoldLabels = [
        "long-sequence-scaffold-0",
        "long-sequence-scaffold-1",
        "long-sequence-scaffold-2",
    ]

    static func schema5LongSequenceWorker(arguments: [String]) async throws {
        let values = try schema5LongSequenceArguments(arguments)
        guard let rootValue = values["--root"],
            let controlValue = values["--control"],
            let targetValue = values["--target-step"],
            let targetStep = Int(targetValue)
        else { throw Schema5LongSequenceCrashError.invalidArguments }
        let steps = schema5LongSequenceSuffixSteps()
        guard steps.indices.contains(targetStep) else {
            throw Schema5LongSequenceCrashError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let control = URL(fileURLWithPath: controlValue, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(control)
        let modelURL = control.appendingPathComponent("model.json", isDirectory: false)
        let intentURL = control.appendingPathComponent("intent.json", isDirectory: false)
        let readyURL = control.appendingPathComponent("ready.json", isDirectory: false)
        let targetReadyURL = control.appendingPathComponent("target-ready.json", isDirectory: false)
        let goURL = control.appendingPathComponent("go", isDirectory: false)
        let completedURL = control.appendingPathComponent("completed.json", isDirectory: false)
        for url in [modelURL, intentURL, readyURL, targetReadyURL, goURL, completedURL] {
            try? FileManager.default.removeItem(at: url)
        }

        let scaffolding = try schema5MigrationIdentities(labels: schema5LongSequenceScaffoldLabels)
        let pool = try schema5MigrationIdentities(
            labels: (0..<schema5LongSequencePoolCount).map(schema5LongSequencePoolLabel)
        )

        var model: [String: String] = [:]
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        for identity in scaffolding.prefix(2) {
            let publication = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
            model[identityLabel(identity, scaffolding: scaffolding, pool: pool)] =
                publication.physicalID.rawValue.uuidString.lowercased()
        }
        guard try await store!.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw Schema5LongSequenceCrashError.invalidFixture
        }
        let third = scaffolding[2]
        let thirdPublication = try await store!.commit(
            data: third.data,
            digest: third.digest,
            partition: third.partition
        )
        model[schema5LongSequenceScaffoldLabels[2]] =
            thirdPublication.physicalID.rawValue.uuidString.lowercased()
        _ = try await store!.resourceProbeMigrateDirectoryHeadSchema4ToSegmentedV1()
        store = nil
        try schema5LongSequenceTransitionV1ToV3(root: root)
        store = try await schema5LongSequenceOpenV3(root: root)

        var logicalMutations = 0
        for index in scaffolding.indices {
            let identity = scaffolding[index]
            try await store!.remove(digest: identity.digest, partition: identity.partition)
            model.removeValue(forKey: schema5LongSequenceScaffoldLabels[index])
            logicalMutations += 1
        }

        for index in 0..<512 {
            try await schema5LongSequenceCommitAbsent(
                index: index,
                pool: pool,
                store: store!,
                model: &model
            )
            logicalMutations += 1
        }
        _ = try await store!.resourceProbeCompactSegmentedManifestV3()

        var recreatedWithChangedPhysicalIDCount = 0
        for index in 0..<256 {
            let label = schema5LongSequencePoolLabel(index)
            guard let previous = model[label] else {
                throw Schema5LongSequenceCrashError.invalidFixture
            }
            try await schema5LongSequenceRemovePresent(
                index: index,
                pool: pool,
                store: store!,
                model: &model
            )
            logicalMutations += 1
            try await schema5LongSequenceCommitAbsent(
                index: index,
                pool: pool,
                store: store!,
                model: &model
            )
            logicalMutations += 1
            if model[label] != previous { recreatedWithChangedPhysicalIDCount += 1 }
        }
        _ = try await store!.resourceProbeCompactSegmentedManifestV3()
        store = nil
        store = try await schema5LongSequenceOpenV3(root: root)

        for index in 256..<384 {
            try await schema5LongSequenceRemovePresent(
                index: index,
                pool: pool,
                store: store!,
                model: &model
            )
            logicalMutations += 1
        }
        for index in 512..<640 {
            try await schema5LongSequenceCommitAbsent(
                index: index,
                pool: pool,
                store: store!,
                model: &model
            )
            logicalMutations += 1
        }
        for index in 256..<320 {
            try await schema5LongSequenceCommitAbsent(
                index: index,
                pool: pool,
                store: store!,
                model: &model
            )
            logicalMutations += 1
        }
        guard logicalMutations == schema5LongSequencePrefixLogicalMutations else {
            throw Schema5LongSequenceCrashError.invalidFixture
        }
        _ = try await store!.resourceProbeCompactSegmentedManifestV3()
        store = nil
        store = try await schema5LongSequenceOpenV3(root: root)

        try await schema5LongSequenceValidateStore(
            store: store!,
            scaffolding: scaffolding,
            pool: pool,
            expected: model
        )
        let rootMetadata = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try schema5LongSequenceWrite(
            Schema5LongSequenceModel(
                schemaVersion: 1,
                prefixLogicalMutations: logicalMutations,
                acknowledgedSuffixStep: nil,
                entries: model
            ),
            to: modelURL
        )
        try schema5LongSequenceWrite(
            Schema5LongSequenceReady(
                schemaVersion: 1,
                prefixLogicalMutations: logicalMutations,
                activeEntryCount: model.count,
                generation: rootMetadata.generation,
                profile: rootMetadata.profile,
                baseKind: rootMetadata.base.kind.rawValue,
                baseRecordCount: rootMetadata.base.recordCount,
                runCount: rootMetadata.runs.count,
                recreatedWithChangedPhysicalIDCount: recreatedWithChangedPhysicalIDCount,
                targetStep: targetStep
            ),
            to: readyURL
        )

        for step in steps {
            try schema5LongSequenceWrite(
                Schema5LongSequenceIntent(schemaVersion: 1, step: step),
                to: intentURL
            )
            if step.index == targetStep {
                try schema5LongSequenceWrite(
                    Schema5LongSequenceTargetReady(
                        schemaVersion: 1,
                        targetStep: step.index,
                        kind: step.kind,
                        label: step.label
                    ),
                    to: targetReadyURL
                )
                while !FileManager.default.fileExists(atPath: goURL.path) {
                    try await Task.sleep(nanoseconds: 100_000)
                }
            }

            switch step.kind {
            case .commitAbsent:
                guard let index = step.poolIndex else {
                    throw Schema5LongSequenceCrashError.invalidFixture
                }
                try await schema5LongSequenceCommitAbsent(
                    index: index,
                    pool: pool,
                    store: store!,
                    model: &model
                )
            case .removePresent:
                guard let index = step.poolIndex else {
                    throw Schema5LongSequenceCrashError.invalidFixture
                }
                try await schema5LongSequenceRemovePresent(
                    index: index,
                    pool: pool,
                    store: store!,
                    model: &model
                )
            case .compact:
                _ = try await store!.resourceProbeCompactSegmentedManifestV3()
            case .reopen:
                store = nil
                store = try await schema5LongSequenceOpenV3(root: root)
            }

            try schema5LongSequenceWrite(
                Schema5LongSequenceModel(
                    schemaVersion: 1,
                    prefixLogicalMutations: logicalMutations,
                    acknowledgedSuffixStep: step.index,
                    entries: model
                ),
                to: modelURL
            )
        }
        try schema5LongSequenceWrite(
            Schema5LongSequenceCompleted(schemaVersion: 1, completedSuffixSteps: steps.count),
            to: completedURL
        )
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    static func schema5LongSequenceInspect(arguments: [String]) async throws {
        let values = try schema5LongSequenceArguments(arguments)
        guard let rootValue = values["--root"] else {
            throw Schema5LongSequenceCrashError.invalidArguments
        }
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let scaffolding = try schema5MigrationIdentities(labels: schema5LongSequenceScaffoldLabels)
        let pool = try schema5MigrationIdentities(
            labels: (0..<schema5LongSequencePoolCount).map(schema5LongSequencePoolLabel)
        )
        var store: FileBlobStore? = try await schema5LongSequenceOpenV3(root: root)
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        var identitiesByKey: [String: (label: String, identity: MigrationIdentity)] = [:]
        for index in scaffolding.indices {
            identitiesByKey[scaffolding[index].key] = (
                schema5LongSequenceScaffoldLabels[index],
                scaffolding[index]
            )
        }
        for index in pool.indices {
            identitiesByKey[pool[index].key] = (schema5LongSequencePoolLabel(index), pool[index])
        }
        var entries: [Schema5LongSequenceInspectEntry] = []
        var allPayloadsExact = true
        var scaffoldingAbsent = true
        for (key, entry) in snapshot.entries {
            guard let expected = identitiesByKey[key] else {
                throw Schema5LongSequenceCrashError.invalidFixture
            }
            if expected.label.hasPrefix("long-sequence-scaffold-") {
                scaffoldingAbsent = false
            }
            let data = try await store!.read(
                digest: expected.identity.digest,
                partition: expected.identity.partition
            )
            allPayloadsExact = allPayloadsExact && data == expected.identity.data
            entries.append(
                Schema5LongSequenceInspectEntry(
                    label: expected.label,
                    physicalID: entry.physicalID.rawValue.uuidString.lowercased(),
                    byteCount: entry.byteCount
                )
            )
        }
        entries.sort { $0.label < $1.label }
        let segmentedRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let segmentCount = try FileManager.default.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).count
        let report = Schema5LongSequenceInspectReport(
            schemaVersion: 1,
            generation: segmentedRoot.generation,
            profile: segmentedRoot.profile,
            baseKind: segmentedRoot.base.kind.rawValue,
            baseRecordCount: segmentedRoot.base.recordCount,
            runCount: segmentedRoot.runs.count,
            activeEntryCount: entries.count,
            allPayloadsExact: allPayloadsExact,
            scaffoldingAbsent: scaffoldingAbsent,
            segmentDirectoryEntryCount: segmentCount,
            entries: entries
        )
        store = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allPayloadsExact, scaffoldingAbsent else {
            throw Schema5LongSequenceCrashError.invalidFixture
        }
    }

    static func schema5LongSequencePoolLabel(_ index: Int) -> String {
        String(format: "long-sequence-pool-%04d", index)
    }
}
