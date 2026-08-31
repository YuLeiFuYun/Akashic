import Darwin
import Foundation

package typealias FileBlobStoreFastOpenOperation =
    @Sendable (String, Int32, mode_t) -> Int32
package typealias FileBlobStoreFastWriteOperation =
    @Sendable (Int32, UnsafeRawPointer, Int) -> Int
package typealias FileBlobStoreManifestXattrSetOperation =
    @Sendable (Int32, String, Data) -> Int32
package typealias FileBlobStoreFastSynchronizeOperation =
    @Sendable (Int32) -> Int32
package typealias FileBlobStoreFastCloseOperation =
    @Sendable (Int32) -> Int32
package typealias FileBlobStoreFastRenameOperation =
    @Sendable (String, String) -> Int32

/// Package-only syscall table for the fast create/replacement transaction.
///
/// Production and probes always use the Darwin defaults. Tests may replace one operation at a time
/// to prove fast-path error boundaries without weakening the public storage API or faking unrelated
/// filesystem work.
package struct FileBlobStoreFastCommitOperations: Sendable {
    package let open: FileBlobStoreFastOpenOperation
    package let write: FileBlobStoreFastWriteOperation
    package let setManifestXattr: FileBlobStoreManifestXattrSetOperation
    package let synchronize: FileBlobStoreFastSynchronizeOperation
    package let close: FileBlobStoreFastCloseOperation
    package let rename: FileBlobStoreFastRenameOperation

    package init(
        open: @escaping FileBlobStoreFastOpenOperation = Self.systemOpen,
        write: @escaping FileBlobStoreFastWriteOperation = Self.systemWrite,
        setManifestXattr: @escaping FileBlobStoreManifestXattrSetOperation = Self.systemSetManifestXattr,
        synchronize: @escaping FileBlobStoreFastSynchronizeOperation = Self.systemSynchronize,
        close: @escaping FileBlobStoreFastCloseOperation = Self.systemClose,
        rename: @escaping FileBlobStoreFastRenameOperation = Self.systemRename
    ) {
        self.open = open
        self.write = write
        self.setManifestXattr = setManifestXattr
        self.synchronize = synchronize
        self.close = close
        self.rename = rename
    }

    package static let system = Self()

    package static func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
        path.withCString { Darwin.open($0, flags, mode) }
    }

    package static func systemWrite(
        _ descriptor: Int32,
        _ bytes: UnsafeRawPointer,
        _ count: Int
    ) -> Int {
        Darwin.write(descriptor, bytes, count)
    }

    package static func systemSetManifestXattr(
        _ descriptor: Int32,
        _ name: String,
        _ data: Data
    ) -> Int32 {
        name.withCString { pointer in
            data.withUnsafeBytes { bytes in
                Darwin.fsetxattr(
                    descriptor,
                    pointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    XATTR_CREATE
                )
            }
        }
    }

    package static func systemSynchronize(_ descriptor: Int32) -> Int32 {
        Darwin.fsync(descriptor)
    }

    package static func systemClose(_ descriptor: Int32) -> Int32 {
        Darwin.close(descriptor)
    }

    package static func systemRename(_ source: String, _ destination: String) -> Int32 {
        source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }
    }
}
