import AkashicDisk
import Darwin
import Foundation

extension AkashicResourceProbe {
    static func measureFootprint(root: URL) throws -> Footprint {
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
        var metadataAttributeBytes: Int64 = 0
        var metadataAttributeCount = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            if isBlobPayloadFile(url) {
                blobBytes = try checkedSum(blobBytes, size)
                blobFileCount += 1
                let attributes = try manifestMetadataAttributes(at: url)
                metadataAttributeCount += attributes.count
                for data in attributes.values {
                    metadataAttributeBytes = try checkedSum(
                        metadataAttributeBytes,
                        Int64(data.count)
                    )
                }
            } else {
                metadataBytes = try checkedSum(metadataBytes, size)
                metadataFileCount += 1
            }
        }
        let blobsDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        let directoryAttributes = try manifestMetadataAttributes(at: blobsDirectory)
        metadataAttributeCount += directoryAttributes.count
        for data in directoryAttributes.values {
            metadataAttributeBytes = try checkedSum(
                metadataAttributeBytes,
                Int64(data.count)
            )
        }
        return try Footprint(
            blobBytes: blobBytes,
            blobFileCount: blobFileCount,
            fileCount: blobFileCount + metadataFileCount,
            metadataBytes: metadataBytes,
            metadataFileCount: metadataFileCount,
            metadataAttributeBytes: metadataAttributeBytes,
            metadataAttributeCount: metadataAttributeCount,
            totalBytes: checkedSum(blobBytes, metadataBytes)
        )
    }

    static func metadataSnapshot(root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else { throw ProbeError.resourceSampleFailed }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if isBlobPayloadFile(url) {
                for (name, data) in try manifestMetadataAttributes(at: url) {
                    result["\(url.path)\u{0}xattr:\(name)"] = data
                }
                continue
            }
            result[url.path] = try Data(contentsOf: url)
        }
        let blobsDirectory = root.appendingPathComponent("blobs", isDirectory: true)
        for (name, data) in try manifestMetadataAttributes(at: blobsDirectory) {
            result["\(blobsDirectory.path)\u{0}xattr:\(name)"] = data
        }
        return result
    }

    private static let manifestMetadataAttributePrefixes = [
        "dev.akashic.manifest-entry-",
        "dev.akashic.md1.",
        "dev.akashic.mh1.",
    ]

    private static func manifestMetadataAttributes(at url: URL) throws -> [String: Data] {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProbeError.resourceSampleFailed }
        defer { _ = Darwin.close(descriptor) }

        let requiredNames = Darwin.flistxattr(descriptor, nil, 0, 0)
        guard requiredNames >= 0 else { throw ProbeError.resourceSampleFailed }
        guard requiredNames > 0 else { return [:] }
        // The observer must cover every xattr name-list size that production recovery itself
        // accepts; a narrower probe-only ceiling creates false resource/liveness failures.
        guard requiredNames <= FileBlobStore.maximumDirectoryHeadXattrListBytes else {
            throw ProbeError.resourceSampleFailed
        }
        var namesBuffer = [CChar](repeating: 0, count: requiredNames)
        let actualNames = namesBuffer.withUnsafeMutableBufferPointer { pointer in
            Darwin.flistxattr(descriptor, pointer.baseAddress, pointer.count, 0)
        }
        guard actualNames == requiredNames else { throw ProbeError.resourceSampleFailed }

        var result: [String: Data] = [:]
        var start = 0
        for index in 0..<actualNames where namesBuffer[index] == 0 {
            defer { start = index + 1 }
            guard index > start else { continue }
            let nameBytes = namesBuffer[start..<index].map { UInt8(bitPattern: $0) }
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard manifestMetadataAttributePrefixes.contains(where: name.hasPrefix) else {
                continue
            }
            let requiredValue = name.withCString { pointer in
                Darwin.fgetxattr(descriptor, pointer, nil, 0, 0, 0)
            }
            guard requiredValue >= 0, requiredValue <= 16 * 1_024 else {
                throw ProbeError.resourceSampleFailed
            }
            var data = Data(count: requiredValue)
            let actualValue = data.withUnsafeMutableBytes { bytes in
                name.withCString { pointer in
                    Darwin.fgetxattr(
                        descriptor,
                        pointer,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        0
                    )
                }
            }
            guard actualValue == requiredValue else { throw ProbeError.resourceSampleFailed }
            result[name] = data
        }
        return result
    }

    private static func isBlobPayloadFile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "blobs"
            && UUID(uuidString: url.lastPathComponent) != nil
    }

}
