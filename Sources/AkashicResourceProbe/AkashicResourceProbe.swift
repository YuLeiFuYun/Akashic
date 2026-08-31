import AkashicCore
import AkashicDisk
import Darwin
import Foundation

struct ProbeConfiguration {
    let root: URL
    let blobCount: Int
    let blobBytes: Int
    let readPasses: Int
    let useDirectoryHead: Bool
    let preseedStore: Bool
    let forceSidecarFastCommit: Bool
    let measurementBarrier: MeasurementBarrier?

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
        let measurementBarrier = try MeasurementBarrier.parse(values)
        let useDirectoryHead = values["--use-directory-head"] == "1"
        return ProbeConfiguration(
            root: URL(fileURLWithPath: rootValue, isDirectory: true),
            blobCount: blobCount,
            blobBytes: blobBytes,
            readPasses: readPasses,
            useDirectoryHead: useDirectoryHead,
            preseedStore: useDirectoryHead || values["--preseed-store"] == "1",
            forceSidecarFastCommit: values["--force-sidecar-fast-commit"] == "1",
            measurementBarrier: measurementBarrier
        )
    }
}

enum ProbeError: Error {
    case invalidArguments
    case arithmeticOverflow
    case measurementBarrierFailed
    case payloadMismatch
    case resourceSampleFailed
    case directoryHeadUnavailable
}

struct MeasurementBarrier {
    let readyFD: Int32
    let goFD: Int32
    let doneFD: Int32
    let releaseFD: Int32

    static func parse(_ values: [String: String]) throws -> MeasurementBarrier? {
        let keys = [
            "--measurement-ready-fd",
            "--measurement-go-fd",
            "--measurement-done-fd",
            "--measurement-release-fd",
        ]
        let present = keys.compactMap { values[$0] }
        if present.isEmpty { return nil }
        guard present.count == keys.count,
              let readyFD = values[keys[0]].flatMap(Int32.init), readyFD >= 0,
              let goFD = values[keys[1]].flatMap(Int32.init), goFD >= 0,
              let doneFD = values[keys[2]].flatMap(Int32.init), doneFD >= 0,
              let releaseFD = values[keys[3]].flatMap(Int32.init), releaseFD >= 0
        else { throw ProbeError.invalidArguments }
        return MeasurementBarrier(
            readyFD: readyFD,
            goFD: goFD,
            doneFD: doneFD,
            releaseFD: releaseFD
        )
    }

    func waitForMeasurementStart() throws {
        try writeByte(0x52, to: readyFD)
        try readByte(from: goFD)
    }

    func waitForMeasurementRelease() throws {
        try writeByte(0x44, to: doneFD)
        try readByte(from: releaseFD)
    }

    private func writeByte(_ value: UInt8, to descriptor: Int32) throws {
        var byte = value
        while true {
            let result = Darwin.write(descriptor, &byte, 1)
            if result == 1 { return }
            if result < 0, errno == EINTR { continue }
            throw ProbeError.measurementBarrierFailed
        }
    }

    private func readByte(from descriptor: Int32) throws {
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(descriptor, &byte, 1)
            if result == 1 { return }
            if result < 0, errno == EINTR { continue }
            throw ProbeError.measurementBarrierFailed
        }
    }
}

struct Claims: Codable {
    let energy: Bool
    let physicalDevice: Bool
    let physicalIOBytes: Bool
    let powerLoss: Bool
}

struct ResourceUsage: Codable {
    let maximumResidentBytes: Int64
    let sampledOpenFileDescriptors: Int
    let systemCPUNanoseconds: UInt64
    let userCPUNanoseconds: UInt64
}

struct Footprint: Codable {
    let blobBytes: Int64
    let blobFileCount: Int
    let fileCount: Int
    /// Regular-file bytes used by manifest snapshots, sidecars, locks and related metadata files.
    let metadataBytes: Int64
    let metadataFileCount: Int
    /// Logical bytes carried by Akashic manifest xattrs on blob inodes. These are kept separate
    /// because `fileSize` does not expose their APFS allocation.
    let metadataAttributeBytes: Int64
    let metadataAttributeCount: Int
    /// Sum of regular-file byte lengths only; xattr physical allocation is intentionally not guessed.
    let totalBytes: Int64
}

struct PopulationResult {
    let commitNanoseconds: UInt64
    let logicalMetadataWriteBytes: Int64
}

struct ProbeReport: Codable {
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

struct InputBlob {
    let data: Data
    let digest: BlobDigest
    let partition: CachePartitionID
}
