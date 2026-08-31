import AkashicCore
import Darwin
import Foundation

/// 将 blob 最近访问时间持久化为低频、分桶的 mtime 更新。
enum BlobAccessJournal {
    private static let persistentUpdateInterval: TimeInterval = 5 * 60

    /// 返回本次运行时访问时间。持久更新时间失败只降低跨进程淘汰精度，
    /// 不会让已经验证的缓存读取失败。
    static func recordAccess(
        at blobURL: URL,
        persistedModificationDate: Date? = nil
    ) -> Date {
        let now = Date()
        if let persistedModificationDate,
            now.timeIntervalSince(persistedModificationDate) < persistentUpdateInterval
        {
            return now
        }
        let descriptor = Darwin.open(blobURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return now }
        defer { _ = Darwin.close(descriptor) }
        guard (try? StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)) != nil
        else { return now }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return now }
        let persisted = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        guard now.timeIntervalSince(persisted) >= persistentUpdateInterval else { return now }

        let interval = now.timeIntervalSince1970
        let seconds = floor(interval)
        let timestamps = [
            status.st_atimespec,
            timespec(
                tv_sec: Int(seconds),
                tv_nsec: Int((interval - seconds) * 1_000_000_000)
            ),
        ]
        _ = timestamps.withUnsafeBufferPointer { buffer in
            Darwin.futimens(descriptor, buffer.baseAddress)
        }
        return now
    }
}
