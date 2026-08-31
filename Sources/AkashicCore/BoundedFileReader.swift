import Darwin
import Foundation

/// 一次已验证有界读取的字节与同一已验证 inode 的持久 mtime。
package struct BoundedFileReadResult: Sendable {
    package let data: Data
    package let modificationDate: Date

    package init(data: Data, modificationDate: Date) {
        self.data = data
        self.modificationDate = modificationDate
    }
}

/// 从受管普通文件读取有界数据，先验证 inode 与长度，再执行分配。
package enum BoundedFileReader {
    package static func read(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int? = nil
    ) throws -> Data {
        try readWithMetadata(
            from: url,
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes
        ).data
    }

    package static func readWithMetadata(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int? = nil
    ) throws -> BoundedFileReadResult {
        try readValidated(
            from: url,
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes,
            allowPermissionDrift: false
        )
    }

    /// Bounded recovery/cleanup read for a same-owner, single-link regular file whose POSIX mode
    /// may have drifted. The caller must establish semantic ownership from the returned bytes before
    /// mutating the path; this method deliberately does not repair permissions or weaken type/link/
    /// owner checks.
    package static func readOwnedRegularFileAllowingPermissionDrift(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int? = nil
    ) throws -> Data {
        try readValidated(
            from: url,
            maximumBytes: maximumBytes,
            expectedBytes: expectedBytes,
            allowPermissionDrift: true
        ).data
    }

    private static func readValidated(
        from url: URL,
        maximumBytes: Int,
        expectedBytes: Int?,
        allowPermissionDrift: Bool
    ) throws -> BoundedFileReadResult {
        let maximumBytes = max(0, maximumBytes)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }

        let status: stat
        if allowPermissionDrift {
            status = try StorageDirectorySecurity.validatedOpenedOwnedRegularFileStatus(descriptor)
        } else {
            status = try StorageDirectorySecurity.validatedOpenedPrivateRegularFileStatus(descriptor)
        }
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
        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return BoundedFileReadResult(data: data, modificationDate: modificationDate)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
