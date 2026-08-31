import AkashicCore
import Darwin
import Foundation

package struct SegmentedManifestSegmentCleanupFailure: Sendable, Equatable {
    package let fileName: String
    package let posixCode: Int32
}

package struct SegmentedManifestSegmentCleanupResult: Sendable, Equatable {
    package let deletedCount: Int
    package let remainingDebtCount: Int
    package let totalEntryCount: Int
    /// Bounded diagnostics for owned canonical entries that reached unlink and failed with a
    /// non-ENOENT error. This does not classify retryability or weaken physical ownership checks.
    package let failures: [SegmentedManifestSegmentCleanupFailure]
}

package enum SegmentedManifestSegmentCleanupV1 {
    /// A valid root references at most one base plus 64 runs. Allow the same amount of bounded
    /// orphan/retired debt without making directory scans or recovery state unbounded.
    package static let maximumDirectoryEntries =
        2 * (SegmentedManifestPrototypeV1.maximumRunDescriptors + 1)

    @discardableResult
    package static func reclaimUnreferenced(
        root: SegmentedManifestRootV1?,
        directory: URL,
        preserving: Set<String> = []
    ) throws -> SegmentedManifestSegmentCleanupResult {
        // One detached compaction may need to preserve its frozen base + 64-run descriptor set
        // plus one not-yet-authoritative candidate while foreground work publishes a replacement
        // topology. This remains bounded by the manifest descriptor constants; preserving is a
        // temporary physical read lease, never logical authority.
        guard preserving.count <= SegmentedManifestPrototypeV1.maximumRunDescriptors + 2,
            preserving.allSatisfy({ isProductionCanonical($0) })
        else { throw AkashicError.invalidManifest }
        try StorageDirectorySecurity.validateDirectory(directory)
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: maximumDirectoryEntries
        )
        let referenced = referencedNames(root)
        var deleted = 0
        var remainingDebt = 0
        var failures: [SegmentedManifestSegmentCleanupFailure] = []
        var needsSync = false

        for name in names {
            if referenced.contains(name) || preserving.contains(name) { continue }
            guard isProductionCanonical(name) else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            // A canonical-looking entry is ours only if its physical identity remains a private,
            // singly-linked regular file. Unsafe lookalikes fail closed rather than being unlinked.
            try StorageDirectorySecurity.validateRegularFile(url)
            let result = url.path.withCString { Darwin.unlink($0) }
            let unlinkErrno = result == 0 ? 0 : errno
            if result == 0 {
                deleted += 1
                needsSync = true
            } else if unlinkErrno == ENOENT {
                // A benign disappearance after validation is already repaid. Same-user replacement
                // races are outside the current protection claim.
                deleted += 1
            } else {
                remainingDebt += 1
                failures.append(
                    SegmentedManifestSegmentCleanupFailure(
                        fileName: name,
                        posixCode: unlinkErrno
                    )
                )
            }
        }
        if needsSync { try synchronizeDirectory(directory) }
        precondition(failures.count == remainingDebt)
        precondition(failures.count <= maximumDirectoryEntries)
        return SegmentedManifestSegmentCleanupResult(
            deletedCount: deleted,
            remainingDebtCount: remainingDebt,
            totalEntryCount: names.count - deleted,
            failures: failures
        )
    }

    package static func validateReferencedProductionOwnership(
        root: SegmentedManifestRootV1
    ) throws {
        guard isProductionCanonical(root.base.fileName),
            root.runs.allSatisfy({ isProductionCanonical($0.fileName) })
        else { throw AkashicError.invalidManifest }
    }

    package static func ensureMaterializationCapacity(
        directory: URL,
        additionalEntries: Int = 1
    ) throws {
        guard additionalEntries > 0,
            additionalEntries <= maximumDirectoryEntries
        else { throw AkashicError.limitExceeded }
        guard try availableMaterializationEntries(directory: directory) >= additionalEntries else {
            throw AkashicError.limitExceeded
        }
    }

    package static func availableMaterializationEntries(
        directory: URL
    ) throws -> Int {
        try StorageDirectorySecurity.validateDirectory(directory)
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: maximumDirectoryEntries
        )
        return maximumDirectoryEntries - names.count
    }

    package static func isProductionCanonical(_ name: String) -> Bool {
        if SegmentedManifestPrototypeV1.isCanonicalSegmentFileName(
            name,
            kind: .compoundRunV1
        ) { return true }
        if canonicalUUIDName(name, prefix: "base-migration-", suffix: ".json") { return true }
        if canonicalUUIDName(name, prefix: "base-compaction-", suffix: ".json") { return true }
        if canonicalUUIDName(name, prefix: "base-binary-", suffix: ".akb") { return true }
        if canonicalUUIDName(name, prefix: "base-binary-v2-", suffix: ".akb2") { return true }
        guard name.hasPrefix("run-g"), name.hasSuffix(".seg") else { return false }
        let body = String(name.dropFirst(5).dropLast(4))
        guard let dash = body.firstIndex(of: "-") else { return false }
        let generation = String(body[..<dash])
        let uuidText = String(body[body.index(after: dash)...])
        guard !generation.isEmpty,
            generation.allSatisfy({ $0.isASCII && $0.isNumber }),
            (generation == "0" || generation.first != "0"),
            UInt64(generation) != nil
        else { return false }
        return canonicalLowercaseUUID(uuidText)
    }

    private static func referencedNames(_ root: SegmentedManifestRootV1?) -> Set<String> {
        guard let root else { return [] }
        return Set(([root.base] + root.runs).map(\.fileName))
    }

    private static func canonicalUUIDName(
        _ name: String,
        prefix: String,
        suffix: String
    ) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuidText = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return canonicalLowercaseUUID(uuidText)
    }

    private static func canonicalLowercaseUUID(_ text: String) -> Bool {
        guard text == text.lowercased(),
            let uuid = UUID(uuidString: text)
        else { return false }
        return uuid.uuidString.lowercased() == text
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        }
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
