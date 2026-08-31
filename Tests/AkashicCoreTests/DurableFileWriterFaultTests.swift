import Darwin
import Foundation
import Testing

@testable import AkashicCore

@Suite("AkashicCore durable file syscall faults")
struct DurableFileWriterFaultTests {
    @Test("Partial write results are retried until the payload is complete")
    func partialWritesAreRetried() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let payload = Data((0..<8_193).map { UInt8($0 % 251) })
            var callCount = 0

            try DurableFileWriter.writeReplacing(
                payload,
                to: destination,
                faultInjector: { _ in },
                operations: systemOperations(
                    write: { descriptor, bytes, count in
                        callCount += 1
                        return Darwin.write(descriptor, bytes, min(count, 17))
                    }
                )
            )

            #expect(callCount > 1)
            #expect(try Data(contentsOf: destination) == payload)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("EINTR from write is retried")
    func interruptedWriteIsRetried() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let payload = Data(repeating: 0x71, count: 4_096)
            var interruptions = 0

            try DurableFileWriter.writeReplacing(
                payload,
                to: destination,
                faultInjector: { _ in },
                operations: systemOperations(
                    write: { descriptor, bytes, count in
                        if interruptions < 3 {
                            interruptions += 1
                            errno = EINTR
                            return -1
                        }
                        return Darwin.write(descriptor, bytes, count)
                    }
                )
            )

            #expect(interruptions == 3)
            #expect(try Data(contentsOf: destination) == payload)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("EINTR from file and directory fsync is retried")
    func interruptedSynchronizationIsRetried() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let payload = Data(repeating: 0x72, count: 4_096)
            var calls = 0

            try DurableFileWriter.writeReplacing(
                payload,
                to: destination,
                faultInjector: { _ in },
                operations: systemOperations(
                    synchronize: { descriptor in
                        calls += 1
                        if calls == 1 || calls == 3 {
                            errno = EINTR
                            return -1
                        }
                        return Darwin.fsync(descriptor)
                    }
                )
            )

            #expect(calls == 4)
            #expect(try Data(contentsOf: destination) == payload)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("Deferred directory sync performs only file fsync and never reports directory-synced")
    func deferredDirectorySynchronizationStopsAfterRename() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let payload = Data(repeating: 0x73, count: 4_096)
            var synchronizeCalls = 0
            let observed = DurableFileSwitchPointRecorder()

            try DurableFileWriter.writeReplacingDeferringDirectorySync(
                payload,
                to: destination,
                faultInjector: { observed.record($0) },
                operations: systemOperations(
                    synchronize: { descriptor in
                        synchronizeCalls += 1
                        return Darwin.fsync(descriptor)
                    }
                )
            )

            #expect(synchronizeCalls == 1)
            #expect(observed.snapshot() == [.afterDataWritten, .afterFileSynced, .afterRename])
            #expect(try Data(contentsOf: destination) == payload)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("Temporary-file open failure preserves the old destination")
    func temporaryOpenFailurePreservesOldDestination() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-before-open".utf8)
            let replacement = Data(repeating: 0x59, count: 4_096)
            try old.write(to: destination)
            var openCalls = 0

            awaitPOSIXError(.EACCES) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    operations: systemOperations(
                        open: { _, _, _ in
                            openCalls += 1
                            errno = EACCES
                            return -1
                        }
                    )
                )
            }

            #expect(openCalls == 1)
            #expect(try Data(contentsOf: destination) == old)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("ENOSPC after a partial write preserves the old destination")
    func noSpaceAfterPartialWritePreservesOldDestination() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-durable-state".utf8)
            let replacement = Data(repeating: 0x5a, count: 4_096)
            try old.write(to: destination)
            var writtenBytes = 0

            awaitPOSIXError(.ENOSPC) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    operations: systemOperations(
                        write: { descriptor, bytes, count in
                            let remainingBeforeFailure = 31 - writtenBytes
                            guard remainingBeforeFailure > 0 else {
                                errno = ENOSPC
                                return -1
                            }
                            let requested = min(count, remainingBeforeFailure)
                            let result = Darwin.write(descriptor, bytes, requested)
                            if result > 0 { writtenBytes += result }
                            return result
                        }
                    )
                )
            }

            #expect(writtenBytes == 31)
            #expect(try Data(contentsOf: destination) == old)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("File fsync failure preserves the old destination")
    func fileSynchronizationFailurePreservesOldDestination() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-before-file-fsync".utf8)
            let replacement = Data(repeating: 0x61, count: 4_096)
            try old.write(to: destination)

            awaitPOSIXError(.EIO) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    operations: systemOperations(
                        synchronize: { _ in
                            errno = EIO
                            return -1
                        }
                    )
                )
            }

            #expect(try Data(contentsOf: destination) == old)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("Close failure is not retried and preserves the old destination")
    func closeFailureIsNotRetried() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-before-close".utf8)
            let replacement = Data(repeating: 0x62, count: 4_096)
            try old.write(to: destination)
            var closeCalls = 0

            awaitPOSIXError(.EIO) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    operations: systemOperations(
                        close: { descriptor in
                            closeCalls += 1
                            let result = Darwin.close(descriptor)
                            if closeCalls == 1, result == 0 {
                                errno = EIO
                                return -1
                            }
                            return result
                        }
                    )
                )
            }

            #expect(closeCalls == 1)
            #expect(try Data(contentsOf: destination) == old)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("Rename ENOSPC preserves the old destination")
    func renameNoSpacePreservesOldDestination() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-before-rename".utf8)
            let replacement = Data(repeating: 0x63, count: 4_096)
            try old.write(to: destination)
            var renameObserved = false

            awaitPOSIXError(.ENOSPC) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    renameObserver: { renameObserved = true },
                    operations: systemOperations(
                        rename: { _, _ in
                            errno = ENOSPC
                            return -1
                        }
                    )
                )
            }

            #expect(!renameObserved)
            #expect(try Data(contentsOf: destination) == old)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("Directory open failure reports ambiguous durability after visible rename")
    func directoryOpenFailureReportsVisibleReplacement() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-before-directory-open".utf8)
            let replacement = Data(repeating: 0x65, count: 4_096)
            try old.write(to: destination)
            var openCalls = 0

            var renameObserved = false
            awaitPOSIXError(.EACCES) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    renameObserver: { renameObserved = true },
                    operations: systemOperations(
                        open: { path, flags, mode in
                            openCalls += 1
                            if path == root.path {
                                errno = EACCES
                                return -1
                            }
                            return path.withCString { Darwin.open($0, flags, mode) }
                        }
                    )
                )
            }

            #expect(openCalls == 2)
            #expect(renameObserved)
            #expect(try Data(contentsOf: destination) == replacement)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }

    @Test("Directory fsync failure reports ambiguous durability after visible rename")
    func directorySynchronizationFailureReportsVisibleReplacement() throws {
        try withTemporaryDirectory { root in
            let destination = root.appendingPathComponent("state.bin")
            let old = Data("old-before-directory-fsync".utf8)
            let replacement = Data(repeating: 0x64, count: 4_096)
            try old.write(to: destination)
            var synchronizeCalls = 0
            var renameObserved = false

            awaitPOSIXError(.EIO) {
                try DurableFileWriter.writeReplacing(
                    replacement,
                    to: destination,
                    faultInjector: { _ in },
                    renameObserver: { renameObserved = true },
                    operations: systemOperations(
                        synchronize: { descriptor in
                            synchronizeCalls += 1
                            if synchronizeCalls == 2 {
                                errno = EIO
                                return -1
                            }
                            return Darwin.fsync(descriptor)
                        }
                    )
                )
            }

            #expect(synchronizeCalls == 2)
            #expect(renameObserved)
            #expect(try Data(contentsOf: destination) == replacement)
            #expect(durableTemporaryFiles(in: root).isEmpty)
        }
    }
}

private final class DurableFileSwitchPointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DurableFileWriteSwitchPoint] = []

    func record(_ value: DurableFileWriteSwitchPoint) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [DurableFileWriteSwitchPoint] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func systemOperations(
    open: @escaping DurableFileOpenOperation = { path, flags, mode in
        path.withCString { Darwin.open($0, flags, mode) }
    },
    write: @escaping DurableFileWriteOperation = { descriptor, bytes, count in
        Darwin.write(descriptor, bytes, count)
    },
    synchronize: @escaping DurableFileSynchronizeOperation = { descriptor in
        Darwin.fsync(descriptor)
    },
    close: @escaping DurableFileCloseOperation = { descriptor in
        Darwin.close(descriptor)
    },
    rename: @escaping DurableFileRenameOperation = { source, destination in
        source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }
    }
) -> DurableFileSystemOperations {
    DurableFileSystemOperations(
        open: open,
        write: write,
        synchronize: synchronize,
        close: close,
        rename: rename
    )
}

private func awaitPOSIXError(
    _ expected: POSIXErrorCode,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected POSIXError.\(expected)")
    } catch let error as POSIXError {
        #expect(error.code == expected)
    } catch {
        Issue.record("Expected POSIXError.\(expected), received \(error)")
    }
}

private func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "akashic-durable-faults-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    guard Darwin.chmod(root.path, mode_t(0o700)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    return try operation(root)
}

private func durableTemporaryFiles(in root: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
    )) ?? []).filter { $0.lastPathComponent.hasPrefix(".durable-tmp-") }
}
