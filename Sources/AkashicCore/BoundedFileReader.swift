import Darwin
import Foundation

/// 从受管普通文件读取有界数据，先验证 inode 与长度，再执行分配。
package enum BoundedFileReader {
    package static func read(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int? = nil
    ) throws -> Data {
        let maximumBytes = max(0, maximumBytes)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }

        try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_size >= 0,
            UInt64(status.st_size) <= UInt64(maximumBytes),
            UInt64(status.st_size) <= UInt64(Int.max)
        else {
            throw AkashicError.storageUnavailable
        }
        let byteCount = Int(status.st_size)
        if let expectedBytes, expectedBytes != byteCount {
            throw AkashicError.integrityMismatch
        }

        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < byteCount {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw AkashicError.integrityMismatch }
                offset += result
            }
        }
        return data
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
