import AkashicCore
import AkashicDisk
import Foundation

private struct BinaryBaseV2DifferentialCase: Codable {
    let entryCount: Int
    let byteExact: Bool
    let diskDecodeExact: Bool
    let probeDecodeExact: Bool
    let semanticCommitmentExact: Bool
}

private struct BinaryBaseV2RootShadowReport: Codable {
    struct Claims: Codable {
        let researchOnly: Bool
        let fileBlobStoreIntegration: Bool
        let automaticMigration: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let fixedCases: [BinaryBaseV2DifferentialCase]
    let generatedSeedCount: Int
    let generatedByteExactCount: Int
    let corruptionCaseCount: Int
    let diskCorruptionRejectedCount: Int
    let rootRecoveredExact: Bool
    let physicalOwnershipExact: Bool
    let v1RejectsBinaryBase: Bool
    let v2RejectsJSONBase: Bool
    let binarySegmentNameStrict: Bool
    let allCasesPass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func binaryBaseV2RootShadow() throws {
        let counts = [0, 1, 512, 1_024, 16_384, 99_488]
        var fixedCases: [BinaryBaseV2DifferentialCase] = []
        for (seed, count) in counts.enumerated() {
            let state = try binaryBaseCandidateState(count: count, seed: 30_000 + seed)
            let probe = try SegmentedBinaryBaseCandidate.encode(state)
            let disk = try SegmentedManifestBinaryBaseV1.encode(state)
            let diskDecoded = try SegmentedManifestBinaryBaseV1.decode(disk)
            let probeDecoded = try SegmentedBinaryBaseCandidate.decode(probe)
            let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(state)
            fixedCases.append(
                BinaryBaseV2DifferentialCase(
                    entryCount: count,
                    byteExact: probe == disk,
                    diskDecodeExact: diskDecoded == state,
                    probeDecodeExact: probeDecoded == state,
                    semanticCommitmentExact:
                        try SegmentedManifestPrototypeV1.semanticStateCommitment(diskDecoded)
                            == commitment
                )
            )
        }

        var generatedByteExact = 0
        for seed in 0..<64 {
            let count = 2 + (seed * 37) % 257
            let state = try binaryBaseCandidateState(count: count, seed: 40_000 + seed)
            if try SegmentedBinaryBaseCandidate.encode(state)
                == SegmentedManifestBinaryBaseV1.encode(state),
                try SegmentedManifestBinaryBaseV1.decode(
                    SegmentedManifestBinaryBaseV1.encode(state)
                ) == state
            {
                generatedByteExact += 1
            }
        }

        let corruptionState = try binaryBaseCandidateState(count: 4, seed: 50_000)
        let valid = try SegmentedBinaryBaseCandidate.encode(corruptionState)
        let corruptions = try binaryBaseCandidateCorruptions(valid: valid)
        var diskRejected = 0
        for corruption in corruptions {
            do {
                _ = try SegmentedManifestBinaryBaseV1.decode(corruption.data)
            } catch {
                diskRejected += 1
            }
        }

        let rootState = try binaryBaseCandidateState(count: 1_024, seed: 60_000)
        let rootResult = try binaryBaseV2RootRoundTrip(rootState)

        let binaryName = "base-binary-\(UUID().uuidString.lowercased()).akb"
        let binaryDescriptor = SegmentedManifestDescriptorV1(
            kind: .baseBinaryV1,
            fileName: binaryName,
            byteCount: SegmentedManifestBinaryBaseV1.expectedByteCount(recordCount: 0) ?? -1,
            recordCount: 0,
            sha256: String(repeating: "0", count: 64)
        )
        let jsonDescriptor = SegmentedManifestDescriptorV1(
            kind: .baseJSON,
            fileName: "base-shadow.json",
            byteCount: 1,
            recordCount: 0,
            sha256: String(repeating: "0", count: 64)
        )
        let v1RejectsBinary = binaryBaseRootRejected {
            try SegmentedManifestPrototypeV1.makeRoot(
                generation: 1,
                base: binaryDescriptor,
                runs: []
            )
        }
        let v2RejectsJSON = binaryBaseRootRejected {
            try SegmentedManifestPrototypeV1.makeRootV2(
                generation: 1,
                base: jsonDescriptor,
                runs: []
            )
        }
        let segmentNameStrict = SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            binaryName,
            kind: .baseBinaryV1
        ) && !SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            binaryName.uppercased(),
            kind: .baseBinaryV1
        ) && !SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            "base-binary-not-a-uuid.akb",
            kind: .baseBinaryV1
        )

        let allPass = fixedCases.allSatisfy {
            $0.byteExact && $0.diskDecodeExact && $0.probeDecodeExact && $0.semanticCommitmentExact
        } && generatedByteExact == 64
            && diskRejected == corruptions.count
            && rootResult.exact
            && rootResult.physicalExact
            && v1RejectsBinary
            && v2RejectsJSON
            && segmentNameStrict
        guard allPass else { throw SegmentedManifestShadowError.invariantViolation }

        try binaryBaseV2WriteJSON(
            BinaryBaseV2RootShadowReport(
                schemaVersion: 1,
                fixedCases: fixedCases,
                generatedSeedCount: 64,
                generatedByteExactCount: generatedByteExact,
                corruptionCaseCount: corruptions.count,
                diskCorruptionRejectedCount: diskRejected,
                rootRecoveredExact: rootResult.exact,
                physicalOwnershipExact: rootResult.physicalExact,
                v1RejectsBinaryBase: v1RejectsBinary,
                v2RejectsJSONBase: v2RejectsJSON,
                binarySegmentNameStrict: segmentNameStrict,
                allCasesPass: allPass,
                claims: .init(
                    researchOnly: true,
                    fileBlobStoreIntegration: false,
                    automaticMigration: false,
                    formalPerformance: false,
                    physicalDevice: false
                )
            )
        )
    }

    private static func binaryBaseV2RootRoundTrip(
        _ state: [String: SegmentedManifestEntry]
    ) throws -> (exact: Bool, physicalExact: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-binary-v2-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let base = try SegmentedManifestPrototypeV1.writeBaseBinary(
            state,
            fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
            directory: segments
        )
        let shadowRoot = try SegmentedManifestPrototypeV1.makeRootV2(
            generation: 1,
            base: base,
            runs: []
        )
        let rootURL = root.appendingPathComponent("root.json")
        try SegmentedManifestPrototypeV1.writeRoot(shadowRoot, to: rootURL)
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: rootURL,
            segmentDirectory: segments
        )
        let originalPhysical = Dictionary(uniqueKeysWithValues: state.map { ($0.key, $0.value.physicalID) })
        let recoveredPhysical = Dictionary(
            uniqueKeysWithValues: recovered.map { ($0.key, $0.value.physicalID) }
        )
        return (recovered == state, recoveredPhysical == originalPhysical)
    }

    private static func binaryBaseRootRejected(
        _ operation: () throws -> SegmentedManifestRootV1
    ) -> Bool {
        do {
            _ = try operation()
            return false
        } catch {
            return true
        }
    }

    private static func binaryBaseV2WriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
