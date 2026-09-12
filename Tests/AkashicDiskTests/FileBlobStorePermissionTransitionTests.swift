import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk permission-transition recovery")
struct FileBlobStorePermissionTransitionTests {

    #if os(macOS)
    @Test("Real ACL delete_child denial reopens miss after exact ACL restoration", .enabled(if: Darwin.geteuid() != 0))
    func manifestACLRenameDenialRecoversAfterACLRestoration() async throws {
        try await withTemporaryDirectory { root in
            let data = Data("acl-publication-payload".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try CachePartitionID.derive(
                domain: "akashic-acl-transition", material: Data([0x02])
            )
            let directory = root.appendingPathComponent("blobs", isDirectory: true)
            let acl = ManifestTestACL(directory: directory)
            defer {
                do { try acl.restore() }
                catch { Issue.record("Unable to restore manifest test ACL: \(error)") }
            }
            var store: FileBlobStore? = try await FileBlobStore.open(
                root: root,
                faultInjector: { point in
                    guard point == .afterManifestFileSynced else { return }
                    try acl.install()
                }
            )
            let stage = try await store!.stage(data: data, digest: digest, partition: partition)
            do {
                _ = try await store!.publish(stage)
                Issue.record("Expected real ACL manifest rename denial")
            } catch let error as POSIXError {
                #expect(error.code == .EACCES || error.code == .EPERM)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            try acl.restore()
            store = nil
            let reopened = try await reopenStore(root: root)
            await expectAkashicError(.notFound) {
                _ = try await reopened.read(digest: digest, partition: partition)
            }
            #expect(recursiveTemporaryFiles(in: root).isEmpty)
            #expect(blobFiles(in: root).isEmpty)
            _ = try await reopened.commit(data: data, digest: digest, partition: partition)
            #expect(try await reopened.read(digest: digest, partition: partition) == data)
        }
    }
    #endif

    @Test("Manifest rename denial preserves a miss and bootstrap removes leftovers")
    func manifestRenameDenialRecoversAfterPermissionRestoration() async throws {
        try await withTemporaryDirectory { root in
            let data = Data("permission-transition-payload".utf8)
            let digest = BlobDigest.sha256(of: data)
            let partition = try CachePartitionID.derive(
                domain: "akashic-permission-transition",
                material: Data([0x01])
            )
            let publicationDirectory = root.appendingPathComponent("blobs", isDirectory: true)
            var store: FileBlobStore? = try await FileBlobStore.open(
                root: root,
                faultInjector: { point in
                    guard point == .afterManifestFileSynced else { return }
                    guard Darwin.chmod(publicationDirectory.path, mode_t(0o500)) == 0 else {
                        throw currentPOSIXError()
                    }
                }
            )
            defer { _ = Darwin.chmod(publicationDirectory.path, mode_t(0o700)) }

            let stage = try await store!.stage(
                data: data,
                digest: digest,
                partition: partition
            )
            do {
                _ = try await store!.publish(stage)
                Issue.record("Expected manifest rename to fail after permission loss")
            } catch let error as POSIXError {
                #expect(error.code == .EACCES || error.code == .EPERM)
            }

            #expect(Darwin.chmod(publicationDirectory.path, mode_t(0o700)) == 0)
            store = nil
            let reopened = try await reopenStore(root: root)
            await expectAkashicError(.notFound) {
                _ = try await reopened.read(digest: digest, partition: partition)
            }
            #expect(recursiveTemporaryFiles(in: root).isEmpty)
            #expect(blobFiles(in: root).isEmpty)
        }
    }
}

private func withTemporaryDirectory<T>(
    _ operation: (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "akashic-permission-transition-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    defer {
        _ = Darwin.chmod(root.path, mode_t(0o700))
        try? FileManager.default.removeItem(at: root)
    }
    return try await operation(root)
}

private func reopenStore(root: URL) async throws -> FileBlobStore {
    for _ in 0..<200 {
        do {
            return try await FileBlobStore.open(root: root)
        } catch AkashicError.transactionConflict {
            await Task.yield()
        }
    }
    throw AkashicError.transactionConflict
}

private func expectAkashicError<T>(
    _ expected: AkashicError,
    operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        Issue.record("Expected AkashicError.\(expected)")
    } catch let error as AkashicError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected AkashicError.\(expected), received \(error)")
    }
}

private func recursiveTemporaryFiles(in root: URL) -> [URL] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        )
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        $0.lastPathComponent.hasPrefix(".durable-tmp-")
            || $0.lastPathComponent.hasPrefix(".tmp-")
    }
}

private func blobFiles(in root: URL) -> [URL] {
    let blobs = root.appendingPathComponent("blobs", isDirectory: true)
    return
        (try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

#if os(macOS)
private final class ManifestTestACL: @unchecked Sendable {
    private struct State: Equatable {
        let mode: Int
        let entries: [String]
    }

    private let directory: URL
    private let rule = "user:\(NSUserName()) deny delete_child"
    private let lock = NSLock()
    private var installed = false
    private var baseline: State?

    init(directory: URL) { self.directory = directory }

    func install() throws {
        try lock.withLock {
            guard !installed else { return }
            let before = try snapshot()
            guard !before.entries.contains(where: { $0.contains(rule) }) else {
                throw POSIXError(.EEXIST)
            }
            try change("+a")
            let after = try snapshot()
            guard after.mode == before.mode,
                  after.entries.count == before.entries.count + 1,
                  after.entries.contains(where: { $0.contains(rule) }) else {
                try? change("-a")
                throw POSIXError(.EIO)
            }
            baseline = before
            installed = true
        }
    }

    func restore() throws {
        try lock.withLock {
            guard installed, let expected = baseline else { return }
            try change("-a")
            installed = false
            baseline = nil
            guard try snapshot() == expected else {
                throw POSIXError(.EIO)
            }
        }
    }

    private func snapshot() throws -> State {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let mode = attributes[.posixPermissions] as? NSNumber else {
            throw POSIXError(.EIO)
        }
        return State(mode: mode.intValue, entries: try aclEntries())
    }

    private func aclEntries() throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = ["-lde", directory.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .map(String.init)
    }

    private func change(_ operation: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = [operation, rule, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
    }
}
#endif
