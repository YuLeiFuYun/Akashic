import AkashicCore
import Darwin
import Foundation

/// 在一个 store generation 的整个可变生命周期内持有单 writer 权限。
///
/// `lockf` 负责跨进程排他；进程内根目录集合补足 POSIX record lock 对同一进程
/// 多描述符不提供实例级排他的缺口。lease 析构时同时释放两层所有权。
final class StoreWriterLease: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var activeRoots: Set<String> = []

    private let descriptor: Int32
    private let rootKey: String

    private init(descriptor: Int32, rootKey: String) {
        self.descriptor = descriptor
        self.rootKey = rootKey
    }

    static func acquire(root: URL) throws -> StoreWriterLease {
        let rootKey = root.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock()
        guard activeRoots.insert(rootKey).inserted else {
            registryLock.unlock()
            throw AkashicError.transactionConflict
        }
        registryLock.unlock()

        let lockURL = root.appendingPathComponent(".akashic-writer.lock", isDirectory: false)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            releaseRoot(rootKey)
            throw posixError()
        }

        do {
            try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw posixError()
            }
            guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
                let code = errno
                if code == EACCES || code == EAGAIN {
                    throw AkashicError.transactionConflict
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return StoreWriterLease(descriptor: descriptor, rootKey: rootKey)
        } catch {
            _ = Darwin.close(descriptor)
            releaseRoot(rootKey)
            throw error
        }
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        _ = Darwin.close(descriptor)
        Self.releaseRoot(rootKey)
    }

    private static func releaseRoot(_ rootKey: String) {
        registryLock.lock()
        activeRoots.remove(rootKey)
        registryLock.unlock()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
