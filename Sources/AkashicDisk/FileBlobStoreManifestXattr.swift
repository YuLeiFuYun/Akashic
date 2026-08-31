import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    /// Fast-create manifest authority carried by the published blob inode.
    ///
    /// The xattr name independently binds format version, generation and the 32-byte manifest key.
    /// Its value reuses the compact ManifestRecord create representation. Tombstones intentionally
    /// remain sidecar records so deleting a large payload never requires retaining that payload as
    /// tombstone storage until the next checkpoint.
    struct ManifestXattrIdentity: Equatable {
        private static let familyPrefix = "dev.akashic.manifest-entry-"
        private static let prefix = "dev.akashic.manifest-entry-v1.g"
        private static let keyByteCount = 64
        private static let generationHexByteCount = 16

        let generation: UInt64
        let key: String

        var name: String {
            "\(Self.prefix)\(String(format: "%016llx", generation)).\(key)"
        }

        static func make(generation: UInt64, key: String) -> Self? {
            guard generation > 0, isValidManifestKey(key) else { return nil }
            return Self(generation: generation, key: key)
        }

        static func parse(_ name: String) throws -> Self? {
            guard name.hasPrefix(familyPrefix) else { return nil }
            let bytes = Array(name.utf8)
            let prefixBytes = Array(prefix.utf8)
            guard bytes.count == prefixBytes.count + generationHexByteCount + 1 + keyByteCount,
                bytes.prefix(prefixBytes.count).elementsEqual(prefixBytes),
                bytes[prefixBytes.count + generationHexByteCount] == 46
            else {
                throw AkashicError.invalidManifest
            }
            let generationBytes = bytes[
                prefixBytes.count ..< (prefixBytes.count + generationHexByteCount)
            ]
            let keyBytes = bytes[(prefixBytes.count + generationHexByteCount + 1) ..< bytes.count]
            guard generationBytes.allSatisfy(isLowercaseHex),
                keyBytes.allSatisfy(isLowercaseHex),
                let generation = UInt64(
                    String(decoding: generationBytes, as: UTF8.self),
                    radix: 16
                ),
                generation > 0
            else {
                throw AkashicError.invalidManifest
            }
            return Self(
                generation: generation,
                key: String(decoding: keyBytes, as: UTF8.self)
            )
        }

        private static func isValidManifestKey(_ key: String) -> Bool {
            let bytes = Array(key.utf8)
            return bytes.count == keyByteCount && bytes.allSatisfy(isLowercaseHex)
        }

        private static func isLowercaseHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    struct ManifestXattrRecord {
        let key: String
        let record: ManifestRecord
    }

    /// Returns false only for a filesystem that explicitly cannot carry this xattr representation.
    /// All durability, space and integrity failures remain hard failures and must not be hidden by
    /// silently falling back to a different transaction after ambiguous progress.
    static func setManifestXattrIfSupported(
        recordData: Data,
        identity: ManifestXattrIdentity,
        descriptor: Int32,
        setOperation: FileBlobStoreManifestXattrSetOperation
    ) throws -> Bool {
        let result = setOperation(descriptor, identity.name, recordData)
        if result == 0 { return true }
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        switch code {
        case .ENOTSUP, .E2BIG:
            return false
        default:
            throw POSIXError(code)
        }
    }

    static func readCurrentManifestXattrRecords(
        at url: URL,
        physicalID: PhysicalBlobID,
        generation: UInt64
    ) throws -> [ManifestXattrRecord] {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AkashicError.storageUnavailable }
        defer { _ = Darwin.close(descriptor) }

        // Authority may be needed to reconstruct the manifest before the final bootstrap
        // reconciliation can repair permission drift. Type/link/owner remain fail-closed here;
        // the normal reconciliation phase still enforces/repairs private mode before open returns.
        _ = try StorageDirectorySecurity.validatedOpenedOwnedRegularFileStatus(descriptor)
        let names = try manifestXattrNames(descriptor: descriptor)
        var current: [ManifestXattrRecord] = []
        for name in names {
            guard let identity = try ManifestXattrIdentity.parse(name) else { continue }
            if identity.generation < generation {
                // The generation in the physical xattr name is sufficient to retire stale logical
                // authority; do not read stale content just to discover it is obsolete.
                continue
            }
            guard identity.generation == generation else {
                throw AkashicError.invalidManifest
            }
            guard current.isEmpty else {
                // One physical blob is one logical partition/digest identity. Multiple current
                // create-authority xattrs on the same inode are therefore malformed.
                throw AkashicError.invalidManifest
            }
            let data = try readManifestXattr(
                name: name,
                descriptor: descriptor,
                maximumBytes: maximumManifestRecordBytes
            )
            let record: ManifestRecord
            do {
                record = try JSONDecoder().decode(ManifestRecord.self, from: data)
            } catch {
                throw AkashicError.invalidManifest
            }
            guard record.schemaVersion == ManifestRecord.currentSchemaVersion,
                record.generation == generation,
                record.sequence > 0,
                let entry = record.entry,
                entry.physicalID == physicalID,
                (record.persistedKey == nil || record.persistedKey == identity.key),
                isValidManifestEntryStatic(key: identity.key, entry: entry)
            else {
                throw AkashicError.invalidManifest
            }
            current.append(ManifestXattrRecord(key: identity.key, record: record))
        }
        return current
    }

    /// Strict physical-maintenance cleanup for schema3 payload-carried manifest authority after a
    /// schema4 snapshot has retired that generation. Normal schema4 bootstrap never calls this:
    /// scanning every live payload inode would reintroduce O(total blobs) recovery work. Explicit
    /// garbage collection already performs a full physical pass, so it is the correct surface for
    /// validating and retiring this legacy metadata debt.
    func removeLegacyManifestXattrsFromPublishedBlob(
        at url: URL,
        physicalID: PhysicalBlobID,
        staleBeforeGeneration: UInt64
    ) throws -> Int {
        guard staleBeforeGeneration > 1 else { return 0 }
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AkashicError.storageUnavailable }
        defer { _ = Darwin.close(descriptor) }
        _ = try StorageDirectorySecurity.validatedOpenedOwnedRegularFileStatus(descriptor)

        var removed = 0
        for name in try Self.manifestXattrNames(descriptor: descriptor) {
            guard let identity = try ManifestXattrIdentity.parse(name) else { continue }
            guard identity.generation < staleBeforeGeneration else {
                // Schema4 never writes payload-carried manifest authority. A current/future
                // manifest-family xattr is therefore not cleanup debt and must fail closed.
                throw AkashicError.invalidManifest
            }
            let data = try Self.readManifestXattr(
                name: name,
                descriptor: descriptor,
                maximumBytes: Self.maximumManifestRecordBytes
            )
            let record: ManifestRecord
            do {
                record = try JSONDecoder().decode(ManifestRecord.self, from: data)
            } catch {
                throw AkashicError.invalidManifest
            }
            guard record.schemaVersion == ManifestRecord.currentSchemaVersion,
                record.generation == identity.generation,
                record.sequence > 0,
                let entry = record.entry,
                entry.physicalID == physicalID,
                (record.persistedKey == nil || record.persistedKey == identity.key),
                Self.isValidManifestEntryStatic(key: identity.key, entry: entry)
            else {
                throw AkashicError.invalidManifest
            }

            let result = name.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
            if result != 0 {
                if errno == ENOATTR { continue }
                throw Self.currentManifestXattrPOSIXError()
            }
            removed += 1
        }

        guard removed > 0 else { return 0 }
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw Self.currentManifestXattrPOSIXError()
        }
        return removed
    }

    private static func manifestXattrNames(descriptor: Int32) throws -> [String] {
        // Current Akashic blobs carry at most one short manifest xattr plus ordinary filesystem
        // metadata. Avoid the usual size-query + second syscall on that common path, while keeping
        // a bounded ERANGE fallback for files with a larger unrelated xattr name set.
        let commonCapacity = 1_024
        var common = [CChar](repeating: 0, count: commonCapacity)
        let commonResult = common.withUnsafeMutableBufferPointer { pointer in
            Darwin.flistxattr(descriptor, pointer.baseAddress, pointer.count, 0)
        }
        if commonResult >= 0 {
            return decodeManifestXattrNames(common, byteCount: commonResult)
        }
        let commonError = POSIXErrorCode(rawValue: errno) ?? .EIO
        guard commonError == .ERANGE else { throw POSIXError(commonError) }

        let required = Darwin.flistxattr(descriptor, nil, 0, 0)
        guard required >= 0 else { throw currentManifestXattrPOSIXError() }
        guard required > 0 else { return [] }
        guard required <= 64 * 1_024 else { throw AkashicError.storageUnavailable }
        var expanded = [CChar](repeating: 0, count: required)
        let actual = expanded.withUnsafeMutableBufferPointer { pointer in
            Darwin.flistxattr(descriptor, pointer.baseAddress, pointer.count, 0)
        }
        guard actual == required else { throw currentManifestXattrPOSIXError() }
        return decodeManifestXattrNames(expanded, byteCount: actual)
    }

    private static func decodeManifestXattrNames(
        _ buffer: [CChar],
        byteCount: Int
    ) -> [String] {
        guard byteCount > 0 else { return [] }
        var names: [String] = []
        var start = 0
        for index in 0..<byteCount where buffer[index] == 0 {
            if index > start {
                let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
                names.append(String(decoding: bytes, as: UTF8.self))
            }
            start = index + 1
        }
        return names
    }

    private static func readManifestXattr(
        name: String,
        descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        let commonCapacity = min(512, maximumBytes)
        var common = Data(count: commonCapacity)
        let commonResult = common.withUnsafeMutableBytes { bytes in
            name.withCString { pointer in
                Darwin.fgetxattr(
                    descriptor,
                    pointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        if commonResult >= 0 {
            common.count = commonResult
            return common
        }
        let commonError = POSIXErrorCode(rawValue: errno) ?? .EIO
        guard commonError == .ERANGE else { throw POSIXError(commonError) }

        let required = name.withCString { pointer in
            Darwin.fgetxattr(descriptor, pointer, nil, 0, 0, 0)
        }
        guard required >= 0 else { throw currentManifestXattrPOSIXError() }
        guard required <= maximumBytes else { throw AkashicError.invalidManifest }
        var data = Data(count: required)
        let actual = try data.withUnsafeMutableBytes { bytes -> Int in
            let result = name.withCString { pointer in
                Darwin.fgetxattr(
                    descriptor,
                    pointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
            guard result >= 0 else { throw currentManifestXattrPOSIXError() }
            return result
        }
        guard actual == required else { throw AkashicError.invalidManifest }
        return data
    }

    private static func isValidManifestEntryStatic(key: String, entry: Entry) -> Bool {
        entry.byteCount >= 0
            && entry.byteCount <= maximumSupportedBlobBytes
            && entry.lastAccess.timeIntervalSinceReferenceDate.isFinite
            && entry.digest.byteCount == entry.byteCount
            && key
                == FileBlobStoreIdentity.manifestKey(
                    digest: entry.digest,
                    partition: entry.partition
                )
    }

    private static func currentManifestXattrPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
