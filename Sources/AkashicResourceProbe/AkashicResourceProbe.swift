import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct ProbeConfiguration {
    let root: URL
    let blobCount: Int
    let blobBytes: Int
    let readPasses: Int

    static func parse(_ arguments: [String]) throws -> ProbeConfiguration {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw ProbeError.invalidArguments }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootValue = values["--root"],
              let blobCountValue = values["--blob-count"],
              let blobBytesValue = values["--blob-bytes"],
              let readPassesValue = values["--read-passes"],
              let blobCount = Int(blobCountValue), blobCount > 0,
              let blobBytes = Int(blobBytesValue), blobBytes > 0,
              let readPasses = Int(readPassesValue), readPasses > 0
        else { throw ProbeError.invalidArguments }
        return ProbeConfiguration(
            root: URL(fileURLWithPath: rootValue, isDirectory: true),
            blobCount: blobCount,
            blobBytes: blobBytes,
            readPasses: readPasses
        )
    }
}

private enum ProbeError: Error {
    case invalidArguments
    case arithmeticOverflow
    case payloadMismatch
    case resourceSampleFailed
}

private struct Claims: Codable {
    let energy: Bool
    let physicalDevice: Bool
    let physicalIOBytes: Bool
    let powerLoss: Bool
}

private struct ResourceUsage: Codable {
    let maximumResidentBytes: Int64
    let sampledOpenFileDescriptors: Int
    let systemCPUNanoseconds: UInt64
    let userCPUNanoseconds: UInt64
}

private struct Footprint: Codable {
    let blobBytes: Int64
    let blobFileCount: Int
    let fileCount: Int
    let metadataBytes: Int64
    let metadataFileCount: Int
    let totalBytes: Int64
}

private struct PopulationResult {
    let commitNanoseconds: UInt64
    let logicalMetadataWriteBytes: Int64
}

private struct ProbeReport: Codable {
    let schemaVersion: Int
    let workloadID: String
    let architecture: String
    let operatingSystemVersion: String
    let blobCount: Int
    let blobBytes: Int
    let readPasses: Int
    let logicalPayloadBytes: Int64
    let logicalReadBytes: Int64
    let logicalMetadataWriteBytes: Int64
    let logicalWriteAmplification: Double
    let commitNanoseconds: UInt64
    let reopenNanoseconds: UInt64
    let readNanoseconds: UInt64
    let footprint: Footprint
    let usage: ResourceUsage
    let claims: Claims
}

private struct InputBlob {
    let data: Data
    let digest: BlobDigest
    let partition: CachePartitionID
}

@main
private enum AkashicResourceProbe {
    static func main() async throws {
        let configuration = try ProbeConfiguration.parse(CommandLine.arguments)
        try resetRoot(configuration.root)
        let logicalPayloadBytes = try checkedProduct(
            configuration.blobCount,
            configuration.blobBytes
        )
        let inputs = try makeInputs(configuration)

        var maximumFDs = sampledOpenFileDescriptors()
        let population = try await populate(
            root: configuration.root,
            inputs: inputs,
            softLimitBytes: logicalPayloadBytes,
            maximumFDs: &maximumFDs
        )

        for _ in 0 ..< 64 {
            await Task.yield()
        }
        let reopenStarted = DispatchTime.now().uptimeNanoseconds
        let reopened = try await FileBlobStore.open(
            root: configuration.root,
            softLimitBytes: Int(logicalPayloadBytes)
        )
        let reopenNanoseconds = DispatchTime.now().uptimeNanoseconds &- reopenStarted
        maximumFDs = max(maximumFDs, sampledOpenFileDescriptors())

        let readStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< configuration.readPasses {
            for input in inputs {
                let restored = try await reopened.read(
                    digest: input.digest,
                    partition: input.partition
                )
                guard restored == input.data else { throw ProbeError.payloadMismatch }
                maximumFDs = max(maximumFDs, sampledOpenFileDescriptors())
            }
        }
        let readNanoseconds = DispatchTime.now().uptimeNanoseconds &- readStarted
        let logicalReadBytes = try checkedProduct(
            logicalPayloadBytes,
            Int64(configuration.readPasses)
        )
        let footprint = try measureFootprint(root: configuration.root)
        let usage = try processUsage(sampledOpenFileDescriptors: maximumFDs)
        let amplification = Double(
            logicalPayloadBytes + population.logicalMetadataWriteBytes
        ) / Double(logicalPayloadBytes)

        let report = ProbeReport(
            schemaVersion: 2,
            workloadID: "blob-\(configuration.blobCount)x\(configuration.blobBytes)-read-\(configuration.readPasses)",
            architecture: architectureName,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            blobCount: configuration.blobCount,
            blobBytes: configuration.blobBytes,
            readPasses: configuration.readPasses,
            logicalPayloadBytes: logicalPayloadBytes,
            logicalReadBytes: logicalReadBytes,
            logicalMetadataWriteBytes: population.logicalMetadataWriteBytes,
            logicalWriteAmplification: amplification,
            commitNanoseconds: population.commitNanoseconds,
            reopenNanoseconds: reopenNanoseconds,
            readNanoseconds: readNanoseconds,
            footprint: footprint,
            usage: usage,
            claims: Claims(
                energy: false,
                physicalDevice: false,
                physicalIOBytes: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileHandle.standardOutput.write(encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func resetRoot(_ root: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            try manager.removeItem(at: root)
        }
    }

    private static func makeInputs(_ configuration: ProbeConfiguration) throws -> [InputBlob] {
        var result: [InputBlob] = []
        result.reserveCapacity(configuration.blobCount)
        for index in 0 ..< configuration.blobCount {
            var data = Data(count: configuration.blobBytes)
            data.withUnsafeMutableBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for offset in 0 ..< bytes.count {
                    bytes[offset] = UInt8(truncatingIfNeeded: (index &* 131) ^ offset)
                }
            }
            let partition = try CachePartitionID.derive(
                domain: "akashic-resource-probe-v1",
                material: Data([UInt8(truncatingIfNeeded: index % 2)])
            )
            result.append(
                InputBlob(
                    data: data,
                    digest: BlobDigest.sha256(of: data),
                    partition: partition
                )
            )
        }
        return result
    }

    private static func populate(
        root: URL,
        inputs: [InputBlob],
        softLimitBytes: Int64,
        maximumFDs: inout Int
    ) async throws -> PopulationResult {
        guard softLimitBytes <= Int64(Int.max) else { throw ProbeError.arithmeticOverflow }
        let openStarted = DispatchTime.now().uptimeNanoseconds
        let store = try await FileBlobStore.open(
            root: root,
            softLimitBytes: Int(softLimitBytes)
        )
        var commitNanoseconds = DispatchTime.now().uptimeNanoseconds &- openStarted
        var previousMetadata = try metadataSnapshot(root: root)
        var logicalMetadataWriteBytes = try previousMetadata.values.reduce(Int64(0)) {
            try checkedSum($0, Int64($1.count))
        }
        for input in inputs {
            let commitStarted = DispatchTime.now().uptimeNanoseconds
            _ = try await store.commit(
                data: input.data,
                digest: input.digest,
                partition: input.partition
            )
            commitNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- commitStarted

            let currentMetadata = try metadataSnapshot(root: root)
            for (path, data) in currentMetadata where previousMetadata[path] != data {
                logicalMetadataWriteBytes = try checkedSum(
                    logicalMetadataWriteBytes,
                    Int64(data.count)
                )
            }
            previousMetadata = currentMetadata
            maximumFDs = max(maximumFDs, sampledOpenFileDescriptors())
        }
        return PopulationResult(
            commitNanoseconds: commitNanoseconds,
            logicalMetadataWriteBytes: logicalMetadataWriteBytes
        )
    }

    private static func measureFootprint(root: URL) throws -> Footprint {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else { throw ProbeError.resourceSampleFailed }
        var blobBytes: Int64 = 0
        var blobFileCount = 0
        var metadataBytes: Int64 = 0
        var metadataFileCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if isBlobPayloadFile(url) {
                blobBytes = try checkedSum(blobBytes, size)
                blobFileCount += 1
            } else {
                metadataBytes = try checkedSum(metadataBytes, size)
                metadataFileCount += 1
            }
        }
        return try Footprint(
            blobBytes: blobBytes,
            blobFileCount: blobFileCount,
            fileCount: blobFileCount + metadataFileCount,
            metadataBytes: metadataBytes,
            metadataFileCount: metadataFileCount,
            totalBytes: checkedSum(blobBytes, metadataBytes)
        )
    }

    private static func metadataSnapshot(root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else { throw ProbeError.resourceSampleFailed }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, !isBlobPayloadFile(url) else { continue }
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }

    private static func isBlobPayloadFile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "blobs"
            && UUID(uuidString: url.lastPathComponent) != nil
    }

    private static func processUsage(sampledOpenFileDescriptors: Int) throws -> ResourceUsage {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw ProbeError.resourceSampleFailed
        }
        return ResourceUsage(
            maximumResidentBytes: Int64(usage.ru_maxrss),
            sampledOpenFileDescriptors: sampledOpenFileDescriptors,
            systemCPUNanoseconds: timevalNanoseconds(usage.ru_stime),
            userCPUNanoseconds: timevalNanoseconds(usage.ru_utime)
        )
    }

    private static func sampledOpenFileDescriptors() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return -1
        }
        return names.reduce(into: 0) { count, name in
            if Int(name) != nil {
                count += 1
            }
        }
    }

    private static func timevalNanoseconds(_ value: timeval) -> UInt64 {
        let seconds = UInt64(max(0, value.tv_sec))
        let microseconds = UInt64(max(0, value.tv_usec))
        return seconds &* 1_000_000_000 &+ microseconds &* 1000
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int64 {
        try checkedProduct(Int64(lhs), Int64(rhs))
    }

    private static func checkedProduct(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw ProbeError.arithmeticOverflow }
        return result.partialValue
    }

    private static func checkedSum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ProbeError.arithmeticOverflow }
        return result.partialValue
    }

    private static var architectureName: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }
}
