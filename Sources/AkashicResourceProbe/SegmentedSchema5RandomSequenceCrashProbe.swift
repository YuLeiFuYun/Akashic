import AkashicCore
import AkashicDisk
import Foundation

private enum Schema5RandomSequenceError: Error {
    case invalidArguments
    case invalidFixture
    case invariantViolation
}

private enum Schema5RandomSequenceOperationKind: String, Codable {
    case commitAbsent
    case removePresent
    case reopen
    case compact
    case garbageCollect
}

private struct Schema5RandomSequenceIdentity {
    let label: String
    let data: Data
    let digest: BlobDigest
    let partition: CachePartitionID
}

private struct Schema5RandomSequenceIntent: Codable {
    let schemaVersion: Int
    let step: Int
    let kind: Schema5RandomSequenceOperationKind
    let label: String?
    let byteCount: Int?
    let acknowledgedPreviousStep: Int?
    let modelEntryCountBefore: Int
}

private struct Schema5RandomSequenceModel: Codable {
    let schemaVersion: Int
    let seed: UInt64
    let acknowledgedSuffixStep: Int?
    let entries: [String: String]
}

private struct Schema5RandomSequenceTargetReady: Codable {
    let schemaVersion: Int
    let seed: UInt64
    let targetStep: Int
    let kind: Schema5RandomSequenceOperationKind
    let label: String?
    let acknowledgedPreviousStep: Int?
    let modelEntryCountBefore: Int
    let profile: String
    let baseKind: String
}

private struct Schema5RandomSequenceInspectReport: Codable {
    let schemaVersion: Int
    let profile: String
    let baseKind: String
    let generation: UInt64
    let manifestEntryCount: Int
    let discoveredEntryCount: Int
    let segmentDirectoryEntryCount: Int
    let entries: [String: String]
    let allPayloadsExact: Bool
    let uniquePhysicalOwnership: Bool
    let noUnknownLogicalEntries: Bool
}

private struct Schema5RandomSequencePRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}

extension SegmentedManifestShadowProbe {
    // The long-sequence seed has 576 active entries, but its stable label universe spans
    // long-sequence-pool-0000 ... -0639. Keep universe cardinality separate from current live
    // cardinality or the random model silently forgets live authority in the upper 64 labels and
    // misclassifies the intentionally absent 320 ... 383 range.
    private static let schema5RandomLongSequenceLabelCount = 640
    private static let schema5RandomAdditionalLabelCount = 256
    private static let schema5RandomPayloadSizes = [64, 512, 4_096, 16_384, 65_536]

    static func schema5RandomSequenceWorker(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw Schema5RandomSequenceError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootPath = values["--root"],
            let sampleDirectoryPath = values["--sample-dir"],
            let seedRaw = values["--seed"],
            let seed = UInt64(seedRaw),
            let suffixCountRaw = values["--suffix-count"],
            let suffixCount = Int(suffixCountRaw), suffixCount > 0,
            let targetStepRaw = values["--target-step"],
            let targetStep = Int(targetStepRaw), targetStep >= 0, targetStep < suffixCount,
            let targetReadyPath = values["--target-ready"],
            let goPath = values["--go"]
        else { throw Schema5RandomSequenceError.invalidArguments }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let sampleDirectory = URL(fileURLWithPath: sampleDirectoryPath, isDirectory: true)
        let intentURL = sampleDirectory.appendingPathComponent("intent.json", isDirectory: false)
        let modelURL = sampleDirectory.appendingPathComponent("model.json", isDirectory: false)
        let targetReadyURL = URL(fileURLWithPath: targetReadyPath, isDirectory: false)
        let goURL = URL(fileURLWithPath: goPath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: sampleDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: sampleDirectory.path
        )

        var store: FileBlobStore? = try await schema5RandomOpenV3(root: root)
        var model = try await schema5RandomInitialModel(store: store!, seed: seed)
        try schema5RandomWriteJSON(model, to: modelURL)
        var generator = Schema5RandomSequencePRNG(seed: seed)

        for step in 0..<suffixCount {
            let operation = try schema5RandomChooseOperation(
                generator: &generator,
                currentEntries: model.entries
            )
            let identity = try operation.label.map(schema5RandomIdentity(label:))
            let intent = Schema5RandomSequenceIntent(
                schemaVersion: 1,
                step: step,
                kind: operation.kind,
                label: operation.label,
                byteCount: identity?.data.count,
                acknowledgedPreviousStep: model.acknowledgedSuffixStep,
                modelEntryCountBefore: model.entries.count
            )
            try schema5RandomWriteJSON(intent, to: intentURL)

            if step == targetStep {
                let metadata = try schema5RandomMetadata(root: root)
                try schema5RandomWriteJSON(
                    Schema5RandomSequenceTargetReady(
                        schemaVersion: 1,
                        seed: seed,
                        targetStep: targetStep,
                        kind: operation.kind,
                        label: operation.label,
                        acknowledgedPreviousStep: model.acknowledgedSuffixStep,
                        modelEntryCountBefore: model.entries.count,
                        profile: metadata.profile,
                        baseKind: metadata.base.kind.rawValue
                    ),
                    to: targetReadyURL
                )
                FileHandle.standardOutput.write(Data("RANDOM-TARGET-READY-SETTLED\n".utf8))
                while !FileManager.default.fileExists(atPath: goURL.path) {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }

            var entries = model.entries
            switch operation.kind {
            case .commitAbsent:
                guard let identity, entries[identity.label] == nil else {
                    throw Schema5RandomSequenceError.invariantViolation
                }
                _ = try await store!.commit(
                    data: identity.data,
                    digest: identity.digest,
                    partition: identity.partition
                )
                guard let physical = await store!.physicalID(
                    digest: identity.digest,
                    partition: identity.partition
                ) else { throw Schema5RandomSequenceError.invariantViolation }
                let physicalString = physical.rawValue.uuidString.lowercased()
                guard !entries.values.contains(physicalString) else {
                    throw Schema5RandomSequenceError.invariantViolation
                }
                entries[identity.label] = physicalString
            case .removePresent:
                guard let identity, entries[identity.label] != nil else {
                    throw Schema5RandomSequenceError.invariantViolation
                }
                try await store!.remove(
                    digest: identity.digest,
                    partition: identity.partition
                )
                guard await store!.physicalID(
                    digest: identity.digest,
                    partition: identity.partition
                ) == nil else { throw Schema5RandomSequenceError.invariantViolation }
                entries.removeValue(forKey: identity.label)
            case .reopen:
                store = nil
                store = try await schema5RandomOpenV3(root: root)
            case .compact:
                _ = try await store!.resourceProbeCompactSegmentedManifestV3()
            case .garbageCollect:
                var references = Set<LiveBlobReference>()
                references.reserveCapacity(entries.count)
                var referencedBytes = 0
                for label in entries.keys {
                    let live = try schema5RandomIdentity(label: label)
                    let (nextBytes, overflow) = referencedBytes.addingReportingOverflow(live.digest.byteCount)
                    guard !overflow else { throw Schema5RandomSequenceError.invariantViolation }
                    referencedBytes = nextBytes
                    references.insert(
                        LiveBlobReference(partition: live.partition, digest: live.digest)
                    )
                }
                let maintenanceLimits = try BlobMaintenanceLimits(
                    maximumReferenceCount: max(1, references.count),
                    maximumReferencedBytes: max(1, referencedBytes)
                )
                _ = try await store!.garbageCollect(
                    retaining: references,
                    limits: maintenanceLimits
                )
            }
            model = Schema5RandomSequenceModel(
                schemaVersion: 1,
                seed: seed,
                acknowledgedSuffixStep: step,
                entries: entries
            )
            try schema5RandomWriteJSON(model, to: modelURL)
        }
        store = nil
    }

    static func schema5RandomSequenceInspect(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw Schema5RandomSequenceError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let store = try await schema5RandomOpenV3(root: root)
        let metadata = try schema5RandomMetadata(root: root)
        let manifestSnapshot = await store.resourceProbeManifestShadowSnapshot()
        let segmentDirectory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let allLabels = schema5RandomAllLabels()
        var entries: [String: String] = [:]
        var knownManifestKeys = Set<String>()
        knownManifestKeys.reserveCapacity(allLabels.count)
        var allPayloadsExact = true
        for label in allLabels {
            let identity = try schema5RandomIdentity(label: label)
            knownManifestKeys.insert(
                FileBlobStore.resourceProbeManifestKey(
                    digest: identity.digest,
                    partition: identity.partition
                )
            )
            guard let physical = await store.physicalID(
                digest: identity.digest,
                partition: identity.partition
            ) else { continue }
            let physicalString = physical.rawValue.uuidString.lowercased()
            entries[label] = physicalString
            do {
                let data = try await store.read(
                    digest: identity.digest,
                    partition: identity.partition
                )
                if data != identity.data || BlobDigest.sha256(of: data) != identity.digest {
                    allPayloadsExact = false
                }
            } catch {
                allPayloadsExact = false
            }
        }
        let physicalIDs = Array(entries.values)
        let uniquePhysicalOwnership = Set(physicalIDs).count == physicalIDs.count
        let noUnknownLogicalEntries = manifestSnapshot.entries.keys.allSatisfy {
            knownManifestKeys.contains($0)
        }
        let names = try BoundedDirectoryReader.names(
            in: segmentDirectory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        )
        let report = Schema5RandomSequenceInspectReport(
            schemaVersion: 1,
            profile: metadata.profile,
            baseKind: metadata.base.kind.rawValue,
            generation: metadata.generation,
            manifestEntryCount: manifestSnapshot.entries.count,
            discoveredEntryCount: entries.count,
            segmentDirectoryEntryCount: names.count,
            entries: entries,
            allPayloadsExact: allPayloadsExact,
            uniquePhysicalOwnership: uniquePhysicalOwnership,
            noUnknownLogicalEntries: noUnknownLogicalEntries
                && manifestSnapshot.entries.count == entries.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5RandomInitialModel(
        store: FileBlobStore,
        seed: UInt64
    ) async throws -> Schema5RandomSequenceModel {
        var entries: [String: String] = [:]
        for label in schema5RandomAllLabels() {
            let identity = try schema5RandomIdentity(label: label)
            if let physical = await store.physicalID(
                digest: identity.digest,
                partition: identity.partition
            ) {
                entries[label] = physical.rawValue.uuidString.lowercased()
            }
        }
        return Schema5RandomSequenceModel(
            schemaVersion: 1,
            seed: seed,
            acknowledgedSuffixStep: nil,
            entries: entries
        )
    }

    private static func schema5RandomChooseOperation(
        generator: inout Schema5RandomSequencePRNG,
        currentEntries: [String: String]
    ) throws -> (kind: Schema5RandomSequenceOperationKind, label: String?) {
        let allLabels = schema5RandomAllLabels()
        let present = currentEntries.keys.sorted()
        let absent = allLabels.filter { currentEntries[$0] == nil }
        let bucket = Int(generator.next() % 100)

        if bucket < 36, !absent.isEmpty {
            return (.commitAbsent, absent[generator.index(upperBound: absent.count)])
        }
        if bucket < 68, !present.isEmpty {
            return (.removePresent, present[generator.index(upperBound: present.count)])
        }
        if bucket < 80 { return (.reopen, nil) }
        if bucket < 91 { return (.compact, nil) }
        if bucket < 97 { return (.garbageCollect, nil) }
        if !absent.isEmpty {
            return (.commitAbsent, absent[generator.index(upperBound: absent.count)])
        }
        if !present.isEmpty {
            return (.removePresent, present[generator.index(upperBound: present.count)])
        }
        return (.reopen, nil)
    }

    private static func schema5RandomAllLabels() -> [String] {
        let initial = (0..<schema5RandomLongSequenceLabelCount).map {
            String(format: "long-sequence-pool-%04d", $0)
        }
        let additional = (0..<schema5RandomAdditionalLabelCount).map {
            String(format: "random-sequence-pool-%04d", $0)
        }
        return initial + additional
    }

    private static func schema5RandomIdentity(label: String) throws -> Schema5RandomSequenceIdentity {
        if label.hasPrefix("long-sequence-pool-") {
            let source = try schema5MigrationIdentities(labels: [label])[0]
            return Schema5RandomSequenceIdentity(
                label: label,
                data: source.data,
                digest: source.digest,
                partition: source.partition
            )
        }
        guard label.hasPrefix("random-sequence-pool-"),
            let suffix = label.split(separator: "-").last,
            let candidateIndex = Int(suffix),
            candidateIndex >= 0,
            candidateIndex < schema5RandomAdditionalLabelCount
        else { throw Schema5RandomSequenceError.invalidArguments }
        let size = schema5RandomPayloadSizes[
            candidateIndex % schema5RandomPayloadSizes.count
        ]
        var data = Data(count: size)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for offset in bytes.indices {
                bytes[offset] = UInt8(
                    truncatingIfNeeded:
                        candidateIndex &* 131
                        &+ offset &* 17
                        &+ (candidateIndex >> 3)
                )
            }
        }
        var bigEndian = UInt64(candidateIndex).bigEndian
        let material = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let partition = try CachePartitionID.derive(
            domain: "akashic-v3-random-sequence-v1",
            material: material
        )
        return Schema5RandomSequenceIdentity(
            label: label,
            data: data,
            digest: BlobDigest.sha256(of: data),
            partition: partition
        )
    }

    private static func schema5RandomOpenV3(root: URL) async throws -> FileBlobStore {
        let store = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let metadata = try schema5RandomMetadata(root: root)
        guard metadata.profile == SegmentedManifestPrototypeV1.profileV3,
            metadata.base.kind == .baseBinaryV2
        else { throw Schema5RandomSequenceError.invalidFixture }
        return store
    }

    private static func schema5RandomMetadata(root: URL) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func schema5RandomWriteJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFileWriter.writeReplacing(try encoder.encode(value) + Data([0x0A]), to: url)
    }
}
