import AkashicCore
import Foundation
import Testing

@testable import AkashicDisk

@Suite("Store retirement lease")
struct StoreRetirementLeaseTests {
    @Test("canonical lock path shares one process-local coordinator")
    func canonicalPathSharesCoordinator() async throws {
        try await withFileBlobStoreTestTemporaryDirectory { root in
            try StorageDirectorySecurity.prepareDirectory(root)
            let lock = root.appendingPathComponent(".akashic-retirement.lock")
            let dotted = root.appendingPathComponent(".", isDirectory: true)
                .appendingPathComponent(".akashic-retirement.lock")

            let first = try RetirementLocalReaderCoordinator.shared(path: lock)
            let second = try RetirementLocalReaderCoordinator.shared(path: dotted)
            #expect(first === second)
        }
    }

    @Test("registry retains one descriptor authority for the process lifetime")
    func registryRetainsCoordinator() async throws {
        try await withFileBlobStoreTestTemporaryDirectory { root in
            try StorageDirectorySecurity.prepareDirectory(root)
            let lock = root.appendingPathComponent(".akashic-retirement.lock")
            weak var retainedByRegistry: RetirementLocalReaderCoordinator?
            do {
                let coordinator = try RetirementLocalReaderCoordinator.shared(path: lock)
                retainedByRegistry = coordinator
            }

            #expect(retainedByRegistry != nil)
            let second = try RetirementLocalReaderCoordinator.shared(path: lock)
            let retained = retainedByRegistry
            #expect(retained === second)
        }
    }

    @Test("reader retirement lock is refcounted inside one process")
    func readerRefcount() async throws {
        try await withFileBlobStoreTestTemporaryDirectory { root in
            try StorageDirectorySecurity.prepareDirectory(root)
            let coordinator = try RetirementLocalReaderCoordinator.shared(
                path: root.appendingPathComponent(".akashic-retirement.lock")
            )

            #expect(try coordinator.acquireReader() == 1)
            #expect(try coordinator.acquireReader() == 2)
            #expect(try coordinator.releaseReader() == 1)
            #expect(try coordinator.releaseReader() == 0)
        }
    }

    @Test("writer intent closes reader admission until retirement completes")
    func writerTurnstile() async throws {
        try await withFileBlobStoreTestTemporaryDirectory { root in
            try StorageDirectorySecurity.prepareDirectory(root)
            let coordinator = try RetirementLocalReaderCoordinator.shared(
                path: root.appendingPathComponent(".akashic-retirement.lock")
            )

            #expect(try coordinator.acquireReader() == 1)
            #expect(try coordinator.beginWriterIntent())

            let blockedReader = try coordinator.tryAcquireReader()
            #expect(!blockedReader.acquired)
            #expect(blockedReader.readerCount == 1)

            let blockedWriter = try coordinator.tryFinishWriterAcquire()
            #expect(!blockedWriter.acquired)
            #expect(blockedWriter.readerCount == 1)

            #expect(try coordinator.releaseReader() == 0)
            let acquiredWriter = try coordinator.tryFinishWriterAcquire()
            #expect(acquiredWriter.acquired)
            #expect(acquiredWriter.readerCount == 0)

            let readerDuringWriter = try coordinator.tryAcquireReader()
            #expect(!readerDuringWriter.acquired)
            #expect(readerDuringWriter.readerCount == 0)

            try coordinator.releaseWriter()
            let readerAfterWriter = try coordinator.tryAcquireReader()
            #expect(readerAfterWriter.acquired)
            #expect(readerAfterWriter.readerCount == 1)
            #expect(try coordinator.releaseReader() == 0)
        }
    }


    @Test("external writer cannot deadlock local reader release behind reader admission")
    func externalWriterDoesNotDeadlockReaderAdmission() async throws {
        try await exerciseExternalWriterGateCycle(waiter: .reader)
    }

    @Test("external writer cannot deadlock local reader release behind local writer intent")
    func externalWriterDoesNotDeadlockWriterIntent() async throws {
        try await exerciseExternalWriterGateCycle(waiter: .writer)
    }

    private enum ExternalGateWaiter {
        case reader
        case writer
    }

    private func exerciseExternalWriterGateCycle(waiter: ExternalGateWaiter) async throws {
        try await withFileBlobStoreTestTemporaryDirectory { root in
            try StorageDirectorySecurity.prepareDirectory(root)
            let lock = root.appendingPathComponent(".akashic-retirement.lock")
            let childReady = root.appendingPathComponent("external-gate-ready")
            let released = root.appendingPathComponent("local-reader-released")
            let waiterDone = root.appendingPathComponent("local-waiter-done")
            let coordinator = try RetirementLocalReaderCoordinator.shared(path: lock)
            #expect(try coordinator.acquireReader() == 1)

            let child = try externalGateWriter(lock: lock, ready: childReady)
            defer {
                if child.isRunning { child.terminate() }
                child.waitUntilExit()
            }
            try await waitForRetirementMarker(childReady)

            let localWaiter = Task.detached {
                switch waiter {
                case .reader:
                    guard try coordinator.acquireReader() == 1 else {
                        throw AkashicError.storageUnavailable
                    }
                    guard try coordinator.releaseReader() == 0 else {
                        throw AkashicError.storageUnavailable
                    }
                case .writer:
                    guard try coordinator.beginWriterIntent() else {
                        throw AkashicError.storageUnavailable
                    }
                    let acquired = try coordinator.tryFinishWriterAcquire()
                    guard acquired.acquired, acquired.readerCount == 0 else {
                        throw AkashicError.storageUnavailable
                    }
                    try coordinator.releaseWriter()
                }
                try Data("done\n".utf8).write(to: waiterDone)
            }

            try await Task.sleep(nanoseconds: 50_000_000)
            let release = Task.detached {
                let count = try coordinator.releaseReader()
                try Data("released\n".utf8).write(to: released)
                return count
            }
            try await waitForRetirementMarker(released)
            let releasedCount = try await release.value
            #expect(releasedCount == 0)
            try await waitForRetirementMarker(waiterDone)
            try await localWaiter.value
            child.waitUntilExit()
            #expect(child.terminationStatus == 0)
        }
    }

    private func externalGateWriter(lock: URL, ready: URL) throws -> Process {
        let script = """
        import fcntl, os, sys
        descriptor = os.open(sys.argv[1], os.O_RDWR)
        fcntl.lockf(descriptor, fcntl.LOCK_EX, 1, 0, os.SEEK_SET)
        with open(sys.argv[2], "wb") as marker:
            marker.write(bytes((114, 101, 97, 100, 121, 10)))
        fcntl.lockf(descriptor, fcntl.LOCK_EX, 1, 1, os.SEEK_SET)
        os.close(descriptor)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, lock.path, ready.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func waitForRetirementMarker(_ marker: URL) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AkashicError.storageUnavailable
    }

    @Test("invalid local release transitions fail closed")
    func invalidReleaseFailsClosed() async throws {
        try await withFileBlobStoreTestTemporaryDirectory { root in
            try StorageDirectorySecurity.prepareDirectory(root)
            let coordinator = try RetirementLocalReaderCoordinator.shared(
                path: root.appendingPathComponent(".akashic-retirement.lock")
            )

            #expect(throws: AkashicError.storageUnavailable) {
                _ = try coordinator.releaseReader()
            }
            #expect(throws: AkashicError.storageUnavailable) {
                try coordinator.releaseWriter()
            }
        }
    }
}
