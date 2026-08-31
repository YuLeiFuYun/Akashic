import AkashicCore
import Darwin
import Foundation

enum XattrShadowProbeIO {
    static func posixError() -> XattrShadowError {
        .posix(errno)
    }

    static func writeBlobAndPublish(
        root: URL,
        data: Data,
        physicalID: PhysicalBlobID,
        attributes: [(String, Data)]
    ) throws -> URL {
        let temporary = root.appendingPathComponent(
            ".xattr-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let destination = root.appendingPathComponent(
            physicalID.rawValue.uuidString.lowercased(),
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        var isOpen = true
        do {
            try writeAll(data, descriptor: descriptor)
            for (name, value) in attributes {
                let result = name.withCString { namePointer in
                    value.withUnsafeBytes { bytes in
                        Darwin.fsetxattr(
                            descriptor,
                            namePointer,
                            bytes.baseAddress,
                            bytes.count,
                            0,
                            0
                        )
                    }
                }
                guard result == 0 else { throw posixError() }
            }
            try synchronize(descriptor)
            guard Darwin.close(descriptor) == 0 else { throw posixError() }
            isOpen = false
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw posixError()
            }
            try synchronizeDirectory(root)
            return destination
        } catch {
            if isOpen { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func listAttributes(_ url: URL) throws -> [String] {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        let required = Darwin.flistxattr(descriptor, nil, 0, 0)
        guard required >= 0 else { throw posixError() }
        guard required > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: required)
        let actual = buffer.withUnsafeMutableBufferPointer { pointer in
            Darwin.flistxattr(descriptor, pointer.baseAddress, pointer.count, 0)
        }
        guard actual == required else { throw posixError() }
        var names: [String] = []
        var start = 0
        for index in 0..<buffer.count where buffer[index] == 0 {
            guard index > start else {
                start = index + 1
                continue
            }
            let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
            names.append(String(decoding: bytes, as: UTF8.self))
            start = index + 1
        }
        return names
    }

    static func readAttribute(_ name: String, from url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        let required = name.withCString { pointer in
            Darwin.fgetxattr(descriptor, pointer, nil, 0, 0, 0)
        }
        guard required >= 0 else { throw posixError() }
        var data = Data(count: required)
        let actual = try data.withUnsafeMutableBytes { bytes -> Int in
            let result = name.withCString { pointer in
                Darwin.fgetxattr(
                    descriptor,
                    pointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
            guard result >= 0 else { throw posixError() }
            return result
        }
        guard actual == required else { throw XattrShadowError.invalidRecord }
        return data
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw XattrShadowError.posix(EIO) }
                offset += result
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while true {
            if Darwin.fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor)
    }
}
