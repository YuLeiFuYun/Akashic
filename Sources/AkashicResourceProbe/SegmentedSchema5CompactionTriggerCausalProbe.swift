import AkashicCore
import AkashicDisk
import Foundation

private enum TriggerLocality: String, Codable {
    case wide
    case hot
    case tombstoneRecreate
}

private struct TriggerCaseSpec {
    let liveEntries: Int
    let totalRecords: Int
    let recordsPerRun: Int
    let locality: TriggerLocality
    let payloadBytes: Int

    var runCount: Int { totalRecords / recordsPerRun }
    var id: String {
        "live-\(liveEntries)-records-\(totalRecords)-rpr-\(recordsPerRun)-loc-\(locality.rawValue)-payload-\(payloadBytes)"
    }
}

private struct TriggerBaseFixture {
    let state: [String: SegmentedManifestEntry]
    let sortedKeys: [String]
    let snapshot: Data
}

private struct TriggerCausalSample: Codable {
    let caseID: String
    let repetition: Int
    let liveEntries: Int
    let totalRecords: Int
    let recordsPerRun: Int
    let runCount: Int
    let locality: TriggerLocality
    let payloadBytes: Int
    let baseBytes: Int
    let totalRunBytes: Int
    let rootBytes: Int
    let totalRecoveryNanoseconds: UInt64
    let runReadHashNanoseconds: UInt64
    let runDecodeNanoseconds: UInt64
    let indexedApplyNanoseconds: UInt64
    let exactState: Bool
}

private struct TriggerCausalReport: Codable {
    struct Claims: Codable {
        let automaticTrigger: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let payloadReadIO: Bool
    }

    let schemaVersion: Int
    let repetitions: Int
    let cases: Int
    let samples: [TriggerCausalSample]
    let allExact: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5CompactionTriggerCausal(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        let repetitions = 3
        let specs = schema5TriggerSpecs()
        var samples: [TriggerCausalSample] = []
        let fixtureGroups = Dictionary(grouping: specs) { spec in
            "\(spec.liveEntries)-\(spec.payloadBytes)"
        }
        for groupKey in fixtureGroups.keys.sorted() {
            guard let group = fixtureGroups[groupKey], let first = group.first else { continue }
            let fixture = try schema5TriggerBaseFixture(
                liveEntries: first.liveEntries,
                payloadBytes: first.payloadBytes
            )
            for spec in group.sorted(by: { $0.id < $1.id }) {
                for repetition in 0..<repetitions {
                    let caseRoot = root.appendingPathComponent(
                        "\(spec.id)-rep-\(repetition)",
                        isDirectory: true
                    )
                    samples.append(
                        try schema5TriggerSample(
                            spec: spec,
                            repetition: repetition,
                            fixture: fixture,
                            root: caseRoot
                        )
                    )
                    try? FileManager.default.removeItem(at: caseRoot)
                }
            }
        }

        let allExact = samples.allSatisfy(\.exactState)
        guard allExact else { throw SegmentedManifestShadowError.invariantViolation }
        let report = TriggerCausalReport(
            schemaVersion: 1,
            repetitions: repetitions,
            cases: specs.count,
            samples: samples,
            allExact: allExact,
            claims: .init(
                automaticTrigger: false,
                formalPerformance: false,
                physicalDevice: false,
                payloadReadIO: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5TriggerSpecs() -> [TriggerCaseSpec] {
        var specs: [TriggerCaseSpec] = []
        for live in [1_024, 16_384, 99_488] {
            for recordsPerRun in [512, 128, 32] {
                specs.append(
                    .init(
                        liveEntries: live,
                        totalRecords: 2_048,
                        recordsPerRun: recordsPerRun,
                        locality: .wide,
                        payloadBytes: 16
                    )
                )
            }
        }
        specs += [
            .init(liveEntries: 16_384, totalRecords: 512, recordsPerRun: 32, locality: .wide, payloadBytes: 16),
            .init(liveEntries: 16_384, totalRecords: 8_192, recordsPerRun: 512, locality: .wide, payloadBytes: 16),
            .init(liveEntries: 16_384, totalRecords: 8_192, recordsPerRun: 128, locality: .wide, payloadBytes: 16),
            .init(liveEntries: 16_384, totalRecords: 32_768, recordsPerRun: 512, locality: .wide, payloadBytes: 16),
            .init(liveEntries: 16_384, totalRecords: 8_192, recordsPerRun: 512, locality: .hot, payloadBytes: 16),
            .init(liveEntries: 16_384, totalRecords: 8_192, recordsPerRun: 512, locality: .tombstoneRecreate, payloadBytes: 16),
            .init(liveEntries: 1_024, totalRecords: 2_048, recordsPerRun: 512, locality: .wide, payloadBytes: 65_536),
        ]
        return specs
    }

    private static func schema5TriggerBaseFixture(
        liveEntries: Int,
        payloadBytes: Int
    ) throws -> TriggerBaseFixture {
        var state: [String: SegmentedManifestEntry] = [:]
        var shadow: [String: FileBlobStoreRecordShadowEntry] = [:]
        state.reserveCapacity(liveEntries)
        shadow.reserveCapacity(liveEntries)
        for index in 0..<liveEntries {
            let partition = try CachePartitionID.derive(
                domain: "schema5-trigger-causal-v1",
                material: Data("partition-\(index)".utf8)
            )
            let payload = Data(repeating: UInt8(truncatingIfNeeded: index), count: payloadBytes)
            let digest = BlobDigest.sha256(of: payload)
            let key = FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
            let physicalID = PhysicalBlobID()
            let lastAccess = Date(timeIntervalSince1970: Double(index + 1))
            let entry = SegmentedManifestEntry(
                key: key,
                physicalID: physicalID,
                partition: partition,
                digest: digest,
                byteCount: digest.byteCount,
                lastAccess: lastAccess
            )
            state[key] = entry
            shadow[key] = FileBlobStoreRecordShadowEntry(
                physicalID: physicalID,
                partition: partition,
                digest: digest,
                byteCount: digest.byteCount,
                lastAccess: lastAccess
            )
        }
        let snapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: shadow
        )
        return TriggerBaseFixture(
            state: state,
            sortedKeys: state.keys.sorted(),
            snapshot: snapshot
        )
    }

    private static func schema5TriggerSample(
        spec: TriggerCaseSpec,
        repetition: Int,
        fixture: TriggerBaseFixture,
        root: URL
    ) throws -> TriggerCausalSample {
        precondition(spec.totalRecords % spec.recordsPerRun == 0)
        precondition(spec.runCount <= SegmentedManifestPrototypeV1.maximumRunDescriptors)
        precondition(spec.recordsPerRun <= fixture.sortedKeys.count)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            fixture.snapshot,
            entryCount: fixture.state.count,
            fileName: "base-trigger.json",
            directory: segments
        )

        var expected = fixture.state
        var runs: [SegmentedManifestDescriptorV1] = []
        runs.reserveCapacity(spec.runCount)
        for runIndex in 0..<spec.runCount {
            let mutations = try schema5TriggerMutations(
                spec: spec,
                runIndex: runIndex,
                fixture: fixture,
                expected: expected
            )
            schema5TriggerApplyExpected(mutations, to: &expected)
            runs.append(
                try SegmentedManifestPrototypeV1.writeRun(
                    mutations,
                    fileName: "run-trigger-\(runIndex).seg",
                    directory: segments
                )
            )
        }
        let manifestRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: UInt64(spec.runCount + 1),
            base: base,
            runs: runs
        )

        let totalStart = DispatchTime.now().uptimeNanoseconds
        let recovered = try SegmentedManifestPrototypeV1.recover(
            root: manifestRoot,
            segmentDirectory: segments
        )
        let totalNanoseconds = DispatchTime.now().uptimeNanoseconds &- totalStart

        var manualState = fixture.state
        var owners: [PhysicalBlobID: String] = [:]
        owners.reserveCapacity(manualState.count)
        for (key, entry) in manualState {
            guard owners.updateValue(key, forKey: entry.physicalID) == nil else {
                throw SegmentedManifestShadowError.invariantViolation
            }
        }
        var runRead: UInt64 = 0
        var runDecode: UInt64 = 0
        var apply: UInt64 = 0
        for descriptor in runs {
            let readStart = DispatchTime.now().uptimeNanoseconds
            let data = try SegmentedManifestPrototypeV1.readDescriptorData(
                descriptor,
                directory: segments
            )
            runRead &+= DispatchTime.now().uptimeNanoseconds &- readStart
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            let mutations = try SegmentedManifestPrototypeV1.decodeRun(data)
            runDecode &+= DispatchTime.now().uptimeNanoseconds &- decodeStart
            let applyStart = DispatchTime.now().uptimeNanoseconds
            try schema5TriggerIndexedApply(mutations, state: &manualState, owners: &owners)
            apply &+= DispatchTime.now().uptimeNanoseconds &- applyStart
        }
        let exact = recovered == expected
            && manualState == expected
            && owners.count == manualState.count
            && manualState.allSatisfy { key, entry in owners[entry.physicalID] == key }
        guard exact else { throw SegmentedManifestShadowError.invariantViolation }
        return TriggerCausalSample(
            caseID: spec.id,
            repetition: repetition,
            liveEntries: spec.liveEntries,
            totalRecords: spec.totalRecords,
            recordsPerRun: spec.recordsPerRun,
            runCount: spec.runCount,
            locality: spec.locality,
            payloadBytes: spec.payloadBytes,
            baseBytes: base.byteCount,
            totalRunBytes: runs.reduce(0) { $0 + $1.byteCount },
            rootBytes: try SegmentedManifestPrototypeV1.encodeRoot(manifestRoot).count,
            totalRecoveryNanoseconds: totalNanoseconds,
            runReadHashNanoseconds: runRead,
            runDecodeNanoseconds: runDecode,
            indexedApplyNanoseconds: apply,
            exactState: exact
        )
    }

    private static func schema5TriggerMutations(
        spec: TriggerCaseSpec,
        runIndex: Int,
        fixture: TriggerBaseFixture,
        expected: [String: SegmentedManifestEntry]
    ) throws -> [SegmentedManifestMutation] {
        let start = spec.locality == .hot
            ? 0
            : (runIndex * spec.recordsPerRun) % fixture.sortedKeys.count
        let keys = (0..<spec.recordsPerRun).map {
            fixture.sortedKeys[(start + $0) % fixture.sortedKeys.count]
        }.sorted()
        if spec.locality == .tombstoneRecreate, runIndex % 2 == 0 {
            return keys.map(SegmentedManifestMutation.tombstone)
        }
        return try keys.map { key in
            guard let template = expected[key] ?? fixture.state[key] else {
                throw SegmentedManifestShadowError.invariantViolation
            }
            return .upsert(
                SegmentedManifestEntry(
                    key: key,
                    physicalID: PhysicalBlobID(),
                    partition: template.partition,
                    digest: template.digest,
                    byteCount: template.byteCount,
                    lastAccess: Date(timeIntervalSince1970: Double(runIndex + 10_000))
                )
            )
        }
    }

    private static func schema5TriggerApplyExpected(
        _ mutations: [SegmentedManifestMutation],
        to state: inout [String: SegmentedManifestEntry]
    ) {
        for mutation in mutations {
            switch mutation {
            case .tombstone(let key): state.removeValue(forKey: key)
            case .upsert(let entry): state[entry.key] = entry
            }
        }
    }

    private static func schema5TriggerIndexedApply(
        _ mutations: [SegmentedManifestMutation],
        state: inout [String: SegmentedManifestEntry],
        owners: inout [PhysicalBlobID: String]
    ) throws {
        for mutation in mutations {
            if let old = state[mutation.key] {
                guard owners[old.physicalID] == mutation.key else {
                    throw SegmentedManifestShadowError.invariantViolation
                }
                owners.removeValue(forKey: old.physicalID)
            }
        }
        for mutation in mutations {
            switch mutation {
            case .tombstone(let key): state.removeValue(forKey: key)
            case .upsert(let entry):
                guard owners[entry.physicalID] == nil else {
                    throw SegmentedManifestShadowError.invariantViolation
                }
                state[entry.key] = entry
                owners[entry.physicalID] = entry.key
            }
        }
    }
}
