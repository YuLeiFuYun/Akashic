import AkashicCore
import Darwin
import Foundation

/// 跨进程 reader retirement 协议使用的两个独立 record-lock 区间。
///
/// `gate` 负责阻止 writer intent 之后的新 reader 入场；`retirement` 负责等待已经
/// 入场的 reader 把 payload 打开成稳定文件描述符，再允许物理回收继续。
package enum RetirementTurnstileRange {
    package static let gate: Int64 = 0
    package static let retirement: Int64 = 1
    package static let length: Int64 = 1
}

/// 仅提供 record-lock 原语的 package-internal authority。
///
/// POSIX `fcntl` record locks 按进程而不是按文件描述符归属，因此同一进程如果针对
/// 同一 lock file 打开多个描述符，关闭任意一个描述符都可能破坏该进程持有的锁。
/// 需要进程内共享语义的调用方必须通过 `RetirementLocalReaderCoordinator.shared(path:)`
/// 获取唯一 coordinator；该低层 barrier 只用于一个进程一个 descriptor 的跨进程探针。
package final class MultiProcessRetirementBarrier: @unchecked Sendable {
    private var descriptor: Int32

    package init(path: URL) throws {
        let descriptor = Darwin.open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw Self.posixError() }
        do {
            try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw Self.posixError()
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    package func lockShared() throws {
        try lockShared(start: 0, length: 0)
    }

    package func lockShared(start: Int64, length: Int64) throws {
        guard try setLock(
            type: Int16(F_RDLCK),
            command: F_SETLKW,
            start: start,
            length: length
        ) else {
            throw AkashicError.storageUnavailable
        }
    }

    package func tryLockShared() throws -> Bool {
        try tryLockShared(start: 0, length: 0)
    }

    package func tryLockShared(start: Int64, length: Int64) throws -> Bool {
        try setLock(
            type: Int16(F_RDLCK),
            command: F_SETLK,
            start: start,
            length: length
        )
    }

    package func lockExclusive() throws {
        try lockExclusive(start: 0, length: 0)
    }

    package func lockExclusive(start: Int64, length: Int64) throws {
        guard try setLock(
            type: Int16(F_WRLCK),
            command: F_SETLKW,
            start: start,
            length: length
        ) else {
            throw AkashicError.storageUnavailable
        }
    }

    package func tryLockExclusive() throws -> Bool {
        try tryLockExclusive(start: 0, length: 0)
    }

    package func tryLockExclusive(start: Int64, length: Int64) throws -> Bool {
        try setLock(
            type: Int16(F_WRLCK),
            command: F_SETLK,
            start: start,
            length: length
        )
    }

    package func unlock() throws {
        try unlock(start: 0, length: 0)
    }

    package func unlock(start: Int64, length: Int64) throws {
        guard try setLock(
            type: Int16(F_UNLCK),
            command: F_SETLK,
            start: start,
            length: length
        ) else {
            throw AkashicError.storageUnavailable
        }
    }

    private func setLock(
        type: Int16,
        command: Int32,
        start: Int64,
        length: Int64
    ) throws -> Bool {
        while true {
            var record = flock()
            record.l_start = start
            record.l_len = length
            record.l_pid = 0
            record.l_type = type
            record.l_whence = Int16(SEEK_SET)
            if Darwin.fcntl(descriptor, command, &record) == 0 {
                return true
            }
            if errno == EINTR {
                continue
            }
            if command == F_SETLK, errno == EACCES || errno == EAGAIN {
                return false
            }
            throw Self.posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

private enum RetirementLocalWriterPhase {
    case idle
    case waitingForGate
    case pending
    case active
}

/// 补足 POSIX record-lock 的进程内语义：同一 canonical lock path 在一个进程内只打开
/// 一个 barrier descriptor，并用 reader refcount 表示本进程全部已入场 reader。
package final class RetirementLocalReaderCoordinator: @unchecked Sendable {
    private static let registryLock = NSLock()
    // fcntl record locks are process-scoped. Keep one descriptor authority alive for the
    // process lifetime for every canonical lock path so a later factory call cannot open
    // and then close a second descriptor that would disturb locks held by this process.
    nonisolated(unsafe) private static var registry: [String: RetirementLocalReaderCoordinator] = [:]

    private let barrier: MultiProcessRetirementBarrier
    private let mutex = NSLock()
    private var readerCount = 0
    private var writerPhase: RetirementLocalWriterPhase = .idle

    private init(path: URL) throws {
        barrier = try MultiProcessRetirementBarrier(path: path)
    }

    /// 返回当前进程内该 canonical lock path 的唯一 coordinator。
    package static func shared(path: URL) throws -> RetirementLocalReaderCoordinator {
        let canonicalPath = canonicalLockPath(path)
        registryLock.lock()
        defer { registryLock.unlock() }

        if let existing = registry[canonicalPath] {
            return existing
        }
        let coordinator = try RetirementLocalReaderCoordinator(
            path: URL(fileURLWithPath: canonicalPath, isDirectory: false)
        )
        registry[canonicalPath] = coordinator
        return coordinator
    }

    package func acquireReader() throws -> Int {
        while true {
            mutex.lock()
            let writerIsIdle = writerPhase == .idle
            mutex.unlock()
            guard writerIsIdle else {
                throw AkashicError.storageUnavailable
            }

            let attempt = try tryAcquireReader()
            if attempt.acquired {
                return attempt.readerCount
            }
            // Never block in fcntl while holding the process-local mutex. An external writer
            // can own gate while waiting for one of our admitted readers to call releaseReader().
            _ = Darwin.usleep(1_000)
        }
    }

    package func tryAcquireReader() throws -> (acquired: Bool, readerCount: Int) {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .idle else {
            return (false, readerCount)
        }
        guard try barrier.tryLockShared(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        ) else {
            return (false, readerCount)
        }

        var gateHeld = true
        var firstReaderLockAcquired = false
        var readerIncremented = false
        do {
            if readerCount == 0 {
                guard try barrier.tryLockShared(
                    start: RetirementTurnstileRange.retirement,
                    length: RetirementTurnstileRange.length
                ) else {
                    try barrier.unlock(
                        start: RetirementTurnstileRange.gate,
                        length: RetirementTurnstileRange.length
                    )
                    gateHeld = false
                    return (false, readerCount)
                }
                firstReaderLockAcquired = true
            }
            readerCount += 1
            readerIncremented = true
            try barrier.unlock(
                start: RetirementTurnstileRange.gate,
                length: RetirementTurnstileRange.length
            )
            gateHeld = false
            return (true, readerCount)
        } catch {
            if readerIncremented {
                readerCount -= 1
            }
            if firstReaderLockAcquired {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.retirement,
                    length: RetirementTurnstileRange.length
                )
            }
            if gateHeld {
                try? barrier.unlock(
                    start: RetirementTurnstileRange.gate,
                    length: RetirementTurnstileRange.length
                )
            }
            throw error
        }
    }

    package func beginWriterIntent() throws -> Bool {
        mutex.lock()
        guard writerPhase == .idle else {
            mutex.unlock()
            return false
        }
        writerPhase = .waitingForGate
        mutex.unlock()

        do {
            while true {
                if try tryAcquireWriterGate() {
                    return true
                }
                // External owners are invisible to NSLock. Poll the nonblocking record-lock
                // primitive so admitted local readers can always enter releaseReader().
                _ = Darwin.usleep(1_000)
            }
        } catch {
            mutex.lock()
            if writerPhase == .waitingForGate {
                writerPhase = .idle
            }
            mutex.unlock()
            throw error
        }
    }

    private func tryAcquireWriterGate() throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .waitingForGate else {
            throw AkashicError.storageUnavailable
        }
        guard try barrier.tryLockExclusive(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        ) else {
            return false
        }
        writerPhase = .pending
        return true
    }

    package func tryFinishWriterAcquire() throws -> (acquired: Bool, readerCount: Int) {
        mutex.lock()
        defer { mutex.unlock() }
        switch writerPhase {
        case .idle, .waitingForGate:
            return (false, readerCount)
        case .active:
            return (true, readerCount)
        case .pending:
            guard readerCount == 0 else {
                return (false, readerCount)
            }
            guard try barrier.tryLockExclusive(
                start: RetirementTurnstileRange.retirement,
                length: RetirementTurnstileRange.length
            ) else {
                return (false, readerCount)
            }
            writerPhase = .active
            return (true, readerCount)
        }
    }

    package func releaseWriter() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .active else {
            throw AkashicError.storageUnavailable
        }
        try barrier.unlock(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        do {
            try barrier.unlock(
                start: RetirementTurnstileRange.gate,
                length: RetirementTurnstileRange.length
            )
            writerPhase = .idle
        } catch {
            // retirement 已释放但 gate 仍由当前进程持有；保持 active 使调用方 fail closed，
            // 避免在状态不确定时重新接纳 reader。
            throw error
        }
    }

    package func releaseReader() throws -> Int {
        mutex.lock()
        defer { mutex.unlock() }
        guard readerCount > 0 else {
            throw AkashicError.storageUnavailable
        }
        if readerCount == 1 {
            try barrier.unlock(
                start: RetirementTurnstileRange.retirement,
                length: RetirementTurnstileRange.length
            )
        }
        readerCount -= 1
        return readerCount
    }

    private static func canonicalLockPath(_ path: URL) -> String {
        let parent = path.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return parent.appendingPathComponent(path.lastPathComponent, isDirectory: false).path
    }
}
