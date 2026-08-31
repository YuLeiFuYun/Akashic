import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum ManifestEncodeProbeError: Error {
    case invalidArguments
}

private struct ManifestEncodeReport: Codable {
    let schemaVersion: Int
    let entryCount: Int
    let blobBytes: Int
    let encodedManifestBytes: Int
    let validationNanoseconds: [UInt64]
    let encodeNanoseconds: [UInt64]
    let claims: ManifestEncodeClaims
}

private struct ManifestEncodeClaims: Codable {
    let formalPerformance: Bool
    let physicalDevice: Bool
    let physicalIOBytes: Bool
}

enum ManifestEncodeProbe {
    static func run(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw ManifestEncodeProbeError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootValue = values["--root"],
            let entryCountValue = values["--entry-count"],
            let blobBytesValue = values["--blob-bytes"],
            let entryCount = Int(entryCountValue), entryCount >= 0, entryCount < 512,
            let blobBytes = Int(blobBytesValue), blobBytes >= 8
        else {
            throw ManifestEncodeProbeError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let logicalBytes = max(1, entryCount).multipliedReportingOverflow(by: blobBytes)
        guard !logicalBytes.overflow else { throw ManifestEncodeProbeError.invalidArguments }
        let softLimit = logicalBytes.partialValue.multipliedReportingOverflow(by: 4)
        guard !softLimit.overflow else { throw ManifestEncodeProbeError.invalidArguments }

        let partition = try CachePartitionID.derive(
            domain: "akashic-resource-manifest-encode-v1",
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

        var validationSamples: [UInt64] = []
        validationSamples.reserveCapacity(5)
        for _ in 0 ..< 5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let valid = await store.resourceProbeValidateManifest()
            validationSamples.append(DispatchTime.now().uptimeNanoseconds &- start)
            precondition(valid)
        }

        var samples: [UInt64] = []
        samples.reserveCapacity(5)
        var encodedBytes = 0
        for _ in 0 ..< 5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let encoded = try await store.resourceProbeEncodedManifestSnapshot()
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
            if encodedBytes == 0 {
                encodedBytes = encoded.count
            } else {
                precondition(encodedBytes == encoded.count)
            }
        }

        let report = ManifestEncodeReport(
            schemaVersion: 1,
            entryCount: entryCount,
            blobBytes: blobBytes,
            encodedManifestBytes: encodedBytes,
            validationNanoseconds: validationSamples,
            encodeNanoseconds: samples,
            claims: ManifestEncodeClaims(
                formalPerformance: false,
                physicalDevice: false,
                physicalIOBytes: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
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
