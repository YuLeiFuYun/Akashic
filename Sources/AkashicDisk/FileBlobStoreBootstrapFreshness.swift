import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    /// A missing root manifest is only an initialization case when the physical store carries no
    /// evidence of an earlier logical state. Otherwise creating a new empty manifest would turn
    /// root-metadata loss into silent logical loss and bootstrap could subsequently delete the
    /// surviving payloads as unreferenced files.
    func requireFreshPhysicalStateForMissingManifest() throws {
        let names = try BoundedDirectoryReader.names(
            in: blobs,
            maximumCount: limits.maximumDirectoryEntryCount
        )
        guard names.isEmpty else { throw AkashicError.invalidManifest }
        guard try !hasDirectoryHeadPhysicalEvidence() else {
            throw AkashicError.invalidManifest
        }
    }

    /// A legacy root manifest cannot coexist with schema4 directory-head metadata. Treating the
    /// legacy file as authoritative in that state would allow one root-file rollback to silently
    /// downgrade carrier semantics and ignore the newer committed heads/records.
    func requireNoDirectoryHeadEvidenceForLegacyManifest() throws {
        guard try !hasDirectoryHeadPhysicalEvidence() else {
            throw AkashicError.invalidManifest
        }
    }

    private func hasDirectoryHeadPhysicalEvidence() throws -> Bool {
        let attributes: [String]
        do {
            attributes = try directoryHeadOperations.listAttributes(
                blobs,
                Self.maximumDirectoryHeadXattrListBytes
            )
        } catch let error as POSIXError
            where error.code == .ENOTSUP || error.code == .EOPNOTSUPP
        {
            // A filesystem that cannot carry directory xattrs cannot contain schema4
            // directory-head authority. Preserve the schema3 sidecar fallback on such media.
            return false
        }

        for name in attributes {
            if try DirectoryHeadIdentity.parse(name) != nil { return true }
            if try DirectoryHeadRecordIdentity.parse(name) != nil { return true }
        }
        return false
    }
}
