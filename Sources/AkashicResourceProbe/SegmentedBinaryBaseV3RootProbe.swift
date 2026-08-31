import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct BinaryBaseV3DifferentialCase: Codable {
    let entryCount: Int
    let byteExact: Bool
    let diskDecodeExact: Bool
    let oracleDecodeExact: Bool
    let semanticCommitmentExact: Bool
}

private struct BinaryBaseV3RootShadowReport: Codable {
    struct Claims: Codable {
        let researchOnly: Bool
        let publicFileBlobStoreAdoption: Bool
        let automaticMigration: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let fixedCases: [BinaryBaseV3DifferentialCase]
    let generatedSeedCount: Int
    let generatedByteExactCount: Int
    let corruptionCaseCount: Int
    let diskCorruptionRejectedCount: Int
    let oracleCorruptionRejectedCount: Int
    let rootRecoveredExact: Bool
    let physicalOwnershipExact: Bool
    let mixedProfilesRejected: Bool
    let segmentNameStrict: Bool
    let allCasesPass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func binaryBaseV3RootShadow() throws {
        let counts = [0, 1, 512, 1_024, 16_384, 99_488]
        var fixed: [BinaryBaseV3DifferentialCase] = []
        for (seed, count) in counts.enumerated() {
            let state = try binaryBaseCandidateState(count: count, seed: 90_000 + seed)
            let oracle = try SegmentedCompactBinaryBaseCandidate.encode(state)
            let disk = try SegmentedManifestBinaryBaseV2.encode(state)
            let oracleDecoded = try SegmentedCompactBinaryBaseCandidate.decode(oracle)
            let diskDecoded = try SegmentedManifestBinaryBaseV2.decode(disk)
            let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(state)
            fixed.append(
                BinaryBaseV3DifferentialCase(
                    entryCount: count,
                    byteExact: oracle == disk,
                    diskDecodeExact: diskDecoded == state,
                    oracleDecodeExact: oracleDecoded == state,
                    semanticCommitmentExact:
                        try SegmentedManifestPrototypeV1.semanticStateCommitment(diskDecoded)
                            == commitment
                        && SegmentedManifestPrototypeV1.semanticStateCommitment(oracleDecoded)
                            == commitment
                )
            )
        }

        var generatedExact = 0
        for seed in 0..<64 {
            let count = 2 + (seed * 41) % 271
            let state = try binaryBaseCandidateState(count: count, seed: 100_000 + seed)
            let oracle = try SegmentedCompactBinaryBaseCandidate.encode(state)
            let disk = try SegmentedManifestBinaryBaseV2.encode(state)
            if oracle == disk,
                try SegmentedCompactBinaryBaseCandidate.decode(oracle) == state,
                try SegmentedManifestBinaryBaseV2.decode(disk) == state
            {
                generatedExact += 1
            }
        }

        let corruptionState = try binaryBaseCandidateState(count: 4, seed: 110_000)
        let valid = try SegmentedCompactBinaryBaseCandidate.encode(corruptionState)
        let corruptions = try binaryBaseV3Corruptions(valid: valid)
        var diskRejected = 0
        var oracleRejected = 0
        for item in corruptions {
            do { _ = try SegmentedManifestBinaryBaseV2.decode(item.data) }
            catch { diskRejected += 1 }
            do { _ = try SegmentedCompactBinaryBaseCandidate.decode(item.data) }
            catch { oracleRejected += 1 }
        }

        let rootState = try binaryBaseCandidateState(count: 1_024, seed: 120_000)
        let rootResult = try binaryBaseV3RootRoundTrip(rootState)
        let mixedRejected = try binaryBaseV3MixedProfilesRejected()
        let name = "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        let segmentNameStrict = SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            name,
            kind: .baseBinaryV2
        ) && !SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            name.uppercased(),
            kind: .baseBinaryV2
        ) && !SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            name.replacingOccurrences(of: ".akb2", with: ".akb"),
            kind: .baseBinaryV2
        )

        let allPass = fixed.allSatisfy {
            $0.byteExact && $0.diskDecodeExact && $0.oracleDecodeExact && $0.semanticCommitmentExact
        } && generatedExact == 64
            && diskRejected == corruptions.count
            && oracleRejected == corruptions.count
            && rootResult.exact
            && rootResult.physicalExact
            && mixedRejected
            && segmentNameStrict
        guard allPass else { throw SegmentedManifestShadowError.invariantViolation }

        let report = BinaryBaseV3RootShadowReport(
            schemaVersion: 1,
            fixedCases: fixed,
            generatedSeedCount: 64,
            generatedByteExactCount: generatedExact,
            corruptionCaseCount: corruptions.count,
            diskCorruptionRejectedCount: diskRejected,
            oracleCorruptionRejectedCount: oracleRejected,
            rootRecoveredExact: rootResult.exact,
            physicalOwnershipExact: rootResult.physicalExact,
            mixedProfilesRejected: mixedRejected,
            segmentNameStrict: segmentNameStrict,
            allCasesPass: allPass,
            claims: .init(
                researchOnly: true,
                publicFileBlobStoreAdoption: false,
                automaticMigration: false,
                formalPerformance: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func binaryBaseV3RootRoundTrip(
        _ state: [String: SegmentedManifestEntry]
    ) throws -> (exact: Bool, physicalExact: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-binary-v3-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let base = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
            state,
            fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
            directory: segments
        )
        let manifest = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: 1,
            base: base,
            runs: []
        )
        let rootURL = root.appendingPathComponent("root.json")
        try SegmentedManifestPrototypeV1.writeRoot(manifest, to: rootURL)
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: rootURL,
            segmentDirectory: segments
        )
        let expectedPhysical = Dictionary(uniqueKeysWithValues: state.map { ($0.key, $0.value.physicalID) })
        let recoveredPhysical = Dictionary(
            uniqueKeysWithValues: recovered.map { ($0.key, $0.value.physicalID) }
        )
        return (recovered == state, recoveredPhysical == expectedPhysical)
    }

    private static func binaryBaseV3MixedProfilesRejected() throws -> Bool {
        let json = SegmentedManifestDescriptorV1(
            kind: .baseJSON,
            fileName: "base-mixed.json",
            byteCount: 1,
            recordCount: 0,
            sha256: String(repeating: "0", count: 64)
        )
        let v2 = SegmentedManifestDescriptorV1(
            kind: .baseBinaryV1,
            fileName: "base-binary-\(UUID().uuidString.lowercased()).akb",
            byteCount: SegmentedManifestBinaryBaseV1.expectedByteCount(recordCount: 0) ?? -1,
            recordCount: 0,
            sha256: String(repeating: "0", count: 64)
        )
        let v3 = SegmentedManifestDescriptorV1(
            kind: .baseBinaryV2,
            fileName: "base-binary-v2-\(UUID().uuidString.lowercased()).akb2",
            byteCount: SegmentedManifestBinaryBaseV2.expectedByteCount(recordCount: 0) ?? -1,
            recordCount: 0,
            sha256: String(repeating: "0", count: 64)
        )
        return binaryBaseV3RootRejected { try SegmentedManifestPrototypeV1.makeRoot(generation: 1, base: v3, runs: []) }
            && binaryBaseV3RootRejected { try SegmentedManifestPrototypeV1.makeRootV2(generation: 1, base: v3, runs: []) }
            && binaryBaseV3RootRejected { try SegmentedManifestPrototypeV1.makeRootV3(generation: 1, base: json, runs: []) }
            && binaryBaseV3RootRejected { try SegmentedManifestPrototypeV1.makeRootV3(generation: 1, base: v2, runs: []) }
    }

    private static func binaryBaseV3RootRejected(
        _ operation: () throws -> SegmentedManifestRootV1
    ) -> Bool {
        do { _ = try operation(); return false }
        catch { return true }
    }

    private static func binaryBaseV3Corruptions(
        valid: Data
    ) throws -> [(name: String, data: Data)] {
        let header = SegmentedCompactBinaryBaseCandidate.headerBytes
        let record = SegmentedCompactBinaryBaseCandidate.recordBytes
        guard valid.count >= header + 2 * record else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        var cases: [(String, Data)] = []
        var badMagic = valid; badMagic[0] ^= 0xff; cases.append(("bad-magic", badMagic))
        var futureVersion = valid; futureVersion[8] = 3; cases.append(("future-version", futureVersion))
        var badWidth = valid; binaryBaseV3WriteUInt16(UInt16(record + 1), to: &badWidth, offset: 9); cases.append(("wrong-record-width", badWidth))
        var reserved = valid; reserved[11] = 1; cases.append(("nonzero-reserved", reserved))
        var tooMany = valid; binaryBaseV3WriteUInt64(UInt64(SegmentedCompactBinaryBaseCandidate.maximumRecords + 1), to: &tooMany, offset: 16); cases.append(("count-over-limit", tooMany))
        var lengthMismatch = valid; binaryBaseV3WriteUInt64(UInt64(valid.count - header + record), to: &lengthMismatch, offset: 24); cases.append(("payload-length-mismatch", lengthMismatch))
        cases.append(("truncated", Data(valid.dropLast())))
        var trailing = valid; trailing.append(0); cases.append(("trailing-byte", trailing))
        var payloadHash = valid; payloadHash[header] ^= 1; cases.append(("payload-hash-mismatch", payloadHash))
        var badByteCount = valid; binaryBaseV3WriteUInt32(UInt32(SegmentedManifestPrototypeV1.maximumBlobBytes + 1), to: &badByteCount, offset: header + 80); binaryBaseV3RewriteDigest(&badByteCount); cases.append(("blob-byte-count-over-limit", badByteCount))
        var nonFinite = valid; binaryBaseV3WriteUInt64(Double.infinity.bitPattern, to: &nonFinite, offset: header + 84); binaryBaseV3RewriteDigest(&nonFinite); cases.append(("nonfinite-last-access", nonFinite))
        var duplicatePhysical = valid; duplicatePhysical.replaceSubrange((header + record)..<(header + record + 16), with: valid[header..<(header + 16)]); binaryBaseV3RewriteDigest(&duplicatePhysical); cases.append(("duplicate-physical-id", duplicatePhysical))
        var duplicateLogical = valid; duplicateLogical.replaceSubrange((header + record + 16)..<(header + record + 84), with: valid[(header + 16)..<(header + 84)]); binaryBaseV3RewriteDigest(&duplicateLogical); cases.append(("duplicate-recomputed-key", duplicateLogical))
        var outOfOrder = valid
        let first = Data(valid[header..<(header + record)])
        let second = Data(valid[(header + record)..<(header + 2 * record)])
        outOfOrder.replaceSubrange(header..<(header + record), with: second)
        outOfOrder.replaceSubrange((header + record)..<(header + 2 * record), with: first)
        binaryBaseV3RewriteDigest(&outOfOrder); cases.append(("out-of-order-recomputed-key", outOfOrder))
        return cases
    }

    private static func binaryBaseV3RewriteDigest(_ data: inout Data) {
        let digest = Data(SHA256.hash(data: data.dropFirst(SegmentedCompactBinaryBaseCandidate.headerBytes)))
        data.replaceSubrange(32..<64, with: digest)
    }

    private static func binaryBaseV3WriteUInt16(_ value: UInt16, to data: inout Data, offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 2), with: $0) }
    }

    private static func binaryBaseV3WriteUInt32(_ value: UInt32, to data: inout Data, offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private static func binaryBaseV3WriteUInt64(_ value: UInt64, to data: inout Data, offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 8), with: $0) }
    }
}
