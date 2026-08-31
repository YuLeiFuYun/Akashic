import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    /// 删除所有未被指定活动引用保留的物理数据块。
    public func garbageCollect(
        retaining references: Set<LiveBlobReference>,
        limits: BlobMaintenanceLimits
    ) async throws -> BlobMaintenanceResult {
        try ensureUsableStoreState()
        try limits.validate(references)
        let victims = manifest.entries.filter { _, entry in
            !references.contains(
                LiveBlobReference(
                    partition: entry.partition,
                    digest: entry.digest
                )
            )
        }
        guard !victims.isEmpty else {
            do {
                let removed = try removeUnreferencedBlobFiles()
                return try BlobMaintenanceResult(
                    removedBlobCount: removed.fileCount,
                    removedByteCount: removed.byteCount
                )
            } catch {
                // Garbage collection is the explicit physical-maintenance surface. Unlike logical
                // remove, failure to repay physical debt remains an observable maintenance error.
                throw AkashicError.storageUnavailable
            }
        }

        var next = manifest
        for key in victims.keys { next.entries.removeValue(forKey: key) }
        manifest = try persistManifest(next)
        for key in victims.keys { runtimeLastAccess.removeValue(forKey: key) }

        var firstError: (any Error)?
        var removed = BlobPhysicalRemovalSummary()
        for entry in victims.values {
            do {
                if try removeBlobDirectoryEntryIfPresent(blobURL(entry.physicalID)) {
                    removed.record(byteCount: entry.byteCount)
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                firstError = firstError ?? error
            }
        }
        do {
            removed.merge(try removeUnreferencedBlobFiles())
        } catch {
            firstError = firstError ?? error
        }
        if firstError != nil {
            // Logical GC authority is already committed. If any payload carrier could not be
            // retired, seal the final logical state before surfacing the physical-maintenance
            // failure so a later missing delta carrier cannot roll recovery backward.
            try sealManifestAfterPhysicalCleanupDebt()
            throw AkashicError.storageUnavailable
        }
        return try BlobMaintenanceResult(
            removedBlobCount: removed.fileCount,
            removedByteCount: removed.byteCount
        )
    }

    /// 返回活动 partition/digest 对应的不透明物理定位符。
    public func physicalID(digest: BlobDigest, partition: CachePartitionID) -> PhysicalBlobID? {
        guard !requiresReopenBeforeFurtherAccess else { return nil }
        let entry = manifest.entries[
            FileBlobStoreIdentity.manifestKey(
                digest: digest, partition: partition)
        ]
        return entry?.partition == partition ? entry?.physicalID : nil
    }

    /// 先删除一个逻辑条目，再删除其物理数据块。
    public func remove(digest: BlobDigest, partition: CachePartitionID) throws {
        try ensureUsableStoreState()
        let key = FileBlobStoreIdentity.manifestKey(
            digest: digest, partition: partition)
        discardPendingStages { $0.key == key }
        guard let entry = manifest.entries[key] else { return }

        manifest = try persistSingleKeyManifestEntry(key: key, entry: nil)
        runtimeLastAccess.removeValue(forKey: key)
        // Logical authority is terminal once the tombstone/manifest mutation is durable. Physical
        // unlink is cleanup, not rollback. If cleanup fails, however, schema 3 must seal the final
        // miss into the next snapshot generation before reporting success; otherwise loss of the
        // tombstone could expose the lower-sequence create carrier still attached to this payload.
        do {
            try removeFileIfPresent(blobURL(entry.physicalID))
        } catch {
            try sealManifestAfterPhysicalCleanupDebt()
        }
    }

    /// 删除某 partition 拥有的全部逻辑与物理条目。
    public func removeAll(partition: CachePartitionID) throws {
        try ensureUsableStoreState()
        discardPendingStages { $0.partition == partition }
        let victims = manifest.entries.filter {
            $0.value.partition == partition
        }
        guard !victims.isEmpty else { return }

        var next = manifest
        for key in victims.keys { next.entries.removeValue(forKey: key) }
        manifest = try persistManifest(next)
        for key in victims.keys { runtimeLastAccess.removeValue(forKey: key) }

        var cleanupDebtObserved = false
        for entry in victims.values {
            // Partition revocation is a logical-authority operation. A failed payload unlink must
            // not turn an already-committed revoke into an apparent rollback; strict physical debt
            // repayment remains available through garbageCollect.
            do {
                try removeFileIfPresent(blobURL(entry.physicalID))
            } catch {
                cleanupDebtObserved = true
            }
        }
        if cleanupDebtObserved {
            try sealManifestAfterPhysicalCleanupDebt()
        }
    }

    func quarantineEntry(key: String, blobURL: URL) throws {
        do {
            manifest = try persistSingleKeyManifestEntry(key: key, entry: nil)
        } catch {
            throw AkashicError.storageUnavailable
        }
        runtimeLastAccess.removeValue(forKey: key)
        do {
            try removeFileIfPresent(blobURL)
        } catch {
            try sealManifestAfterPhysicalCleanupDebt()
        }
    }

    func removeFileIfPresent(_ url: URL) throws {
        _ = try removeBlobDirectoryEntryIfPresent(url)
    }

    func reconcileStorageAfterBootstrap() throws {
        let fileManager = FileManager.default
        try removeManifestTemporaryFiles()
        // Unreferenced payloads have no logical authority. An external filesystem condition can
        // make physical deletion temporarily impossible (for example UF_IMMUTABLE); that resource
        // debt must not make an otherwise valid manifest unreadable. Explicit GC remains strict.
        _ = try removeUnreferencedBlobFiles(allowRemovalDebt: true)

        var next = manifest
        var obsoleteBlobURLs: [URL] = []
        for (key, entry) in manifest.entries {
            let url = blobURL(entry.physicalID)
            guard fileManager.fileExists(atPath: url.path) else {
                next.entries.removeValue(forKey: key)
                continue
            }
            guard entry.byteCount <= limits.maximumBlobBytes else {
                next.entries.removeValue(forKey: key)
                obsoleteBlobURLs.append(url)
                continue
            }
            try StorageDirectorySecurity.validateOrRepairPublishedFilePermissions(url)
        }
        if next.entries != manifest.entries {
            manifest = try persistManifest(next)
            for url in obsoleteBlobURLs {
                try? fileManager.removeItem(at: url)
            }
        }
    }


    func removeManifestTemporaryFiles() throws {
        let root = manifestURL.deletingLastPathComponent()
        for url in try boundedChildren(at: root, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(".durable-tmp-") {
            try FileManager.default.removeItem(at: url)
        }
    }

    func boundedChildren(
        at directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?
    ) throws -> [URL] {
        try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: limits.maximumDirectoryEntryCount
        ).map { name in
            directory.appendingPathComponent(name, isDirectory: false)
        }
    }

    func removeUnreferencedBlobFiles(
        allowRemovalDebt: Bool = false
    ) throws -> BlobPhysicalRemovalSummary {
        let files = try boundedChildren(
            at: blobs,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )
        try resetBlobDirectoryEntryCount(files.count)
        let livePhysicalIDsByName = Dictionary(
            uniqueKeysWithValues: manifest.entries.values.map { entry in
                (entry.physicalID.rawValue.uuidString.lowercased(), entry.physicalID)
            }
        )
        let referencedNames = Set(
            livePhysicalIDsByName.keys
                + pendingStages.values.filter(\.createdFile).map {
                    $0.physicalID.rawValue.uuidString.lowercased()
                }
        )
        var removed = BlobPhysicalRemovalSummary()
        var knownLegacyRecordDebt = Set(staleManifestRecordCleanupQueue)
        for file in files {
            let name = file.lastPathComponent
            if isManifestRecordName(name) {
                // Schema4 never publishes sidecar manifest records. Any valid sidecar-shaped file
                // is therefore legacy schema2/3 metadata, never current logical authority.
                guard manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion else {
                    continue
                }
                do {
                    try validateLegacyManifestRecordCleanupCandidate(
                        file,
                        staleBeforeGeneration: manifest.generation
                    )
                } catch let error as POSIXError where error.code == .ENOENT {
                    continue
                } catch {
                    // Bootstrap is not allowed to delete or adopt a foreign/corrupt lookalike.
                    // Explicit GC is the strict maintenance surface and reports it.
                    if allowRemovalDebt { continue }
                    throw AkashicError.storageUnavailable
                }
                if allowRemovalDebt {
                    if knownLegacyRecordDebt.insert(file).inserted {
                        staleManifestRecordCleanupQueue.append(file)
                    }
                    continue
                }
                do {
                    _ = try removeBlobDirectoryEntryIfPresent(file)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                } catch {
                    throw AkashicError.storageUnavailable
                }
                continue
            }
            if let physicalID = livePhysicalIDsByName[name] {
                if manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
                    !allowRemovalDebt
                {
                    do {
                        _ = try removeLegacyManifestXattrsFromPublishedBlob(
                            at: file,
                            physicalID: physicalID,
                            staleBeforeGeneration: manifest.generation
                        )
                    } catch {
                        // Schema4 no longer interprets payload xattrs as logical authority, but
                        // explicit GC is the strict physical-maintenance surface. Corrupt foreign
                        // lookalikes or inability to durably retire valid legacy metadata remain
                        // observable instead of being silently grandfathered forever.
                        throw AkashicError.storageUnavailable
                    }
                }
                continue
            }
            guard name.hasPrefix(".tmp-") || name.hasPrefix(".durable-tmp-")
                || !referencedNames.contains(name)
            else { continue }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            do {
                _ = try removeBlobDirectoryEntryIfPresent(file)
            } catch {
                if allowRemovalDebt,
                    let uuid = UUID(uuidString: name),
                    uuid.uuidString.lowercased() == name
                {
                    do {
                        try StorageDirectorySecurity.validateRegularFile(file)
                        continue
                    } catch let validationError as POSIXError where validationError.code == .ENOENT {
                        // The orphan disappeared after the failed unlink but before validation.
                        // Treat the cleanup debt as already repaid rather than failing bootstrap.
                        continue
                    } catch {
                        throw AkashicError.storageUnavailable
                    }
                }
                throw AkashicError.storageUnavailable
            }
            if values?.isRegularFile == true {
                removed.record(byteCount: values?.fileSize ?? 0)
            }
        }
        if !allowRemovalDebt,
            manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion
        {
            // A successful strict pass has either removed every valid legacy sidecar or failed on
            // an unsafe lookalike. Any queued URLs are therefore already physically absent.
            staleManifestRecordCleanupQueue.removeAll(keepingCapacity: true)
        }
        return removed
    }

    func discardPendingStages(
        where shouldDiscard: (PendingStage) -> Bool
    ) {
        let identifiers = pendingStages.compactMap { identifier, pending in
            shouldDiscard(pending) ? identifier : nil
        }
        for identifier in identifiers {
            discard(BlobStage(rawValue: identifier))
        }
    }

    func trimIfNeeded() throws {
        var total: Int
        if let cached = manifestLiveByteCount {
            total = cached
        } else {
            total = manifest.entries.values.reduce(0) { $0 + $1.byteCount }
            manifestLiveByteCount = total
        }
        guard total > limits.softTotalBytes else { return }

        let entriesByLastAccess = manifest.entries.map { key, entry in
            (key: key, entry: entry, lastAccess: effectiveLastAccess(for: key, entry: entry))
        }.sorted { lhs, rhs in
            if lhs.lastAccess == rhs.lastAccess { return lhs.key < rhs.key }
            return lhs.lastAccess < rhs.lastAccess
        }

        var next = manifest
        var victims: [(key: String, entry: Entry)] = []
        for item in entriesByLastAccess {
            let key = item.key
            let entry = item.entry
            next.entries.removeValue(forKey: key)
            victims.append((key, entry))
            total -= entry.byteCount
            if total <= limits.softTotalBytes { break }
        }
        manifest = try persistManifest(next)
        manifestLiveByteCount = total
        var cleanupDebtObserved = false
        for victim in victims {
            runtimeLastAccess.removeValue(forKey: victim.key)
            do {
                try removeFileIfPresent(blobURL(victim.entry.physicalID))
            } catch {
                cleanupDebtObserved = true
            }
        }
        if cleanupDebtObserved {
            try sealManifestAfterPhysicalCleanupDebt()
        }
    }

    func isValidManifestEntry(key: String, entry: Entry) -> Bool {
        Self.isValidManifestEntryCore(key: key, entry: entry)
    }

    func isValidManifestEntriesAndOwnership(_ manifest: Manifest) -> Bool {
        validatedManifestOwnershipIndex(manifest) != nil
    }

    func isValidManifest(_ manifest: Manifest) -> Bool {
        switch manifest.schemaVersion {
        case Self.currentSchemaVersion:
            guard manifest.deltaCarrierProfile == nil else { return false }
        case Self.directoryHeadManifestSchemaVersion:
            guard manifest.deltaCarrierProfile == .directoryHeadV2 else { return false }
        default:
            return false
        }
        return isValidManifestEntriesAndOwnership(manifest)
    }

    func recordAccess(
        for key: String,
        blobURL: URL,
        persistedModificationDate: Date? = nil
    ) {
        // mtime 只承担跨进程近似最近性；运行时字典保留精确顺序。读取路径已经验证过
        // 同一 inode 时把观察到的 mtime 一并传入，常见的五分钟窗口内无需再次 open/fstat。
        runtimeLastAccess[key] = BlobAccessJournal.recordAccess(
            at: blobURL,
            persistedModificationDate: persistedModificationDate
        )
    }

    func ensureUsableStoreState() throws {
        guard !requiresReopenBeforeFurtherAccess else {
            throw AkashicError.storageUnavailable
        }
    }

    func effectiveLastAccess(for key: String, entry: Entry) -> Date {
        var latest = entry.lastAccess
        if let runtime = runtimeLastAccess[key], runtime > latest { latest = runtime }
        if let modificationDate = ManagedFileMetadata.modificationDate(
            at: blobURL(entry.physicalID)),
            modificationDate > latest
        {
            latest = modificationDate
        }
        return latest
    }

    func blobURL(_ id: PhysicalBlobID) -> URL {
        blobs.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
    }
}
