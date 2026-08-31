import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    static func directoryHeadListAttributes(
        at directory: URL,
        maximumBytes: Int
    ) throws -> [String] {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw directoryHeadPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)

        for _ in 0..<3 {
            let required = Darwin.flistxattr(descriptor, nil, 0, 0)
            guard required >= 0 else { throw directoryHeadPOSIXError() }
            guard required <= maximumBytes else { throw AkashicError.invalidManifest }
            guard required > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: required)
            let actual = buffer.withUnsafeMutableBufferPointer { pointer in
                Darwin.flistxattr(descriptor, pointer.baseAddress, pointer.count, 0)
            }
            if actual < 0, errno == ERANGE { continue }
            guard actual >= 0,
                actual <= maximumBytes,
                actual <= buffer.count
            else { throw directoryHeadPOSIXError() }
            var names: [String] = []
            var start = 0
            for index in 0..<actual where buffer[index] == 0 {
                guard index > start else {
                    start = index + 1
                    continue
                }
                let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
                names.append(String(decoding: bytes, as: UTF8.self))
                start = index + 1
            }
            guard start == actual else { throw AkashicError.invalidManifest }
            return names
        }
        throw AkashicError.storageUnavailable
    }

    static func directoryHeadReadAttribute(
        _ name: String,
        from url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw directoryHeadPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)

        for _ in 0..<3 {
            let required = name.withCString { pointer in
                Darwin.fgetxattr(descriptor, pointer, nil, 0, 0, 0)
            }
            guard required >= 0 else { throw directoryHeadPOSIXError() }
            guard required <= maximumBytes else { throw AkashicError.invalidManifest }
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
                if result < 0, errno == ERANGE { return -2 }
                guard result >= 0 else { throw directoryHeadPOSIXError() }
                return result
            }
            if actual == -2 { continue }
            guard actual == required else { throw AkashicError.invalidManifest }
            return data
        }
        throw AkashicError.storageUnavailable
    }

    static func directoryHeadSetAttribute(
        _ name: String,
        value: Data,
        at directory: URL,
        flags: Int32
    ) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw directoryHeadPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        let result = name.withCString { namePointer in
            value.withUnsafeBytes { bytes in
                Darwin.fsetxattr(
                    descriptor,
                    namePointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    flags
                )
            }
        }
        guard result == 0 else { throw directoryHeadPOSIXError() }
    }

    static func directoryHeadRemoveAttribute(_ name: String, at directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw directoryHeadPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        let result = name.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
        if result == 0 { return }
        if errno == ENOATTR { return }
        throw directoryHeadPOSIXError()
    }

    static func directoryHeadSynchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw directoryHeadPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        while true {
            if Darwin.fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw directoryHeadPOSIXError()
        }
    }

    private static func directoryHeadPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
