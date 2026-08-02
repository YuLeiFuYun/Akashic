import Darwin
import Foundation

/// 建立并复核缓存目录与文件的最小权限、不跟随链接和所有权边界。
/// 路径安全不是一次性创建动作；每次发布或重新打开都必须重新验证。
package enum StorageDirectorySecurity {
    package static func prepareDirectory(_ url: URL) throws {
        try createPrivateDirectoryHierarchyIfNeeded(url)
        try validateDirectory(url)
        try excludeFromBackup(url)
        try FileManager.default.setAttributes(
            directoryAttributes,
            ofItemAtPath: url.path
        )
        try validateDirectory(url)
    }

    package static func securePublishedFile(_ url: URL) throws {
        try validateRegularFileIdentity(url)
        try excludeFromBackup(url)
        try FileManager.default.setAttributes(
            fileAttributes,
            ofItemAtPath: url.path
        )
        try validateRegularFile(url)
    }

    /// 安全化由调用方刚以 `O_EXCL | O_NOFOLLOW` 创建并持有的私有普通文件。
    ///
    /// 备份排除由已验证的父目录承担；rename 保留同一 inode。macOS 上创建模式已经
    /// 给出完整保护，iOS 只需在首次 fsync 前补充 Data Protection 属性。
    package static func secureNewPrivateFile(_ url: URL, descriptor: Int32) throws {
        try validateOpenedPrivateRegularFile(descriptor)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
        try validateOpenedPrivateRegularFile(descriptor)
    }

    package static func validateDirectory(_ url: URL) throws {
        let status = try fileStatusWithoutFollowingLinks(at: url)
        let fileType = status.st_mode & S_IFMT
        guard fileType == S_IFDIR,
            status.st_uid == Darwin.geteuid(),
            status.st_mode & 0o077 == 0
        else {
            throw AkashicError.storageUnavailable
        }
    }

    private static func createPrivateDirectoryHierarchyIfNeeded(_ url: URL) throws {
        var missing: [URL] = []
        var cursor = url.standardizedFileURL

        while true {
            var status = stat()
            let result = cursor.path.withCString { Darwin.lstat($0, &status) }
            if result == 0 {
                break
            }
            guard errno == ENOENT else { throw posixError() }
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { throw AkashicError.storageUnavailable }
            cursor = parent
        }

        for directory in missing.reversed() {
            let result = directory.path.withCString { Darwin.mkdir($0, S_IRWXU) }
            if result != 0, errno != EEXIST { throw posixError() }
            // 只有重新验证并发发布的 inode 后，才能接受 EEXIST。
            try validateDirectory(directory)
        }
    }

    private static func validateRegularFileIdentity(_ url: URL) throws {
        let status = try fileStatusWithoutFollowingLinks(at: url)
        let fileType = status.st_mode & S_IFMT
        guard fileType == S_IFREG,
            status.st_nlink == 1,
            status.st_uid == Darwin.geteuid()
        else {
            throw AkashicError.storageUnavailable
        }
    }

    package static func validateRegularFile(_ url: URL) throws {
        let status = try fileStatusWithoutFollowingLinks(at: url)
        let fileType = status.st_mode & S_IFMT
        guard fileType == S_IFREG,
            status.st_nlink == 1,
            status.st_uid == Darwin.geteuid(),
            status.st_mode & 0o077 == 0
        else {
            throw AkashicError.storageUnavailable
        }
    }

    package static func validateOpenedPrivateRegularFile(_ descriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        let fileType = status.st_mode & S_IFMT
        guard fileType == S_IFREG,
            status.st_nlink == 1,
            status.st_uid == Darwin.geteuid(),
            status.st_mode & 0o077 == 0
        else {
            throw AkashicError.storageUnavailable
        }
    }

    package static func validateOpenedDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        let fileType = status.st_mode & S_IFMT
        guard fileType == S_IFDIR,
            status.st_uid == Darwin.geteuid(),
            status.st_mode & 0o077 == 0
        else {
            throw AkashicError.storageUnavailable
        }
    }

    private static func fileStatusWithoutFollowingLinks(at url: URL) throws -> stat {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0 else { throw posixError() }
        return status
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static var directoryAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o700))
        ]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return attributes
    }

    private static var fileAttributes: [FileAttributeKey: Any] {
        var attributes: [FileAttributeKey: Any] = [
            .posixPermissions: NSNumber(value: Int16(0o600))
        ]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        return attributes
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
