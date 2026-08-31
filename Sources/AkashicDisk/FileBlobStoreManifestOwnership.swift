import AkashicCore
import Foundation

extension FileBlobStore {
    struct ManifestOwnershipIndex {
        var keyByPhysicalID: [PhysicalBlobID: String]
        var totalBytes: Int
    }

    struct ManifestOwnershipTransition {
        let key: String
        let oldEntry: Entry?
        let newEntry: Entry?
        let nextTotalBytes: Int
    }

    static func isValidManifestEntryCore(key: String, entry: Entry) -> Bool {
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

    static func validatedManifestOwnershipIndexCore(
        _ candidate: Manifest
    ) -> ManifestOwnershipIndex? {
        guard candidate.generation > 0,
            candidate.entries.count <= maximumManifestEntryCount
        else { return nil }

        var keyByPhysicalID: [PhysicalBlobID: String] = [:]
        keyByPhysicalID.reserveCapacity(candidate.entries.count)
        var totalBytes = 0
        for (key, entry) in candidate.entries {
            guard isValidManifestEntryCore(key: key, entry: entry),
                keyByPhysicalID.updateValue(key, forKey: entry.physicalID) == nil
            else { return nil }
            let addition = totalBytes.addingReportingOverflow(entry.byteCount)
            guard !addition.overflow else { return nil }
            totalBytes = addition.partialValue
        }
        return ManifestOwnershipIndex(
            keyByPhysicalID: keyByPhysicalID,
            totalBytes: totalBytes
        )
    }

    func validatedManifestOwnershipIndex(
        _ candidate: Manifest
    ) -> ManifestOwnershipIndex? {
        Self.validatedManifestOwnershipIndexCore(candidate)
    }

    func rebuildManifestResourceIndexes() throws {
        guard let rebuilt = validatedManifestOwnershipIndex(manifest) else {
            throw AkashicError.invalidManifest
        }
        manifestLiveByteCount = rebuilt.totalBytes
        if manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion {
            manifestOwnershipIndex = rebuilt
        } else {
            manifestOwnershipIndex = nil
        }
    }

    func validatedSchema4SingleKeyOwnershipTransition(
        key: String,
        newEntry: Entry?
    ) throws -> ManifestOwnershipTransition? {
        guard manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2
        else { return nil }
        guard let index = manifestOwnershipIndex else { return nil }

        let oldEntry = manifest.entries[key]
        guard oldEntry != newEntry else { return nil }
        if let oldEntry {
            guard index.keyByPhysicalID[oldEntry.physicalID] == key else {
                throw AkashicError.invalidManifest
            }
        }
        if let newEntry {
            guard isValidManifestEntry(key: key, entry: newEntry) else {
                throw AkashicError.storageUnavailable
            }
            if let owner = index.keyByPhysicalID[newEntry.physicalID], owner != key {
                throw AkashicError.storageUnavailable
            }
        }

        var nextCount = manifest.entries.count
        if oldEntry == nil, newEntry != nil {
            let count = nextCount.addingReportingOverflow(1)
            guard !count.overflow, count.partialValue <= Self.maximumManifestEntryCount else {
                throw AkashicError.storageUnavailable
            }
            nextCount = count.partialValue
        } else if oldEntry != nil, newEntry == nil {
            nextCount -= 1
        }
        guard nextCount >= 0, nextCount <= Self.maximumManifestEntryCount else {
            throw AkashicError.storageUnavailable
        }

        var nextTotalBytes = index.totalBytes
        if let oldEntry {
            let subtraction = nextTotalBytes.subtractingReportingOverflow(oldEntry.byteCount)
            guard !subtraction.overflow, subtraction.partialValue >= 0 else {
                throw AkashicError.invalidManifest
            }
            nextTotalBytes = subtraction.partialValue
        }
        if let newEntry {
            let addition = nextTotalBytes.addingReportingOverflow(newEntry.byteCount)
            guard !addition.overflow else { throw AkashicError.storageUnavailable }
            nextTotalBytes = addition.partialValue
        }
        return ManifestOwnershipTransition(
            key: key,
            oldEntry: oldEntry,
            newEntry: newEntry,
            nextTotalBytes: nextTotalBytes
        )
    }

    func adoptSchema4SingleKeyOwnershipTransition(
        _ transition: ManifestOwnershipTransition
    ) throws {
        guard manifestOwnershipIndex != nil else {
            throw AkashicError.invalidManifest
        }
        if let oldEntry = transition.oldEntry,
            transition.newEntry?.physicalID != oldEntry.physicalID
        {
            guard manifestOwnershipIndex!.keyByPhysicalID.removeValue(
                forKey: oldEntry.physicalID
            ) == transition.key else {
                throw AkashicError.invalidManifest
            }
        }
        if let newEntry = transition.newEntry {
            if let owner = manifestOwnershipIndex!.keyByPhysicalID[newEntry.physicalID],
                owner != transition.key
            {
                throw AkashicError.invalidManifest
            }
            manifestOwnershipIndex!.keyByPhysicalID[newEntry.physicalID] = transition.key
        }
        manifestOwnershipIndex!.totalBytes = transition.nextTotalBytes
        manifestLiveByteCount = transition.nextTotalBytes
    }
}
