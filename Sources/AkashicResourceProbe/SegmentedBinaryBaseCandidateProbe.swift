import AkashicCore
import AkashicDisk
import Foundation

private struct BinaryBaseCorrectnessCase: Codable {
    let name: String
    let entryCount: Int
    let binaryBytes: Int
    let jsonBytes: Int
    let exactDecode: Bool
    let semanticCommitmentExact: Bool
    let stableReencode: Bool
    let fixedWidthExact: Bool
}

private struct BinaryBaseCorrectnessReport: Codable {
    struct Claims: Codable {
        let productionFormat: Bool
        let rootProfileIntegration: Bool
        let automaticMigration: Bool
        let formalPerformance: Bool
    }

    let schemaVersion: Int
    let fixedCases: [BinaryBaseCorrectnessCase]
    let generatedSeedCount: Int
    let generatedExactCount: Int
    let corruptionCaseCount: Int
    let corruptionRejectedCount: Int
    let corruptionNames: [String]
    let allCasesPass: Bool
    let claims: Claims
}

private struct BinaryBaseResourceCase: Codable {
    let entryCount: Int
    let jsonBytes: Int
    let binaryBytes: Int
    let theoreticalBinaryBytes: Int
    let byteReductionRatio: Double
    let repetitions: Int
    let jsonEncodeMedianNanoseconds: UInt64
    let binaryEncodeMedianNanoseconds: UInt64
    let jsonDecodeOnlyMedianNanoseconds: UInt64
    let jsonDecodeAndValidateMedianNanoseconds: UInt64
    let binaryDecodeAndValidateMedianNanoseconds: UInt64
    let exactState: Bool
}

private struct BinaryBaseResourceReport: Codable {
    struct Claims: Codable {
        let mechanismMeasurement: Bool
        let formalPerformance: Bool
        let productionFormat: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let cases: [BinaryBaseResourceCase]
    let allCasesPass: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func binaryBaseCorrectness() throws {
        let counts = [0, 1, 512, 1_024, 16_384, 99_488]
        var fixed: [BinaryBaseCorrectnessCase] = []
        for (seed, count) in counts.enumerated() {
            let state = try binaryBaseCandidateState(count: count, seed: seed + 1)
            let binary = try SegmentedBinaryBaseCandidate.encode(state)
            let decoded = try SegmentedBinaryBaseCandidate.decode(binary)
            let json = try binaryBaseCandidateJSON(state)
            let jsonDecoded = try binaryBaseCandidateJSONDecode(json)
            let stable = try SegmentedBinaryBaseCandidate.encode(decoded) == binary
            let commitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(state)
            let decodedCommitment = try SegmentedManifestPrototypeV1.semanticStateCommitment(decoded)
            let exact = decoded == state && jsonDecoded == state
            fixed.append(
                BinaryBaseCorrectnessCase(
                    name: "count-\(count)",
                    entryCount: count,
                    binaryBytes: binary.count,
                    jsonBytes: json.count,
                    exactDecode: exact,
                    semanticCommitmentExact: commitment == decodedCommitment,
                    stableReencode: stable,
                    fixedWidthExact: binary.count
                        == SegmentedBinaryBaseCandidate.headerBytes
                        + SegmentedBinaryBaseCandidate.recordBytes * count
                )
            )
        }

        var generatedExact = 0
        for seed in 0..<64 {
            let count = 2 + (seed * 37) % 257
            let state = try binaryBaseCandidateState(count: count, seed: 1000 + seed)
            let binary = try SegmentedBinaryBaseCandidate.encode(state)
            let decoded = try SegmentedBinaryBaseCandidate.decode(binary)
            let json = try binaryBaseCandidateJSON(state)
            let jsonDecoded = try binaryBaseCandidateJSONDecode(json)
            if decoded == state,
                jsonDecoded == state,
                try SegmentedBinaryBaseCandidate.encode(decoded) == binary,
                binary.count == SegmentedBinaryBaseCandidate.headerBytes
                    + SegmentedBinaryBaseCandidate.recordBytes * count,
                try SegmentedManifestPrototypeV1.semanticStateCommitment(decoded)
                    == SegmentedManifestPrototypeV1.semanticStateCommitment(state)
            {
                generatedExact += 1
            }
        }

        let corruptionState = try binaryBaseCandidateState(count: 4, seed: 9000)
        let valid = try SegmentedBinaryBaseCandidate.encode(corruptionState)
        let corruptions = try binaryBaseCandidateCorruptions(valid: valid)
        var rejected = 0
        var names: [String] = []
        for corruption in corruptions {
            do {
                _ = try SegmentedBinaryBaseCandidate.decode(corruption.data)
            } catch {
                rejected += 1
                names.append(corruption.name)
            }
        }
        let allPass = fixed.allSatisfy {
            $0.exactDecode && $0.semanticCommitmentExact && $0.stableReencode && $0.fixedWidthExact
        } && generatedExact == 64 && rejected == corruptions.count
        guard allPass else { throw SegmentedManifestShadowError.invariantViolation }

        let report = BinaryBaseCorrectnessReport(
            schemaVersion: 1,
            fixedCases: fixed,
            generatedSeedCount: 64,
            generatedExactCount: generatedExact,
            corruptionCaseCount: corruptions.count,
            corruptionRejectedCount: rejected,
            corruptionNames: names,
            allCasesPass: allPass,
            claims: .init(
                productionFormat: false,
                rootProfileIntegration: false,
                automaticMigration: false,
                formalPerformance: false
            )
        )
        try binaryBaseWriteJSON(report)
    }

    static func binaryBaseResource() throws {
        let repetitions = 3
        let counts = [1_024, 16_384, 99_488]
        var cases: [BinaryBaseResourceCase] = []
        for (seed, count) in counts.enumerated() {
            let state = try binaryBaseCandidateState(count: count, seed: 20_000 + seed)
            let shadow = schema5DepthShadow(state)
            let jsonWarm = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
                generation: 1,
                entries: shadow
            )
            let binaryWarm = try SegmentedBinaryBaseCandidate.encode(state)
            _ = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(jsonWarm)
            _ = try binaryBaseCandidateJSONDecodeValidated(jsonWarm)
            _ = try SegmentedBinaryBaseCandidate.decode(binaryWarm)

            var jsonEncodeTimes: [UInt64] = []
            var binaryEncodeTimes: [UInt64] = []
            var jsonDecodeOnlyTimes: [UInt64] = []
            var jsonDecodeAndValidateTimes: [UInt64] = []
            var binaryDecodeAndValidateTimes: [UInt64] = []
            var lastJSON = jsonWarm
            var lastBinary = binaryWarm
            var exact = true
            for _ in 0..<repetitions {
                let jsonEncodeStart = DispatchTime.now().uptimeNanoseconds
                lastJSON = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
                    generation: 1,
                    entries: shadow
                )
                jsonEncodeTimes.append(DispatchTime.now().uptimeNanoseconds &- jsonEncodeStart)

                let binaryEncodeStart = DispatchTime.now().uptimeNanoseconds
                lastBinary = try SegmentedBinaryBaseCandidate.encode(state)
                binaryEncodeTimes.append(DispatchTime.now().uptimeNanoseconds &- binaryEncodeStart)

                let jsonDecodeOnlyStart = DispatchTime.now().uptimeNanoseconds
                _ = try FileBlobStore.resourceProbeDecodeDirectoryHeadSnapshot(lastJSON)
                jsonDecodeOnlyTimes.append(
                    DispatchTime.now().uptimeNanoseconds &- jsonDecodeOnlyStart
                )

                let jsonValidatedStart = DispatchTime.now().uptimeNanoseconds
                let jsonDecoded = try binaryBaseCandidateJSONDecodeValidated(lastJSON)
                jsonDecodeAndValidateTimes.append(
                    DispatchTime.now().uptimeNanoseconds &- jsonValidatedStart
                )

                let binaryDecodeStart = DispatchTime.now().uptimeNanoseconds
                let binaryDecoded = try SegmentedBinaryBaseCandidate.decode(lastBinary)
                binaryDecodeAndValidateTimes.append(
                    DispatchTime.now().uptimeNanoseconds &- binaryDecodeStart
                )
                if jsonDecoded != state || binaryDecoded != state { exact = false }
            }
            let theoretical = SegmentedBinaryBaseCandidate.headerBytes
                + SegmentedBinaryBaseCandidate.recordBytes * count
            let caseReport = BinaryBaseResourceCase(
                entryCount: count,
                jsonBytes: lastJSON.count,
                binaryBytes: lastBinary.count,
                theoreticalBinaryBytes: theoretical,
                byteReductionRatio: 1 - Double(lastBinary.count) / Double(lastJSON.count),
                repetitions: repetitions,
                jsonEncodeMedianNanoseconds: binaryBaseMedian(jsonEncodeTimes),
                binaryEncodeMedianNanoseconds: binaryBaseMedian(binaryEncodeTimes),
                jsonDecodeOnlyMedianNanoseconds: binaryBaseMedian(jsonDecodeOnlyTimes),
                jsonDecodeAndValidateMedianNanoseconds: binaryBaseMedian(
                    jsonDecodeAndValidateTimes
                ),
                binaryDecodeAndValidateMedianNanoseconds: binaryBaseMedian(
                    binaryDecodeAndValidateTimes
                ),
                exactState: exact && lastBinary.count == theoretical
            )
            cases.append(caseReport)
        }
        let allPass = cases.allSatisfy(\.exactState)
        guard allPass else { throw SegmentedManifestShadowError.invariantViolation }
        try binaryBaseWriteJSON(
            BinaryBaseResourceReport(
                schemaVersion: 2,
                cases: cases,
                allCasesPass: allPass,
                claims: .init(
                    mechanismMeasurement: true,
                    formalPerformance: false,
                    productionFormat: false,
                    physicalDevice: false
                )
            )
        )
    }

    private static func binaryBaseMedian(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func binaryBaseWriteJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
