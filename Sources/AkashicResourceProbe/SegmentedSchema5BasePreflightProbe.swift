import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5BasePreflightReport: Codable {
    struct Claims: Codable {
        let semanticSnapshot: Bool
        let productionFormat: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let maximumReferencedSegmentBytes: Int
    let maximumBaseBytes: Int
    let oversizedBytes: Int
    let oversizedRejectedBeforeMaterialization: Bool
    let boundaryBytes: Int
    let boundaryMaterialized: Bool
    let claims: Claims
}

extension SegmentedManifestShadowProbe {
    static func schema5BasePreflight(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let oversizedBytes = SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes + 1
        let oversizedURL = segments.appendingPathComponent("base-oversized.json")
        let oversizedData = Data(repeating: 0, count: oversizedBytes)
        let oversizedRejectedBeforeMaterialization: Bool
        do {
            _ = try SegmentedManifestPrototypeV1.writeBaseJSON(
                oversizedData,
                entryCount: 1,
                fileName: oversizedURL.lastPathComponent,
                directory: segments
            )
            oversizedRejectedBeforeMaterialization = false
        } catch {
            oversizedRejectedBeforeMaterialization =
                !FileManager.default.fileExists(atPath: oversizedURL.path)
        }

        let boundaryBytes = SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes
        let boundaryURL = segments.appendingPathComponent("base-boundary.json")
        let boundaryData = Data(repeating: 0, count: boundaryBytes)
        let boundary = try SegmentedManifestPrototypeV1.writeBaseJSON(
            boundaryData,
            entryCount: 1,
            fileName: boundaryURL.lastPathComponent,
            directory: segments
        )
        let boundaryMaterialized = boundary.byteCount == boundaryBytes
            && FileManager.default.fileExists(atPath: boundaryURL.path)
        try FileManager.default.removeItem(at: boundaryURL)

        guard oversizedRejectedBeforeMaterialization, boundaryMaterialized else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let report = Schema5BasePreflightReport(
            schemaVersion: 1,
            maximumReferencedSegmentBytes: SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes,
            maximumBaseBytes: SegmentedManifestPrototypeV1.maximumBaseBytes,
            oversizedBytes: oversizedBytes,
            oversizedRejectedBeforeMaterialization: oversizedRejectedBeforeMaterialization,
            boundaryBytes: boundaryBytes,
            boundaryMaterialized: boundaryMaterialized,
            claims: .init(
                semanticSnapshot: false,
                productionFormat: false,
                formalPerformance: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
