import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum ReopenScalingProbeError: Error {
    case invalidArguments
    case invalidManifest
    case directoryHeadUnavailable
}

private struct ReopenPhaseSample: Codable {
    let phase: String
    let offsetNanoseconds: UInt64
}

private final class ReopenPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let origin: UInt64
    private var samples: [ReopenPhaseSample] = []

    init(origin: UInt64) {
        self.origin = origin
    }

    func record(_ phase: FileBlobStoreBootstrapPhase) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        samples.append(
            ReopenPhaseSample(
                phase: phase.rawValue,
                offsetNanoseconds: now &- origin
            )
        )
        lock.unlock()
    }

    func snapshot() -> [ReopenPhaseSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

private struct ReopenScalingReport: Codable {
    let schemaVersion: Int
    let entryCount: Int
    let blobBytes: Int
    let manifestSchemaVersion: Int
    let directoryHeadMigrated: Bool
    let manifestGeneration: UInt64
    let manifestRecordCount: Int
    let manifestBytes: Int
    let reopenNanoseconds: UInt64
    let securityValidateNanoseconds: UInt64
    let securityRepairNanoseconds: UInt64
    let phases: [ReopenPhaseSample]
    let claims: ReopenScalingClaims
}

private struct ReopenScalingClaims: Codable {
    let formalPerformance: Bool
    let physicalDevice: Bool
    let physicalIOBytes: Bool
}

enum ReopenScalingProbe {
    static func run(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw ReopenScalingProbeError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootValue = values["--root"],
            let entryCountValue = values["--entry-count"],
            let blobBytesValue = values["--blob-bytes"],
            let entryCount = Int(entryCountValue), entryCount > 0,
            let blobBytes = Int(blobBytesValue), blobBytes >= 8
        else {
            throw ReopenScalingProbeError.invalidArguments
        }

        let migrateDirectoryHead = values["--migrate-directory-head"] == "1"
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let logicalBytes = entryCount.multipliedReportingOverflow(by: blobBytes)
        guard !logicalBytes.overflow else { throw ReopenScalingProbeError.invalidArguments }
        let softLimit = logicalBytes.partialValue.multipliedReportingOverflow(by: 4)
        guard !softLimit.overflow else { throw ReopenScalingProbeError.invalidArguments }

        let limits = FileBlobStoreLimits(
            softTotalBytes: max(blobBytes, softLimit.partialValue),
            maximumBlobBytes: blobBytes
        )
        let directoryHeadMigrated = try await populate(
            root: root,
            entryCount: entryCount,
            blobBytes: blobBytes,
            limits: limits,
            migrateDirectoryHead: migrateDirectoryHead
        )
        for _ in 0 ..< 64 { await Task.yield() }

        let before = try manifestState(root: root)
        let reopenStart = DispatchTime.now().uptimeNanoseconds
        let phaseRecorder = ReopenPhaseRecorder(origin: reopenStart)
        let reopened = try await FileBlobStore.open(
            root: root,
            limits: limits,
            faultInjector: { _ in },
            bootstrapObserver: { phase in phaseRecorder.record(phase) }
        )
        let reopenNanoseconds = DispatchTime.now().uptimeNanoseconds &- reopenStart

        let validateStart = DispatchTime.now().uptimeNanoseconds
        let validatedCount = try await reopened.resourceProbePublishedFileSecurityPass(repair: false)
        let securityValidateNanoseconds = DispatchTime.now().uptimeNanoseconds &- validateStart
        precondition(validatedCount == entryCount)

        let repairStart = DispatchTime.now().uptimeNanoseconds
        let repairedCount = try await reopened.resourceProbePublishedFileSecurityPass(repair: true)
        let securityRepairNanoseconds = DispatchTime.now().uptimeNanoseconds &- repairStart
        precondition(repairedCount == entryCount)

        let report = ReopenScalingReport(
            schemaVersion: 1,
            entryCount: entryCount,
            blobBytes: blobBytes,
            manifestSchemaVersion: before.schemaVersion,
            directoryHeadMigrated: directoryHeadMigrated,
            manifestGeneration: before.generation,
            manifestRecordCount: before.recordCount,
            manifestBytes: before.bytes,
            reopenNanoseconds: reopenNanoseconds,
            securityValidateNanoseconds: securityValidateNanoseconds,
            securityRepairNanoseconds: securityRepairNanoseconds,
            phases: phaseRecorder.snapshot(),
            claims: ReopenScalingClaims(
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

    private static func populate(
        root: URL,
        entryCount: Int,
        blobBytes: Int,
        limits: FileBlobStoreLimits,
        migrateDirectoryHead: Bool
    ) async throws -> Bool {
        let partition = try CachePartitionID.derive(
            domain: "akashic-resource-reopen-scaling-v1",
            material: Data("domain-neutral".utf8)
        )
        let store = try await FileBlobStore.open(root: root, limits: limits)
        for entryIndex in 0 ..< entryCount {
            let data = payload(index: entryIndex, byteCount: blobBytes)
            _ = try await store.commit(
                data: data,
                digest: BlobDigest.sha256(of: data),
                partition: partition
            )
        }
        if migrateDirectoryHead {
            guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
                throw ReopenScalingProbeError.directoryHeadUnavailable
            }
            return true
        }
        return false
    }

    private static func payload(index: Int, byteCount: Int) -> Data {
        var result = Data(repeating: 0xA5, count: byteCount)
        var value = UInt64(index).littleEndian
        withUnsafeBytes(of: &value) { bytes in
            result.replaceSubrange(0 ..< 8, with: bytes)
        }
        return result
    }

    private static func manifestState(root: URL) throws -> (
        schemaVersion: Int,
        generation: UInt64,
        recordCount: Int,
        bytes: Int
    ) {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
            let schemaVersion = dictionary["schemaVersion"] as? NSNumber,
            let generation = dictionary["generation"] as? NSNumber
        else {
            throw ReopenScalingProbeError.invalidManifest
        }
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        let recordCount = names.reduce(into: 0) { count, name in
            if name.hasPrefix(".manifest-entry-") && name.hasSuffix(".json") {
                count += 1
            }
        }
        return (schemaVersion.intValue, generation.uint64Value, recordCount, data.count)
    }
}
