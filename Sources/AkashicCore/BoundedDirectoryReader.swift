import Darwin
import Foundation

/// 通过 POSIX 目录流读取直接子项，包含隐藏文件，并在累计名称前执行硬数量上限。
package enum BoundedDirectoryReader {
    package static func names(
        in directory: URL,
        maximumCount: Int
    ) throws -> [String] {
        guard maximumCount > 0 else { throw AkashicError.limitExceeded }
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else { throw posixError() }
        do {
            try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }

        guard let stream = Darwin.fdopendir(descriptor) else {
            _ = Darwin.close(descriptor)
            throw posixError()
        }
        defer { _ = Darwin.closedir(stream) }

        var names: [String] = []
        names.reserveCapacity(min(1_024, maximumCount))
        errno = 0
        while let pointer = Darwin.readdir(stream) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumCount else {
                throw AkashicError.limitExceeded
            }
            names.append(name)
            errno = 0
        }
        guard errno == 0 else { throw posixError() }
        return names
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
