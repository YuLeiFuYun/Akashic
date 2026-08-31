import AkashicCore
import AkashicDisk
import Foundation

private enum RecordReplayProbeError: Error {
    case invalidArguments
}

private struct RecordReplayReport: Codable {
    let schemaVersion: Int
    let entryCount: Int
    let blobBytes: Int
    let recordCount: Int
    let enumerationAndParseNanoseconds: [UInt64]
    let boundedReadNanoseconds: [UInt64]
    let decodeFreshDecoderNanoseconds: [UInt64]
    let decodeSharedDecoderNanoseconds: [UInt64]
    let keyValidationNanoseconds: [UInt64]
    let fullManifestValidationNanoseconds: [UInt64]
    let claims: Claims

    struct Claims: Codable {
        let formalPerformance: Bool
        let physicalDevice: Bool
        let physicalIOBytes: Bool
    }
}

enum RecordReplayProbe {
    static func run(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw RecordReplayProbeError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootValue = values["--root"],
            let entryCountValue = values["--entry-count"],
            let blobBytesValue = values["--blob-bytes"],
            let entryCount = Int(entryCountValue), entryCount > 0, entryCount < 512,
            let blobBytes = Int(blobBytesValue), blobBytes >= 8
        else {
            throw RecordReplayProbeError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let logicalBytes = entryCount.multipliedReportingOverflow(by: blobBytes)
        guard !logicalBytes.overflow else { throw RecordReplayProbeError.invalidArguments }
        let softLimit = logicalBytes.partialValue.multipliedReportingOverflow(by: 4)
        guard !softLimit.overflow else { throw RecordReplayProbeError.invalidArguments }

        let partition = try CachePartitionID.derive(
            domain: "akashic-resource-record-replay-v1",
            material: Data("domain-neutral".utf8)
        )
        let store = try await FileBlobStore.open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: max(blobBytes, softLimit.partialValue),
                maximumBlobBytes: blobBytes
            )
        )
        for entryIndex in 0 ..< entryCount {
            let data = payload(index: entryIndex, byteCount: blobBytes)
            _ = try await store.commit(
                data: data,
                digest: BlobDigest.sha256(of: data),
                partition: partition
            )
        }

        let diagnostic = try await store.resourceProbeRecordReplayDiagnostic(repetitions: 7)
        let report = RecordReplayReport(
            schemaVersion: 1,
            entryCount: entryCount,
            blobBytes: blobBytes,
            recordCount: diagnostic.recordCount,
            enumerationAndParseNanoseconds: diagnostic.enumerationAndParseNanoseconds,
            boundedReadNanoseconds: diagnostic.boundedReadNanoseconds,
            decodeFreshDecoderNanoseconds: diagnostic.decodeFreshDecoderNanoseconds,
            decodeSharedDecoderNanoseconds: diagnostic.decodeSharedDecoderNanoseconds,
            keyValidationNanoseconds: diagnostic.keyValidationNanoseconds,
            fullManifestValidationNanoseconds: diagnostic.fullManifestValidationNanoseconds,
            claims: .init(
                formalPerformance: false,
                physicalDevice: false,
                physicalIOBytes: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func payload(index: Int, byteCount: Int) -> Data {
        var result = Data(repeating: 0xA5, count: byteCount)
        var value = UInt64(index).littleEndian
        withUnsafeBytes(of: &value) { bytes in
            result.replaceSubrange(0 ..< 8, with: bytes)
        }
        return result
    }
}
