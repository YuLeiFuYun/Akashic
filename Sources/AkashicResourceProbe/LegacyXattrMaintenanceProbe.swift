import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum LegacyXattrMaintenanceProbeError: Error {
    case invalidArguments
    case migrationUnavailable
    case unexpectedCleanupResult
    case cleanupIncomplete
}

private struct LegacyXattrMaintenanceReport: Codable {
    let schemaVersion: Int
    let entryCount: Int
    let blobBytes: Int
    let legacyManifestXattrCountBefore: Int
    let legacyManifestXattrCountAfter: Int
    let migrationNanoseconds: UInt64
    let garbageCollectNanoseconds: UInt64
    let emptyDebtGarbageCollectNanoseconds: UInt64
    let removedBlobCount: Int
    let removedByteCount: Int
    let claims: Claims

    struct Claims: Codable {
        let formalPerformance: Bool
        let physicalDevice: Bool
        let physicalIOBytes: Bool
        let automaticMigrationQualified: Bool
    }
}

enum LegacyXattrMaintenanceProbe {
    private static let legacyManifestXattrPrefix = "dev.akashic.manifest-entry-v1.g"

    static func run(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw LegacyXattrMaintenanceProbeError.invalidArguments
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
            throw LegacyXattrMaintenanceProbeError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let logicalBytes = entryCount.multipliedReportingOverflow(by: blobBytes)
        guard !logicalBytes.overflow else {
            throw LegacyXattrMaintenanceProbeError.invalidArguments
        }
        let softLimit = logicalBytes.partialValue.multipliedReportingOverflow(by: 2)
        guard !softLimit.overflow else {
            throw LegacyXattrMaintenanceProbeError.invalidArguments
        }
        let limits = FileBlobStoreLimits(
            softTotalBytes: max(blobBytes, softLimit.partialValue),
            maximumBlobBytes: blobBytes
        )
        let partition = try CachePartitionID.derive(
            domain: "akashic-resource-legacy-xattr-maintenance-v1",
            material: Data("domain-neutral".utf8)
        )
        let store = try await FileBlobStore.open(root: root, limits: limits)
        var references = Set<LiveBlobReference>()
        references.reserveCapacity(entryCount)

        for entryIndex in 0 ..< entryCount {
            let data = payload(index: entryIndex, byteCount: blobBytes)
            let digest = BlobDigest.sha256(of: data)
            _ = try await store.commit(data: data, digest: digest, partition: partition)
            references.insert(LiveBlobReference(partition: partition, digest: digest))
        }

        let legacyBefore = try countLegacyManifestXattrs(root: root)
        let migrationStart = DispatchTime.now().uptimeNanoseconds
        guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
            throw LegacyXattrMaintenanceProbeError.migrationUnavailable
        }
        let migrationNanoseconds = DispatchTime.now().uptimeNanoseconds &- migrationStart

        let maintenanceLimits = try BlobMaintenanceLimits(
            maximumReferenceCount: entryCount,
            maximumReferencedBytes: logicalBytes.partialValue
        )
        let gcStart = DispatchTime.now().uptimeNanoseconds
        let result = try await store.garbageCollect(
            retaining: references,
            limits: maintenanceLimits
        )
        let garbageCollectNanoseconds = DispatchTime.now().uptimeNanoseconds &- gcStart
        guard result.removedBlobCount == 0, result.removedByteCount == 0 else {
            throw LegacyXattrMaintenanceProbeError.unexpectedCleanupResult
        }
        let legacyAfter = try countLegacyManifestXattrs(root: root)
        guard legacyAfter == 0 else {
            throw LegacyXattrMaintenanceProbeError.cleanupIncomplete
        }
        let emptyDebtGCStart = DispatchTime.now().uptimeNanoseconds
        let emptyDebtResult = try await store.garbageCollect(
            retaining: references,
            limits: maintenanceLimits
        )
        let emptyDebtGarbageCollectNanoseconds =
            DispatchTime.now().uptimeNanoseconds &- emptyDebtGCStart
        guard emptyDebtResult.removedBlobCount == 0, emptyDebtResult.removedByteCount == 0 else {
            throw LegacyXattrMaintenanceProbeError.unexpectedCleanupResult
        }

        let report = LegacyXattrMaintenanceReport(
            schemaVersion: 1,
            entryCount: entryCount,
            blobBytes: blobBytes,
            legacyManifestXattrCountBefore: legacyBefore,
            legacyManifestXattrCountAfter: legacyAfter,
            migrationNanoseconds: migrationNanoseconds,
            garbageCollectNanoseconds: garbageCollectNanoseconds,
            emptyDebtGarbageCollectNanoseconds: emptyDebtGarbageCollectNanoseconds,
            removedBlobCount: result.removedBlobCount,
            removedByteCount: result.removedByteCount,
            claims: .init(
                formalPerformance: false,
                physicalDevice: false,
                physicalIOBytes: false,
                automaticMigrationQualified: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func countLegacyManifestXattrs(root: URL) throws -> Int {
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var count = 0
        for url in children {
            let name = url.lastPathComponent
            guard let uuid = UUID(uuidString: name),
                uuid.uuidString.lowercased() == name
            else { continue }
            count += try XattrShadowProbeIO.listAttributes(url).filter {
                $0.hasPrefix(legacyManifestXattrPrefix)
            }.count
        }
        return count
    }

    private static func payload(index: Int, byteCount: Int) -> Data {
        var result = Data(repeating: 0xC7, count: byteCount)
        var value = UInt64(index).littleEndian
        withUnsafeBytes(of: &value) { bytes in
            result.replaceSubrange(0 ..< 8, with: bytes)
        }
        return result
    }
}
