import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

struct SegmentedShadowSemanticProof: Codable, Equatable {
    let schemaVersion: Int
    let frozenRootSeal: String
    let candidateBase: SegmentedShadowDescriptor
    let frozenStateCommitment: String
    let candidateStateCommitment: String
    let seal: String
}

private struct SegmentedShadowSemanticProofTranscript: Codable {
    let schemaVersion: Int
    let frozenRootSeal: String
    let candidateBase: SegmentedShadowDescriptor
    let frozenStateCommitment: String
    let candidateStateCommitment: String
}

struct SegmentedShadowBoundedProofReport: Codable {
    let schemaVersion: Int
    let semanticCommitmentsEqual: Bool
    let noSuffixMatchesFullOracle: Bool
    let mixedSuffixMatchesFullOracle: Bool
    let proofSealCorruptionRejected: Bool
    let frozenSealMismatchRejected: Bool
    let candidateDescriptorMismatchRejected: Bool
    let prefixDivergenceRejected: Bool
    let postProofCandidateMutationAcceptedByBoundedPublisher: Bool
    let postProofCandidateMutationRejectedOnRecovery: Bool
    let candidateFreshnessGapDemonstrated: Bool
    let foregroundFullReplayRequiredByProofLogic: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let fileBlobStoreAuthority: Bool
        let publicationAlgorithmQualified: Bool
        let automaticMigration: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let keyedAuthentication: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func boundedProofShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segmentDirectory)

        let baseEntries = try makeBaseEntries(count: 96)
        let baseState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let base = try boundedWriteBase(
            baseEntries,
            fileName: "base-bounded-origin.seg",
            directory: segmentDirectory
        )
        let frozenMutations = try makeRunMutations(base: baseEntries, count: 24)
        let frozenRun = try boundedWriteRun(
            frozenMutations,
            fileName: "run-bounded-frozen.seg",
            directory: segmentDirectory
        )
        let frozenState = try apply(frozenMutations, to: baseState)
        let frozen = try makeRoot(generation: 40, base: base, runs: [frozenRun])
        let candidateEntries = frozenState.values.sorted { $0.key < $1.key }
        let candidateData = try encodeBase(candidateEntries)
        let candidate = try boundedWriteBase(
            candidateEntries,
            fileName: "base-bounded-candidate.seg",
            directory: segmentDirectory
        )
        let proof = try makeSemanticProof(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segmentDirectory
        )
        let semanticCommitmentsEqual = proof.frozenStateCommitment == proof.candidateStateCommitment
        guard semanticCommitmentsEqual else { throw SegmentedManifestShadowError.invariantViolation }

        let noSuffix = try boundedRebasedRoot(
            frozen: frozen,
            current: frozen,
            proof: proof
        )
        let noSuffixMatchesFullOracle = try boundedRecover(noSuffix, directory: segmentDirectory) == frozenState
        guard noSuffixMatchesFullOracle else { throw SegmentedManifestShadowError.invariantViolation }

        let frozenEntries = frozenState.values.sorted { $0.key < $1.key }
        let suffixMutations = try boundedMixedSuffix(frozenEntries)
        let suffixRun = try boundedWriteRun(
            suffixMutations,
            fileName: "run-bounded-suffix.seg",
            directory: segmentDirectory
        )
        let current = try makeRoot(generation: 41, base: base, runs: [frozenRun, suffixRun])
        let currentState = try apply(suffixMutations, to: frozenState)
        let mixedSuffix = try boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: proof
        )
        let mixedSuffixMatchesFullOracle = try boundedRecover(mixedSuffix, directory: segmentDirectory) == currentState
        guard mixedSuffixMatchesFullOracle else { throw SegmentedManifestShadowError.invariantViolation }

        let corruptProof = SegmentedShadowSemanticProof(
            schemaVersion: proof.schemaVersion,
            frozenRootSeal: proof.frozenRootSeal,
            candidateBase: proof.candidateBase,
            frozenStateCommitment: proof.frozenStateCommitment,
            candidateStateCommitment: String(repeating: "0", count: 64),
            seal: proof.seal
        )
        let proofSealCorruptionRejected = boundedRejects(
            frozen: frozen,
            current: current,
            proof: corruptProof
        )
        guard proofSealCorruptionRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let wrongFrozen = try makeRoot(generation: 42, base: base, runs: [])
        let frozenSealMismatchRejected = boundedRejects(
            frozen: wrongFrozen,
            current: wrongFrozen,
            proof: proof
        )
        guard frozenSealMismatchRejected else { throw SegmentedManifestShadowError.invariantViolation }

        var alternateEntries = candidateEntries
        let changed = alternateEntries[0]
        alternateEntries[0] = SegmentedShadowEntry(
            key: changed.key,
            physicalID: PhysicalBlobID(),
            partition: changed.partition,
            digest: changed.digest,
            byteCount: changed.byteCount,
            lastAccess: changed.lastAccess
        )
        let alternateCandidate = try boundedWriteBase(
            alternateEntries,
            fileName: "base-bounded-alternate.seg",
            directory: segmentDirectory
        )
        let mismatchedProof = try semanticProofReplacingCandidate(proof, candidateBase: alternateCandidate)
        let candidateDescriptorMismatchRejected = boundedRejects(
            frozen: frozen,
            current: current,
            proof: mismatchedProof,
            expectedCandidate: candidate
        )
        guard candidateDescriptorMismatchRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let divergentRun = try boundedWriteRun(
            [.upsert(try boundedEntry(label: "divergent-prefix"))],
            fileName: "run-bounded-divergent.seg",
            directory: segmentDirectory
        )
        let divergentCurrent = try makeRoot(generation: 41, base: base, runs: [divergentRun])
        let prefixDivergenceRejected = boundedRejects(
            frozen: frozen,
            current: divergentCurrent,
            proof: proof
        )
        guard prefixDivergenceRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let candidateURL = segmentDirectory.appendingPathComponent(candidate.fileName)
        var mutatedCandidate = candidateData
        guard mutatedCandidate.count > headerBytes else { throw SegmentedManifestShadowError.invariantViolation }
        mutatedCandidate[mutatedCandidate.index(mutatedCandidate.startIndex, offsetBy: headerBytes)] ^= 0x01
        try DurableFileWriter.writeReplacing(mutatedCandidate, to: candidateURL)
        let postMutationRoot = try boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: proof
        )
        let postProofCandidateMutationAcceptedByBoundedPublisher = postMutationRoot.base == candidate
        guard postProofCandidateMutationAcceptedByBoundedPublisher else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var postProofCandidateMutationRejectedOnRecovery = false
        do {
            _ = try boundedRecover(postMutationRoot, directory: segmentDirectory)
        } catch {
            postProofCandidateMutationRejectedOnRecovery = true
        }
        guard postProofCandidateMutationRejectedOnRecovery else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try DurableFileWriter.writeReplacing(candidateData, to: candidateURL)
        _ = try descriptor(.base, url: candidateURL, expectedRecords: candidateEntries.count)

        let report = SegmentedShadowBoundedProofReport(
            schemaVersion: 1,
            semanticCommitmentsEqual: true,
            noSuffixMatchesFullOracle: true,
            mixedSuffixMatchesFullOracle: true,
            proofSealCorruptionRejected: true,
            frozenSealMismatchRejected: true,
            candidateDescriptorMismatchRejected: true,
            prefixDivergenceRejected: true,
            postProofCandidateMutationAcceptedByBoundedPublisher: true,
            postProofCandidateMutationRejectedOnRecovery: true,
            candidateFreshnessGapDemonstrated: true,
            foregroundFullReplayRequiredByProofLogic: false,
            claims: .init(
                productionFormat: false,
                fileBlobStoreAuthority: false,
                publicationAlgorithmQualified: false,
                automaticMigration: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false,
                keyedAuthentication: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func makeSemanticProof(
        frozen: SegmentedShadowRoot,
        candidateBase: SegmentedShadowDescriptor,
        segmentDirectory: URL
    ) throws -> SegmentedShadowSemanticProof {
        let frozenState = try boundedRecover(frozen, directory: segmentDirectory)
        let candidateEntries = try readBase(candidateBase, directory: segmentDirectory)
        let candidateState = Dictionary(uniqueKeysWithValues: candidateEntries.map { ($0.key, $0) })
        let frozenCommitment = try semanticStateCommitment(frozenState)
        let candidateCommitment = try semanticStateCommitment(candidateState)
        guard frozenCommitment == candidateCommitment else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        return try makeSemanticProofValue(
            frozenRootSeal: frozen.seal,
            candidateBase: candidateBase,
            frozenCommitment: frozenCommitment,
            candidateCommitment: candidateCommitment
        )
    }

    static func semanticStateCommitment(
        _ state: [String: SegmentedShadowEntry]
    ) throws -> String {
        var data = Data("AKSEG-SEMANTIC-STATE-V1\0".utf8)
        let entries = state.values.sorted { $0.key < $1.key }
        appendLittleEndian(UInt64(entries.count), to: &data)
        for entry in entries {
            let keyBytes = Data(entry.key.utf8)
            let algorithmBytes = Data(entry.digest.algorithm.rawValue.utf8)
            guard keyBytes.count <= Int(UInt16.max),
                algorithmBytes.count <= Int(UInt8.max),
                entry.partition.canonicalBytes.count == 32,
                entry.digest.bytes.count == entry.digest.algorithm.digestByteCount,
                entry.digest.byteCount == entry.byteCount,
                entry.byteCount >= 0,
                entry.byteCount <= maximumBlobBytes
            else { throw SegmentedManifestShadowError.invalidFormat }
            appendLittleEndian(UInt16(keyBytes.count), to: &data)
            data.append(keyBytes)
            appendUUID(entry.physicalID.rawValue, to: &data)
            data.append(entry.partition.canonicalBytes)
            data.append(UInt8(algorithmBytes.count))
            data.append(algorithmBytes)
            data.append(entry.digest.bytes)
            appendLittleEndian(UInt64(entry.byteCount), to: &data)
            appendLittleEndian(entry.lastAccess.timeIntervalSinceReferenceDate.bitPattern, to: &data)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedRebasedRoot(
        frozen: SegmentedShadowRoot,
        current: SegmentedShadowRoot,
        proof: SegmentedShadowSemanticProof,
        expectedCandidate: SegmentedShadowDescriptor? = nil
    ) throws -> SegmentedShadowRoot {
        guard try validateSemanticProof(proof),
            try boundedRootExtends(current, frozen: frozen),
            proof.frozenRootSeal == frozen.seal,
            proof.frozenStateCommitment == proof.candidateStateCommitment,
            proof.candidateBase.kind == .base,
            expectedCandidate == nil || proof.candidateBase == expectedCandidate
        else { throw SegmentedManifestShadowError.invalidFormat }
        try validateDescriptorShape(proof.candidateBase)
        let suffix = Array(current.runs.dropFirst(frozen.runs.count))
        let generation = current.generation.addingReportingOverflow(1)
        guard !generation.overflow else { throw SegmentedManifestShadowError.invalidFormat }
        return try makeRoot(
            generation: generation.partialValue,
            base: proof.candidateBase,
            runs: suffix
        )
    }

    private static func makeSemanticProofValue(
        frozenRootSeal: String,
        candidateBase: SegmentedShadowDescriptor,
        frozenCommitment: String,
        candidateCommitment: String
    ) throws -> SegmentedShadowSemanticProof {
        let transcript = SegmentedShadowSemanticProofTranscript(
            schemaVersion: 1,
            frozenRootSeal: frozenRootSeal,
            candidateBase: candidateBase,
            frozenStateCommitment: frozenCommitment,
            candidateStateCommitment: candidateCommitment
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(transcript)
        let seal = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return SegmentedShadowSemanticProof(
            schemaVersion: transcript.schemaVersion,
            frozenRootSeal: frozenRootSeal,
            candidateBase: candidateBase,
            frozenStateCommitment: frozenCommitment,
            candidateStateCommitment: candidateCommitment,
            seal: seal
        )
    }

    private static func validateSemanticProof(_ proof: SegmentedShadowSemanticProof) throws -> Bool {
        guard proof.schemaVersion == 1,
            proof.frozenRootSeal.utf8.count == 64,
            proof.frozenStateCommitment.utf8.count == 64,
            proof.candidateStateCommitment.utf8.count == 64
        else { return false }
        let expected = try makeSemanticProofValue(
            frozenRootSeal: proof.frozenRootSeal,
            candidateBase: proof.candidateBase,
            frozenCommitment: proof.frozenStateCommitment,
            candidateCommitment: proof.candidateStateCommitment
        )
        return expected == proof
    }

    private static func semanticProofReplacingCandidate(
        _ proof: SegmentedShadowSemanticProof,
        candidateBase: SegmentedShadowDescriptor
    ) throws -> SegmentedShadowSemanticProof {
        try makeSemanticProofValue(
            frozenRootSeal: proof.frozenRootSeal,
            candidateBase: candidateBase,
            frozenCommitment: proof.frozenStateCommitment,
            candidateCommitment: proof.candidateStateCommitment
        )
    }

    private static func boundedRootExtends(
        _ current: SegmentedShadowRoot,
        frozen: SegmentedShadowRoot
    ) throws -> Bool {
        guard try validateRootSeal(current),
            try validateRootSeal(frozen),
            current.generation >= frozen.generation,
            current.base == frozen.base,
            current.runs.count >= frozen.runs.count
        else { return false }
        return Array(current.runs.prefix(frozen.runs.count)) == frozen.runs
    }

    private static func boundedRecover(
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

    private static func boundedRejects(
        frozen: SegmentedShadowRoot,
        current: SegmentedShadowRoot,
        proof: SegmentedShadowSemanticProof,
        expectedCandidate: SegmentedShadowDescriptor? = nil
    ) -> Bool {
        do {
            _ = try boundedRebasedRoot(
                frozen: frozen,
                current: current,
                proof: proof,
                expectedCandidate: expectedCandidate
            )
            return false
        } catch {
            return true
        }
    }

    private static func boundedWriteBase(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    private static func boundedWriteRun(
        _ mutations: [SegmentedShadowMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: url)
        return try descriptor(.run, url: url, expectedRecords: mutations.count)
    }

    private static func boundedMixedSuffix(
        _ frozenEntries: [SegmentedShadowEntry]
    ) throws -> [SegmentedShadowMutation] {
        guard frozenEntries.count >= 2 else { throw SegmentedManifestShadowError.invalidFormat }
        let repairSource = frozenEntries[1]
        let repaired = SegmentedShadowEntry(
            key: repairSource.key,
            physicalID: PhysicalBlobID(),
            partition: repairSource.partition,
            digest: repairSource.digest,
            byteCount: repairSource.byteCount,
            lastAccess: repairSource.lastAccess.addingTimeInterval(2)
        )
        return [
            .tombstone(key: frozenEntries[0].key),
            .upsert(repaired),
            .upsert(try boundedEntry(label: "suffix-new-0")),
            .upsert(try boundedEntry(label: "suffix-new-1")),
        ].sorted { $0.key < $1.key }
    }

    private static func boundedEntry(label: String) throws -> SegmentedShadowEntry {
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-bounded-proof-v1",
            material: Data(label.utf8)
        )
        let payload = Data("bounded-proof-\(label)".utf8)
        let digest = BlobDigest.sha256(of: payload)
        return SegmentedShadowEntry(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            physicalID: PhysicalBlobID(),
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 970_000_000)
        )
    }
}
