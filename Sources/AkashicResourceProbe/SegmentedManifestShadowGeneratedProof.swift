import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct SegmentedProofLCG {
    private(set) var state: UInt64

    init(seed: Int) {
        state = UInt64(seed) &+ 0x9e3779b97f4a7c15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func choose(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}

struct SegmentedGeneratedProofCase: Codable {
    let seed: Int
    let baseEntries: Int
    let frozenRuns: Int
    let suffixRuns: Int
    let finalEntries: Int
    let validTraceMatchesOracle: Bool
    let invalidAuthorityRejected: Bool
}

struct SegmentedGeneratedProofReport: Codable {
    let schemaVersion: Int
    let seedCount: Int
    let validTracePasses: Int
    let invalidAuthorityRejections: Int
    let allSemanticCommitmentsMatch: Bool
    let cases: [SegmentedGeneratedProofCase]
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let publicationAlgorithmQualified: Bool
        let externalPostValidationMutation: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func generatedProofShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        var cases: [SegmentedGeneratedProofCase] = []
        cases.reserveCapacity(64)
        for seed in 0..<64 {
            let caseRoot = root.appendingPathComponent("seed-\(seed)", isDirectory: true)
            try StorageDirectorySecurity.prepareDirectory(caseRoot)
            cases.append(try generatedProofCase(seed: seed, root: caseRoot))
        }

        let validPasses = cases.filter(\.validTraceMatchesOracle).count
        let invalidRejections = cases.filter(\.invalidAuthorityRejected).count
        guard validPasses == 64, invalidRejections == 64 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let report = SegmentedGeneratedProofReport(
            schemaVersion: 1,
            seedCount: 64,
            validTracePasses: validPasses,
            invalidAuthorityRejections: invalidRejections,
            allSemanticCommitmentsMatch: true,
            cases: cases,
            claims: .init(
                productionFormat: false,
                publicationAlgorithmQualified: false,
                externalPostValidationMutation: false,
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

    private static func generatedProofCase(
        seed: Int,
        root: URL
    ) throws -> SegmentedGeneratedProofCase {
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        var generator = SegmentedProofLCG(seed: seed)
        var serial = 0
        var nextLogicalID = 0
        let baseCount = 8 + seed % 25
        var baseEntries: [SegmentedShadowEntry] = []
        baseEntries.reserveCapacity(baseCount)
        for _ in 0..<baseCount {
            baseEntries.append(
                try generatedEntry(
                    seed: seed,
                    logicalID: nextLogicalID,
                    versionLabel: "base",
                    payloadBytes: generatedPayloadSizes[(seed + nextLogicalID) % generatedPayloadSizes.count],
                    serial: serial
                )
            )
            nextLogicalID += 1
            serial += 1
        }
        baseEntries.sort { $0.key < $1.key }
        let base = try generatedWriteBase(
            baseEntries,
            fileName: "base-generated-origin.seg",
            directory: segments
        )
        var state = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })

        let frozenRunCount = seed % 7
        var frozenRuns: [SegmentedShadowDescriptor] = []
        for index in 0..<frozenRunCount {
            let mutations = try generatedMutations(
                seed: seed,
                runLabel: "f\(index)",
                state: state,
                generator: &generator,
                nextLogicalID: &nextLogicalID,
                serial: &serial
            )
            let run = try generatedWriteRun(
                mutations,
                fileName: "run-generated-f-\(index).seg",
                directory: segments
            )
            frozenRuns.append(run)
            state = try apply(mutations, to: state)
        }
        let frozenState = state
        let generation = UInt64(1_000 + seed * 4)
        let frozen = try makeRoot(generation: generation, base: base, runs: frozenRuns)
        let candidateEntries = frozenState.values.sorted { $0.key < $1.key }
        let candidate = try generatedWriteBase(
            candidateEntries,
            fileName: "base-generated-candidate.seg",
            directory: segments
        )
        let proof = try makeSemanticProof(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segments
        )

        let suffixRunCount = (seed * 3 + 1) % 7
        var suffixRuns: [SegmentedShadowDescriptor] = []
        for index in 0..<suffixRunCount {
            let mutations = try generatedMutations(
                seed: seed,
                runLabel: "s\(index)",
                state: state,
                generator: &generator,
                nextLogicalID: &nextLogicalID,
                serial: &serial
            )
            let run = try generatedWriteRun(
                mutations,
                fileName: "run-generated-s-\(index).seg",
                directory: segments
            )
            suffixRuns.append(run)
            state = try apply(mutations, to: state)
        }
        let currentState = state
        let current = try makeRoot(
            generation: generation + 1,
            base: base,
            runs: frozenRuns + suffixRuns
        )
        let rebased = try boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: proof,
            expectedCandidate: candidate
        )
        let oracle = try generatedRecover(current, directory: segments)
        let bounded = try generatedRecover(rebased, directory: segments)
        let oracleCommitment = try semanticStateCommitment(oracle)
        let boundedCommitment = try semanticStateCommitment(bounded)
        let validTraceMatchesOracle = oracle == currentState
            && bounded == currentState
            && oracleCommitment == boundedCommitment
        guard validTraceMatchesOracle else { throw SegmentedManifestShadowError.invariantViolation }

        let invalidCurrent: SegmentedShadowRoot
        if frozenRuns.isEmpty {
            var alternateBaseEntries = baseEntries
            let source = alternateBaseEntries[0]
            alternateBaseEntries[0] = SegmentedShadowEntry(
                key: source.key,
                physicalID: try generatedPhysicalID("invalid-base-\(seed)"),
                partition: source.partition,
                digest: source.digest,
                byteCount: source.byteCount,
                lastAccess: source.lastAccess
            )
            let alternateBase = try generatedWriteBase(
                alternateBaseEntries,
                fileName: "base-generated-invalid.seg",
                directory: segments
            )
            invalidCurrent = try makeRoot(
                generation: generation + 2,
                base: alternateBase,
                runs: suffixRuns
            )
        } else {
            invalidCurrent = try makeRoot(
                generation: generation + 2,
                base: base,
                runs: Array(frozenRuns.dropLast()) + suffixRuns
            )
        }
        var invalidAuthorityRejected = false
        do {
            _ = try boundedRebasedRoot(
                frozen: frozen,
                current: invalidCurrent,
                proof: proof,
                expectedCandidate: candidate
            )
        } catch {
            invalidAuthorityRejected = true
        }
        guard invalidAuthorityRejected else { throw SegmentedManifestShadowError.invariantViolation }

        return SegmentedGeneratedProofCase(
            seed: seed,
            baseEntries: baseCount,
            frozenRuns: frozenRunCount,
            suffixRuns: suffixRunCount,
            finalEntries: currentState.count,
            validTraceMatchesOracle: true,
            invalidAuthorityRejected: true
        )
    }

    private static let generatedPayloadSizes = [0, 1, 64, 4096, 65536]

    private static func generatedMutations(
        seed: Int,
        runLabel: String,
        state: [String: SegmentedShadowEntry],
        generator: inout SegmentedProofLCG,
        nextLogicalID: inout Int,
        serial: inout Int
    ) throws -> [SegmentedShadowMutation] {
        let count = 1 + generator.choose(6)
        var mutations: [SegmentedShadowMutation] = []
        var usedKeys = Set<String>()
        mutations.reserveCapacity(count)
        for mutationIndex in 0..<count {
            let available = state.values
                .filter { !usedKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
            let operation = available.isEmpty ? 0 : generator.choose(3)
            switch operation {
            case 0:
                let size = generatedPayloadSizes[generator.choose(generatedPayloadSizes.count)]
                let entry = try generatedEntry(
                    seed: seed,
                    logicalID: nextLogicalID,
                    versionLabel: "\(runLabel)-create-\(mutationIndex)",
                    payloadBytes: size,
                    serial: serial
                )
                nextLogicalID += 1
                usedKeys.insert(entry.key)
                mutations.append(.upsert(entry))
            case 1:
                let source = available[generator.choose(available.count)]
                usedKeys.insert(source.key)
                mutations.append(.tombstone(key: source.key))
            default:
                let source = available[generator.choose(available.count)]
                let repaired = SegmentedShadowEntry(
                    key: source.key,
                    physicalID: try generatedPhysicalID("repair-\(seed)-\(serial)-\(source.key)"),
                    partition: source.partition,
                    digest: source.digest,
                    byteCount: source.byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: 1_010_000_000 + Double(serial))
                )
                usedKeys.insert(source.key)
                mutations.append(.upsert(repaired))
            }
            serial += 1
        }
        return mutations.sorted { $0.key < $1.key }
    }

    private static func generatedEntry(
        seed: Int,
        logicalID: Int,
        versionLabel: String,
        payloadBytes: Int,
        serial: Int
    ) throws -> SegmentedShadowEntry {
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-generated-proof-v1",
            material: Data("seed=\(seed);logical=\(logicalID)".utf8)
        )
        let fill = UInt8(truncatingIfNeeded: seed &* 17 &+ logicalID &* 31)
        let payload = Data(repeating: fill, count: payloadBytes)
        let digest = BlobDigest.sha256(of: payload)
        return SegmentedShadowEntry(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            physicalID: try generatedPhysicalID("entry-\(seed)-\(logicalID)-\(versionLabel)"),
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 1_000_000_000 + Double(serial))
        )
    }

    private static func generatedPhysicalID(_ label: String) throws -> PhysicalBlobID {
        let bytes = Array(SHA256.hash(data: Data(label.utf8)).prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidText = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: uuidText) else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return PhysicalBlobID(rawValue: uuid)
    }

    private static func generatedWriteBase(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    private static func generatedWriteRun(
        _ mutations: [SegmentedShadowMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: url)
        return try descriptor(.run, url: url, expectedRecords: mutations.count)
    }

    private static func generatedRecover(
        _ root: SegmentedShadowRoot,
        directory: URL
    ) throws -> [String: SegmentedShadowEntry] {
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        var state = Dictionary(uniqueKeysWithValues: try readBase(root.base, directory: directory).map { ($0.key, $0) })
        for run in root.runs {
            state = try apply(try readRun(run, directory: directory), to: state)
        }
        return state
    }
}
