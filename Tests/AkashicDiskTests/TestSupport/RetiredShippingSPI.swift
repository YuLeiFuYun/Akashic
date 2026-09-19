import AkashicCore
import CryptoKit
import Foundation
@testable import AkashicDisk

extension SegmentedManifestPrototypeV1 {
    package static func writeBaseJSON(
        _ data: Data,
        entryCount: Int,
        fileName: String,
        directory: URL
    ) throws -> SegmentedManifestDescriptorV1 {
        guard isCanonicalSegmentFileName(fileName, kind: .baseJSON),
            entryCount >= 0,
            entryCount <= 100_000,
            data.count > 0,
            data.count <= maximumBaseBytes,
            data.count <= maximumReferencedSegmentBytes
        else { throw AkashicError.invalidManifest }
        try StorageDirectorySecurity.validateDirectory(directory)
        let url = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AkashicError.storageUnavailable
        }
        try DurableFileWriter.writeReplacing(data, to: url)
        try StorageDirectorySecurity.validateRegularFile(url)
        return SegmentedManifestDescriptorV1(
            kind: .baseJSON,
            fileName: fileName,
            byteCount: data.count,
            recordCount: entryCount,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}
