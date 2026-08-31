import AkashicCore
import Darwin
import Foundation
import Testing

@Suite("AkashicCore storage ownership boundary")
struct StorageDirectorySecurityOwnershipTests {
    @Test("AKASHIC-CT-016 different-owner regular descriptor is rejected by the owner gate")
    func differentOwnerRegularDescriptorIsRejected() throws {
        let effectiveUser = Darwin.geteuid()
        var candidates = [
            "/etc/hosts",
            "/etc/passwd",
            "/private/etc/hosts",
            "/private/etc/passwd",
        ]
        var temporaryRoot: URL?
        if effectiveUser == 0 {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("akashic-owner-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            temporaryRoot = root
            let path = root.appendingPathComponent("different-owner").path
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
            let changed = path.withCString {
                Darwin.chown($0, uid_t(1), gid_t.max)
            }
            #expect(changed == 0)
            candidates.insert(path, at: 0)
        }
        defer {
            if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        }

        var selected: (path: String, status: stat)?
        for path in candidates {
            var status = stat()
            guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else { continue }
            guard status.st_mode & S_IFMT == S_IFREG,
                status.st_nlink == 1,
                status.st_uid != effectiveUser
            else { continue }
            selected = (path, status)
            break
        }

        let fixture = try #require(selected)
        let descriptor = fixture.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }

        var opened = stat()
        #expect(Darwin.fstat(descriptor, &opened) == 0)
        #expect(opened.st_mode & S_IFMT == S_IFREG)
        #expect(opened.st_nlink == 1)
        #expect(opened.st_uid == fixture.status.st_uid)
        #expect(opened.st_uid != effectiveUser)

        #expect(throws: AkashicError.storageUnavailable) {
            _ = try StorageDirectorySecurity.validatedOpenedOwnedRegularFileStatus(descriptor)
        }
    }
}
