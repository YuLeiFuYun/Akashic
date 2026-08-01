import AkashicCore
import Darwin
import Foundation

/// 从已验证的受管 inode 读取文件元数据，不跟随符号链接或接受硬链接。
package enum ManagedFileMetadata {
    package static func modificationDate(at url: URL) -> Date? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        guard (try? StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)) != nil
        else {
            return nil
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }
}
