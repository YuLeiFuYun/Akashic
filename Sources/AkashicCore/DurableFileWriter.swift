import Darwin
import Foundation

package enum DurableFileWriteSwitchPoint: String, CaseIterable, Sendable {
    case afterDataWritten
    case afterFileSynced
    case afterRename
    case afterDirectorySynced
}

package typealias DurableFileWriteFaultInjector =
    @Sendable (DurableFileWriteSwitchPoint) throws -> Void

/// 允许包内测试精确控制一次底层 `write(2)` 调用的返回行为。
package typealias DurableFileWriteOperation =
    (Int32, UnsafeRawPointer, Int) -> Int

/// 允许包内测试精确控制 `fsync(2)` 的返回行为。
package typealias DurableFileSynchronizeOperation = (Int32) -> Int32

/// 允许包内测试精确控制 `close(2)` 的返回行为。
package typealias DurableFileCloseOperation = (Int32) -> Int32

/// 允许包内测试精确控制同目录 `rename(2)` 的返回行为。
package typealias DurableFileRenameOperation = (String, String) -> Int32

/// `DurableFileWriter` 的 package-only 系统调用表。
///
/// 生产入口始终使用真实 Darwin 系统调用；测试入口通过该值验证部分成功、
/// `EINTR`、空间耗尽和同步失败不会绕过原子可见性边界。
package struct DurableFileSystemOperations {
    package let write: DurableFileWriteOperation
    package let synchronize: DurableFileSynchronizeOperation
    package let close: DurableFileCloseOperation
    package let rename: DurableFileRenameOperation

    package init(
        write: @escaping DurableFileWriteOperation,
        synchronize: @escaping DurableFileSynchronizeOperation,
        close: @escaping DurableFileCloseOperation,
        rename: @escaping DurableFileRenameOperation
    ) {
        self.write = write
        self.synchronize = synchronize
        self.close = close
        self.rename = rename
    }
}

/// 在同一目录内暂存并耐久地原子替换文件。
///
/// 成功返回前依次保证：暂存文件安全属性已设置、内容写完、文件 `fsync`、原子
/// `rename`、父目录 `fsync`。调用方仍需用更高层事务协调多个文件之间的可见性。
package enum DurableFileWriter {
    package static func writeReplacing(_ data: Data, to destination: URL) throws {
        try writeReplacing(data, to: destination, faultInjector: { _ in })
    }

    package static func writeReplacing(
        _ data: Data,
        to destination: URL,
        faultInjector: DurableFileWriteFaultInjector
    ) throws {
        try writeReplacing(
            data,
            to: destination,
            faultInjector: faultInjector,
            operations: systemOperations()
        )
    }

    /// 使用指定的同步系统调用表执行完整耐久替换。
    ///
    /// 该入口保持 package-only，只用于证明部分写入、`EINTR`、空间耗尽、
    /// close/rename/fsync 失败不会绕过完整写入循环或原子替换边界。
    package static func writeReplacing(
        _ data: Data,
        to destination: URL,
        faultInjector: DurableFileWriteFaultInjector,
        operations: DurableFileSystemOperations
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".durable-tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        do {
            try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
        } catch {
            _ = operations.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        var descriptorIsOpen = true
        do {
            // 属性必须在文件同步前写入；rename 会保留同一 inode 的保护属性与扩展属性。
            try StorageDirectorySecurity.securePublishedFile(temporary)
            try writeAll(data, to: descriptor, operation: operations.write)
            try faultInjector(.afterDataWritten)
            try synchronize(descriptor, operation: operations.synchronize)
            try faultInjector(.afterFileSynced)

            // close 失败后描述符是否仍可用并不适合由调用方猜测，因此绝不重试同一 fd。
            let closeResult = operations.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else { throw posixError() }

            guard operations.rename(temporary.path, destination.path) == 0 else {
                throw posixError()
            }
            try faultInjector(.afterRename)
            try synchronizeDirectory(directory, operations: operations)
            try faultInjector(.afterDirectorySynced)
        } catch {
            if descriptorIsOpen { _ = operations.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        operation: DurableFileWriteOperation
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = operation(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                written += result
            }
        }
    }

    private static func synchronize(
        _ descriptor: Int32,
        operation: DurableFileSynchronizeOperation
    ) throws {
        while true {
            let result = operation(descriptor)
            if result == 0 { return }
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func synchronizeDirectory(
        _ directory: URL,
        operations: DurableFileSystemOperations
    ) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = operations.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        try synchronize(descriptor, operation: operations.synchronize)
    }

    private static func systemOperations() -> DurableFileSystemOperations {
        DurableFileSystemOperations(
            write: { descriptor, bytes, count in
                Darwin.write(descriptor, bytes, count)
            },
            synchronize: { descriptor in Darwin.fsync(descriptor) },
            close: { descriptor in Darwin.close(descriptor) },
            rename: { source, destination in
                source.withCString { sourcePointer in
                    destination.withCString { destinationPointer in
                        Darwin.rename(sourcePointer, destinationPointer)
                    }
                }
            }
        )
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
