import AkashicCore
import AkashicDisk
import Darwin
import Foundation

final class MultiProcessRetirementBarrier {
    private var descriptor: Int32

    init(path: URL) throws {
        let fd = Darwin.open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { throw Self.posixError() }
        do {
            try StorageDirectorySecurity.validateOpenedPrivateRegularFile(fd)
        } catch {
            _ = Darwin.close(fd)
            throw error
        }
        descriptor = fd
    }

    deinit {
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    func lockShared() throws {
        try lockShared(start: 0, length: 0)
    }

    func lockShared(start: Int64, length: Int64) throws {
        guard try setLock(
            type: Int16(F_RDLCK),
            command: F_SETLKW,
            start: start,
            length: length
        ) else {
            throw AkashicError.storageUnavailable
        }
    }

    func tryLockShared() throws -> Bool {
        try tryLockShared(start: 0, length: 0)
    }

    func tryLockShared(start: Int64, length: Int64) throws -> Bool {
        try setLock(
            type: Int16(F_RDLCK),
            command: F_SETLK,
            start: start,
            length: length
        )
    }

    func tryLockExclusive() throws -> Bool {
        try tryLockExclusive(start: 0, length: 0)
    }

    func tryLockExclusive(start: Int64, length: Int64) throws -> Bool {
        try setLock(
            type: Int16(F_WRLCK),
            command: F_SETLK,
            start: start,
            length: length
        )
    }

    func lockExclusive() throws {
        try lockExclusive(start: 0, length: 0)
    }

    func lockExclusive(start: Int64, length: Int64) throws {
        guard try setLock(
            type: Int16(F_WRLCK),
            command: F_SETLKW,
            start: start,
            length: length
        ) else {
            throw AkashicError.storageUnavailable
        }
    }

    func unlock() throws {
        try unlock(start: 0, length: 0)
    }

    func unlock(start: Int64, length: Int64) throws {
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
            if Darwin.fcntl(descriptor, command, &record) == 0 { return true }
            if errno == EINTR { continue }
            if command == F_SETLK, errno == EACCES || errno == EAGAIN { return false }
            throw Self.posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct RetirementBarrierReaderReady: Codable {
    let schemaVersion: Int
    let pid: Int32
    let label: String
    let physicalID: String
    let byteCount: Int
    let profile: String
    let baseKind: String
    let sharedBarrierHeld: Bool
    let payloadPathExists: Bool
}

struct RetirementBarrierFDOpened: Codable {
    let schemaVersion: Int
    let label: String
    let physicalID: String
    let descriptorValidated: Bool
    let sharedBarrierReleased: Bool
    let payloadPathExistsAtOpen: Bool
}

struct RetirementBarrierReaderResult: Codable {
    let schemaVersion: Int
    let label: String
    let physicalID: String
    let payloadPathExistsAfterWriter: Bool
    let bytesRead: Int
    let payloadExact: Bool
    let digestExact: Bool
}

struct RetirementBarrierWriterResult: Codable {
    let schemaVersion: Int
    let label: String
    let initialExclusiveWouldBlock: Bool
    let exclusiveEventuallyAcquired: Bool
    let physicalBefore: String
    let physicalAfter: String?
    let logicalMissAfterRemove: Bool
    let payloadPathExistsAfterRemove: Bool
    let profile: String
    let baseKind: String
}

struct RetirementBarrierCheckResult: Codable {
    let schemaVersion: Int
    let lockKind: String
    let immediatelyAvailable: Bool
}

enum RetirementTurnstileRange {
    static let gate: Int64 = 0
    static let retirement: Int64 = 1
    static let length: Int64 = 1
}

struct RetirementTurnstileReaderReady: Codable {
    let schemaVersion: Int
    let pid: Int32
    let label: String
    let physicalID: String
    let byteCount: Int
    let gateReleased: Bool
    let retirementSharedHeld: Bool
    let profile: String
    let baseKind: String
}

struct RetirementTurnstileWriterResult: Codable {
    let schemaVersion: Int
    let label: String
    let gateInitiallyAvailable: Bool
    let retirementInitiallyWouldBlock: Bool
    let retirementEventuallyAcquired: Bool
    let physicalBefore: String
    let physicalAfter: String?
    let logicalMissAfterRemove: Bool
    let payloadPathExistsAfterRemove: Bool
    let profile: String
    let baseKind: String
}

struct RetirementTurnstileCheckResult: Codable {
    let schemaVersion: Int
    let range: String
    let lockKind: String
    let immediatelyAvailable: Bool
}

struct RetirementLocalRefcountState: Codable {
    let schemaVersion: Int
    let phase: String
    let readerCount: Int
}

struct RetirementLocalAdmissionState: Codable {
    let schemaVersion: Int
    let phase: String
    let acquired: Bool
    let readerCount: Int
}

struct RetirementLocalWriterState: Codable {
    let schemaVersion: Int
    let phase: String
    let acquired: Bool
    let readerCount: Int
    let readerAdmissionWhileWriterActive: Bool?
}

enum RetirementLocalWriterPhase {
    case idle
    case pending
    case active
}

final class RetirementLocalReaderCoordinator {
    private let barrier: MultiProcessRetirementBarrier
    private let mutex = NSLock()
    private var readerCount = 0
    private var writerPhase: RetirementLocalWriterPhase = .idle

    init(path: URL) throws {
        barrier = try MultiProcessRetirementBarrier(path: path)
    }

    func acquireReader() throws -> Int {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .idle else { throw AkashicError.storageUnavailable }
        try barrier.lockShared(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        var gateHeld = true
        var firstReaderLockAcquired = false
        var readerIncremented = false
        do {
            if readerCount == 0 {
                try barrier.lockShared(
                    start: RetirementTurnstileRange.retirement,
                    length: RetirementTurnstileRange.length
                )
                firstReaderLockAcquired = true
            }
            readerCount += 1
            readerIncremented = true
            try barrier.unlock(
                start: RetirementTurnstileRange.gate,
                length: RetirementTurnstileRange.length
            )
            gateHeld = false
            return readerCount
        } catch {
            if readerIncremented { readerCount -= 1 }
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

    func tryAcquireReader() throws -> (acquired: Bool, readerCount: Int) {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .idle else { return (false, readerCount) }
        guard try barrier.tryLockShared(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        ) else { return (false, readerCount) }

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
            if readerIncremented { readerCount -= 1 }
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

    func beginWriterIntent() throws -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .idle else { return false }
        try barrier.lockExclusive(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        writerPhase = .pending
        return true
    }

    func tryFinishWriterAcquire() throws -> (acquired: Bool, readerCount: Int) {
        mutex.lock()
        defer { mutex.unlock() }
        switch writerPhase {
        case .idle:
            return (false, readerCount)
        case .active:
            return (true, readerCount)
        case .pending:
            guard readerCount == 0 else { return (false, readerCount) }
            guard try barrier.tryLockExclusive(
                start: RetirementTurnstileRange.retirement,
                length: RetirementTurnstileRange.length
            ) else { return (false, readerCount) }
            writerPhase = .active
            return (true, readerCount)
        }
    }

    func releaseWriter() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard writerPhase == .active else { throw AkashicError.storageUnavailable }
        try barrier.unlock(
            start: RetirementTurnstileRange.retirement,
            length: RetirementTurnstileRange.length
        )
        try barrier.unlock(
            start: RetirementTurnstileRange.gate,
            length: RetirementTurnstileRange.length
        )
        writerPhase = .idle
    }

    func releaseReader() throws -> Int {
        mutex.lock()
        defer { mutex.unlock() }
        guard readerCount > 0 else { throw AkashicError.storageUnavailable }
        if readerCount == 1 {
            try barrier.unlock(
                start: RetirementTurnstileRange.retirement,
                length: RetirementTurnstileRange.length
            )
        }
        readerCount -= 1
        return readerCount
    }
}
