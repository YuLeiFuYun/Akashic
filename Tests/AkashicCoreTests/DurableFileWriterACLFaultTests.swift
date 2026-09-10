import Darwin
import Foundation
import Testing

@testable import AkashicCore

#if os(macOS)
extension DurableFileWriterFaultTests {
    @Test("Real ACL add_file denial preserves bytes and exact ACL restoration", .enabled(if: Darwin.geteuid() != 0))
    func realACLTemporaryOpenDenialPreservesOldDestination() throws {
        try verifyRealACLDirectoryDenial(permission: .addFile, afterFileSync: false)
    }

    @Test("Real ACL delete_child rename denial preserves bytes and exact ACL restoration", .enabled(if: Darwin.geteuid() != 0))
    func realACLRenameDenialPreservesOldDestination() throws {
        try verifyRealACLDirectoryDenial(permission: .deleteChild, afterFileSync: true)
    }
}

private enum DurableTestACLPermission: String {
    case addFile = "add_file"
    case deleteChild = "delete_child"
}

private func verifyRealACLDirectoryDenial(
    permission: DurableTestACLPermission,
    afterFileSync: Bool
) throws {
    try withTemporaryDirectory { root in
        let destination = root.appendingPathComponent("acl-state.bin")
        let old = Data("old-before-acl-denial".utf8)
        let replacement = Data("new-after-acl-restoration".utf8)
        try old.write(to: destination)
        let acl = DurableTestACL(directory: root, permission: permission)
        defer {
            do { try acl.restore() }
            catch { Issue.record("Unable to restore test ACL: \(error)") }
        }
        if !afterFileSync { try acl.install() }
        let observed = DurableFileSwitchPointRecorder()
        do {
            try DurableFileWriter.writeReplacing(
                replacement, to: destination,
                faultInjector: { point in
                    if afterFileSync, point == .afterFileSynced { try acl.install() }
                    observed.record(point)
                }
            )
            Issue.record("Expected a real ACL denial from the production syscall")
        } catch let error as POSIXError {
            #expect(error.code == .EACCES || error.code == .EPERM)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(observed.snapshot().contains(.afterFileSynced) == afterFileSync)
        #expect(!observed.snapshot().contains(.afterRename))
        #expect(try Data(contentsOf: destination) == old)
        let deniedTemporaryFiles = durableTemporaryFiles(in: root)
        switch permission {
        case .addFile:
            #expect(deniedTemporaryFiles.isEmpty)
        case .deleteChild:
            // The same directory ACL that denies replacement also denies unlinking
            // the already-created temporary file. Do not misclassify that expected
            // cleanup obstruction as a writer mutation of the published destination.
            #expect(deniedTemporaryFiles.count == 1)
        }
        try acl.restore()
        try DurableFileWriter.writeReplacing(replacement, to: destination)
        #expect(try Data(contentsOf: destination) == replacement)
        for temporaryFile in deniedTemporaryFiles {
            try FileManager.default.removeItem(at: temporaryFile)
        }
        #expect(durableTemporaryFiles(in: root).isEmpty)
    }
}

private final class DurableTestACL: @unchecked Sendable {
    private struct State: Equatable {
        let mode: Int
        let entries: [String]
    }

    private let directory: URL
    private let rule: String
    private let lock = NSLock()
    private var installed = false
    private var baseline: State?

    init(directory: URL, permission: DurableTestACLPermission) {
        self.directory = directory
        self.rule = "user:\(NSUserName()) deny \(permission.rawValue)"
    }

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
