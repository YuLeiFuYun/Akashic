import AkashicCore
import Darwin
import Foundation
import Testing

@testable import AkashicDisk

@Suite("AkashicDisk permission-transition recovery")
struct FileBlobStorePermissionTransitionTests {
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
