import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5RecoveryPhaseSample: Codable {
    let depth: Int
    let repetition: Int
    let rootNanoseconds: UInt64
    let baseReadHashNanoseconds: UInt64
    let baseDecodeIndexNanoseconds: UInt64
    let runReadHashNanoseconds: UInt64
    let runDecodeNanoseconds: UInt64
    let indexedApplyNanoseconds: UInt64
    let finalConsistencyNanoseconds: UInt64
    let totalProfiledNanoseconds: UInt64
    let exactState: Bool
}

private struct Schema5RecoveryPhaseReport: Codable {
    struct Claims: Codable {
        let formalPerformance: Bool
        let productionFormat: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let liveEntries: Int
    let recordsPerRun: Int
    let depths: [Int]
    let repetitions: Int
    let samples: [Schema5RecoveryPhaseSample]
    let medians: [String: UInt64]
    let allExact: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5RecoveryPhaseProfile(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        let liveCount = 16_384
        let recordsPerRun = 512
        let depths = [0, 1, 4, 16, 64]
        let repetitions = 3
        let baseEntries = try makeBaseEntries(count: liveCount)
        let initialState = Dictionary(
            uniqueKeysWithValues: baseEntries.map { ($0.key, schema5DepthEntry($0)) }
        )
        let baseSnapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: schema5DepthShadow(initialState)
        )

        var samples: [Schema5RecoveryPhaseSample] = []
        for depth in depths {
            for repetition in 0..<repetitions {
                let caseRoot = root.appendingPathComponent(
                    "depth-\(depth)-rep-\(repetition)", isDirectory: true
                )
                let segments = caseRoot.appendingPathComponent("segments", isDirectory: true)
                try StorageDirectorySecurity.prepareDirectory(caseRoot)
                try StorageDirectorySecurity.prepareDirectory(segments)
                let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
                    baseSnapshot,
                    entryCount: liveCount,
                    fileName: "base-phase.json",
                    directory: segments
                )

                var expected = initialState
                var runs: [SegmentedManifestDescriptorV1] = []
                runs.reserveCapacity(depth)
                for runIndex in 0..<depth {
                    let mutations = try schema5DepthMutations(
                        runIndex: runIndex,
                        baseEntries: baseEntries,
                        expected: expected,
                        count: recordsPerRun
                    )
                    expected = try SegmentedManifestPrototypeV1.apply(mutations, to: expected)
                    runs.append(
                        try SegmentedManifestPrototypeV1.writeRun(
                            mutations,
                            fileName: String(format: "run-phase-%03d.seg", runIndex),
                            directory: segments
                        )
                    )
                }
                let manifestRoot = try SegmentedManifestPrototypeV1.makeRoot(
                    generation: UInt64(depth + 1),
                    base: base,
                    runs: runs
                )
                let rootURL = caseRoot.appendingPathComponent("manifest.json")
                try SegmentedManifestPrototypeV1.writeRoot(manifestRoot, to: rootURL)

                let totalStart = DispatchTime.now().uptimeNanoseconds
                let rootStart = DispatchTime.now().uptimeNanoseconds
                let decodedRoot = try SegmentedManifestPrototypeV1.readRoot(from: rootURL)
                let rootNanoseconds = DispatchTime.now().uptimeNanoseconds &- rootStart

                let baseReadStart = DispatchTime.now().uptimeNanoseconds
                let baseData = try SegmentedManifestPrototypeV1.readDescriptorData(
                    decodedRoot.base,
                    directory: segments
                )
                let baseReadNanoseconds = DispatchTime.now().uptimeNanoseconds &- baseReadStart

                let baseDecodeStart = DispatchTime.now().uptimeNanoseconds
                let decodedBase = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(baseData)
                guard decodedBase.count == decodedRoot.base.recordCount else {
                    throw SegmentedManifestShadowError.invariantViolation
                }
                var state: [String: SegmentedManifestEntry] = [:]
                state.reserveCapacity(decodedBase.count)
                var owners: [PhysicalBlobID: String] = [:]
                owners.reserveCapacity(decodedBase.count)
                for (key, entry) in decodedBase {
                    let converted = SegmentedManifestEntry(
                        key: key,
                        physicalID: entry.physicalID,
                        partition: entry.partition,
                        digest: entry.digest,
                        byteCount: entry.byteCount,
                        lastAccess: entry.lastAccess
                    )
                    guard state.updateValue(converted, forKey: key) == nil,
                        owners.updateValue(key, forKey: entry.physicalID) == nil
                    else { throw SegmentedManifestShadowError.invariantViolation }
                }
                let baseDecodeNanoseconds = DispatchTime.now().uptimeNanoseconds &- baseDecodeStart

                var runReadNanoseconds: UInt64 = 0
                var runDecodeNanoseconds: UInt64 = 0
                var applyNanoseconds: UInt64 = 0
                for descriptor in decodedRoot.runs {
                    let readStart = DispatchTime.now().uptimeNanoseconds
                    let data = try SegmentedManifestPrototypeV1.readDescriptorData(
                        descriptor,
                        directory: segments
                    )
                    runReadNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- readStart

                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    let mutations = try SegmentedManifestPrototypeV1.decodeRun(data)
                    guard mutations.count == descriptor.recordCount else {
                        throw SegmentedManifestShadowError.invariantViolation
                    }
                    runDecodeNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- decodeStart

                    let applyStart = DispatchTime.now().uptimeNanoseconds
                    try schema5ProfileIndexedApply(
                        mutations,
                        state: &state,
                        owners: &owners
                    )
                    applyNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- applyStart
                }

                let finalStart = DispatchTime.now().uptimeNanoseconds
                let finalConsistent = owners.count == state.count
                    && state.allSatisfy { key, entry in owners[entry.physicalID] == key }
                let finalNanoseconds = DispatchTime.now().uptimeNanoseconds &- finalStart
                let totalNanoseconds = DispatchTime.now().uptimeNanoseconds &- totalStart

                let packageRecovered = try SegmentedManifestPrototypeV1.recover(
                    rootURL: rootURL,
                    segmentDirectory: segments
                )
                let exact = finalConsistent && state == expected && packageRecovered == expected
                guard exact else { throw SegmentedManifestShadowError.invariantViolation }
                samples.append(
                    Schema5RecoveryPhaseSample(
                        depth: depth,
                        repetition: repetition,
                        rootNanoseconds: rootNanoseconds,
                        baseReadHashNanoseconds: baseReadNanoseconds,
                        baseDecodeIndexNanoseconds: baseDecodeNanoseconds,
                        runReadHashNanoseconds: runReadNanoseconds,
                        runDecodeNanoseconds: runDecodeNanoseconds,
                        indexedApplyNanoseconds: applyNanoseconds,
                        finalConsistencyNanoseconds: finalNanoseconds,
                        totalProfiledNanoseconds: totalNanoseconds,
                        exactState: exact
                    )
                )
            }
        }

        var medians: [String: UInt64] = [:]
        for depth in depths {
            let rows = samples.filter { $0.depth == depth }
            let phases: [(String, KeyPath<Schema5RecoveryPhaseSample, UInt64>)] = [
                ("root", \.rootNanoseconds),
                ("base-read-hash", \.baseReadHashNanoseconds),
                ("base-decode-index", \.baseDecodeIndexNanoseconds),
                ("run-read-hash", \.runReadHashNanoseconds),
                ("run-decode", \.runDecodeNanoseconds),
                ("indexed-apply", \.indexedApplyNanoseconds),
                ("final-consistency", \.finalConsistencyNanoseconds),
                ("total", \.totalProfiledNanoseconds),
            ]
            for (name, keyPath) in phases {
                medians["depth-\(depth)-\(name)"] = schema5PhaseMedian(
                    rows.map { $0[keyPath: keyPath] }
                )
            }
        }
        let allExact = samples.allSatisfy(\.exactState)
        guard allExact else { throw SegmentedManifestShadowError.invariantViolation }
        let report = Schema5RecoveryPhaseReport(
            schemaVersion: 1,
            liveEntries: liveCount,
            recordsPerRun: recordsPerRun,
            depths: depths,
            repetitions: repetitions,
            samples: samples,
            medians: medians,
            allExact: allExact,
            claims: .init(
                formalPerformance: false,
                productionFormat: false,
                physicalIOBytes: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func schema5ProfileIndexedApply(
        _ mutations: [SegmentedManifestMutation],
        state: inout [String: SegmentedManifestEntry],
        owners: inout [PhysicalBlobID: String]
    ) throws {
        for mutation in mutations {
            guard let old = state[mutation.key] else { continue }
            guard owners[old.physicalID] == mutation.key else {
                throw SegmentedManifestShadowError.invariantViolation
            }
            owners.removeValue(forKey: old.physicalID)
        }
        for mutation in mutations {
            switch mutation {
            case .tombstone(let key):
                state.removeValue(forKey: key)
            case .upsert(let entry):
                guard owners[entry.physicalID] == nil else {
                    throw SegmentedManifestShadowError.invariantViolation
                }
                state[entry.key] = entry
                owners[entry.physicalID] = entry.key
            }
        }
    }

    private static func schema5PhaseMedian(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}
