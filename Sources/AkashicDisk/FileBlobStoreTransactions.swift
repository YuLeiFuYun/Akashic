import AkashicCore
import Foundation

extension FileBlobStore {
    /// 读取并验证一个 partition blob，同时隔离损坏条目。
    public func read(digest: BlobDigest, partition: CachePartitionID) async throws -> Data {
        try ensureUsableStoreState()
        let key = FileBlobStoreIdentity.manifestKey(
            digest: digest, partition: partition)
        var replacementRetryCount = 0
        while true {
            guard let entry = manifest.entries[key], entry.partition == partition
            else {
                throw AkashicError.notFound
            }
            let url = blobURL(entry.physicalID)
            let readResult: BoundedFileReadResult
            do {
                readResult = try await readIO.readVerifiedForStore(
                    from: url,
                    maximumBytes: entry.byteCount,
                    expectedBytes: entry.byteCount,
                    digest: digest
                )
            } catch {
                if error is CancellationError { throw error }
                try ensureUsableStoreState()
                let current = manifest.entries[key]
                if current?.physicalID != entry.physicalID || current?.partition != partition {
                    guard current?.partition == partition else { throw AkashicError.notFound }
                    guard replacementRetryCount == 0 else {
                        throw AkashicError.storageUnavailable
                    }
                    replacementRetryCount += 1
                    continue
                }
                if error is FileBlobStoreReadSchedulingError {
                    // Scheduler capacity is an availability/resource outcome, not evidence that the
                    // still-current physical carrier is corrupt. Never let queue pressure revoke
                    // logical authority.
                    throw AkashicError.storageUnavailable
                }
                if let posixError = error as? POSIXError,
                    FileBlobStoreIdentity.isInvalidBlobPath(posixError.code)
                {
                    try quarantineEntry(key: key, blobURL: url)
                    throw AkashicError.integrityMismatch
                }
                if error is AkashicError {
                    try quarantineEntry(key: key, blobURL: url)
                    throw AkashicError.integrityMismatch
                }
                throw AkashicError.storageUnavailable
            }
            try ensureUsableStoreState()
            if let current = manifest.entries[key],
                current.physicalID == entry.physicalID,
                current.partition == partition
            {
                recordAccess(
                    for: key,
                    blobURL: url,
                    persistedModificationDate: readResult.modificationDate
                )
            }
            return readResult.data
        }
    }

    /// 原子发布已验证字节，并在安全时修复原有损坏数据块。
    @discardableResult
    public func commit(data: Data, digest: BlobDigest, partition: CachePartitionID) throws -> BlobPublication {
        try ensureUsableStoreState()
        if let publication = try commitFastPath(
            data: data,
            digest: digest,
            partition: partition
        ) {
            return publication
        }
        let deferDirectorySync: Bool
        if manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion {
            let key = FileBlobStoreIdentity.manifestKey(
                digest: digest,
                partition: partition
            )
            deferDirectorySync = try canCoalesceDirectoryHeadCommit(key: key)
        } else {
            deferDirectorySync = false
        }
        let stage = try stage(
            data: data,
            digest: digest,
            partition: partition,
            deferDirectorySync: deferDirectorySync
        )
        defer { discard(stage) }
        return try publish(stage)
    }

    /// 写入尚未进入逻辑清单的耐久数据块；此时 `read` 与 `physicalID` 不可观察它。
    public func stage(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID
    ) throws -> BlobStage {
        try stage(
            data: data,
            digest: digest,
            partition: partition,
            deferDirectorySync: false
        )
    }

    private func stage(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID,
        deferDirectorySync: Bool
    ) throws -> BlobStage {
        try ensureUsableStoreState()
        guard pendingStages.count < Self.maximumManifestEntryCount,
            data.count <= limits.maximumBlobBytes
        else { throw AkashicError.storageUnavailable }
        guard FileBlobStoreIdentity.digestMatches(data: data, digest: digest) else {
            throw AkashicError.integrityMismatch
        }

        let key = FileBlobStoreIdentity.manifestKey(
            digest: digest,
            partition: partition
        )
        let existing = manifest.entries[key]
        if let inFlight = pendingStages.values.first(where: { pending in
            guard pending.key == key,
                pending.partition == partition,
                pending.digest == digest,
                pending.byteCount == data.count,
                FileManager.default.fileExists(atPath: blobURL(pending.physicalID).path)
            else { return false }
            if pending.createdFile { return true }
            // A reuse stage is only an observation of current authority, not an owned unpublished
            // carrier. Once that authority changes, the stale token must not poison later staging
            // by being cloned into another reuse-only stage that can never publish successfully.
            guard let current = existing else { return false }
            return current.physicalID == pending.physicalID
                && current.partition == pending.partition
                && current.digest == pending.digest
                && current.byteCount == pending.byteCount
        }) {
            let token = BlobStage()
            pendingStages[token.rawValue] = inFlight
            return token
        }
        if let existing, existing.partition == partition {
            let existingURL = blobURL(existing.physicalID)
            do {
                let existingData = try BoundedFileReader.read(
                    from: existingURL,
                    maximumBytes: existing.byteCount,
                    expectedBytes: existing.byteCount
                )
                if existingData.count == existing.byteCount,
                    FileBlobStoreIdentity.digestMatches(
                        data: existingData,
                        digest: digest
                    )
                {
                    let token = BlobStage()
                    pendingStages[token.rawValue] = PendingStage(
                        key: key,
                        physicalID: existing.physicalID,
                        partition: partition,
                        digest: digest,
                        byteCount: existing.byteCount,
                        existing: existing,
                        createdFile: false
                    )
                    return token
                }
            } catch let error as POSIXError
                where !FileBlobStoreIdentity.isInvalidBlobPath(error.code)
            {
                throw AkashicError.storageUnavailable
            } catch let error as AkashicError where error == .notFound {
                throw error
            } catch {
                // 已发布条目损坏。新阶段在 publish 前仍保持不可见，成功后原子替换。
            }
        }

        let physicalID = PhysicalBlobID()
        let destination = blobURL(physicalID)
        let directoryReservation = try reserveBlobDirectoryEntries(1)
        do {
            let writerFaults: DurableFileWriteFaultInjector = { point in
                switch point {
                case .afterDataWritten:
                    try self.faultInjector(.afterBlobDataWritten)
                case .afterFileSynced:
                    try self.faultInjector(.afterBlobFileSynced)
                case .afterRename:
                    try self.faultInjector(.afterBlobRenamed)
                case .afterDirectorySynced:
                    try self.faultInjector(.afterBlobDirectorySynced)
                }
            }
            if deferDirectorySync {
                try DurableFileWriter.writeReplacingDeferringDirectorySync(
                    data,
                    to: destination,
                    faultInjector: writerFaults
                )
            } else {
                try DurableFileWriter.writeReplacing(
                    data,
                    to: destination,
                    faultInjector: writerFaults
                )
            }
            // DurableFileWriter 已在同一 inode 上设置保护属性并完成 rename；此处只复核
            // 发布路径仍指向该私有普通文件，避免重复 xattr/chmod 写入放大每次提交成本。
            try StorageDirectorySecurity.validateRegularFile(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            reconcileBlobDirectoryReservationAfterFailure(directoryReservation)
            throw error
        }
        settleBlobDirectoryReservation(directoryReservation, newEntryCount: 1)
        try faultInjector(.afterBlobFilePublished)

        let token = BlobStage()
        pendingStages[token.rawValue] = PendingStage(
            key: key,
            physicalID: physicalID,
            partition: partition,
            digest: digest,
            byteCount: data.count,
            existing: existing,
            createdFile: true
        )
        return token
    }

    /// 将一个已写入的阶段原子加入逻辑清单。
    public func publish(_ stage: BlobStage) throws -> BlobPublication {
        try ensureUsableStoreState()
        guard let pending = pendingStages[stage.rawValue] else {
            throw AkashicError.transactionConflict
        }
        if let published = manifest.entries[pending.key],
            published.physicalID == pending.physicalID,
            published.partition == pending.partition,
            published.digest == pending.digest,
            published.byteCount == pending.byteCount
        {
            pendingStages.removeValue(forKey: stage.rawValue)
            recordAccess(for: pending.key, blobURL: blobURL(pending.physicalID))
            return try BlobPublication(
                physicalID: pending.physicalID,
                byteCount: pending.byteCount,
                disposition: .reused
            )
        }
        if !pending.createdFile {
            // A reuse stage owns no new physical carrier: it is valid only while the exact
            // PhysicalBlobID observed by `stage` remains current authority. Trim, quarantine, or a
            // same-key repair may retire that authority before `publish`; reporting `.reused` after
            // such a transition would hand the caller a stale/non-authoritative physical identity.
            pendingStages.removeValue(forKey: stage.rawValue)
            throw AkashicError.transactionConflict
        }

        let destination = blobURL(pending.physicalID)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AkashicError.storageUnavailable
        }
        let nextEntry = Entry(
            physicalID: pending.physicalID,
            partition: pending.partition,
            digest: pending.digest,
            byteCount: pending.byteCount,
            lastAccess: Date()
        )
        try faultInjector(.beforeManifestPublished)
        let persistedManifest = try persistSingleKeyManifestEntry(
            key: pending.key,
            entry: nextEntry
        )
        do {
            try faultInjector(.afterManifestPublished)
        } catch {
            // Disk authority is already durable/visible but this actor has not adopted it. Freeze
            // the instance so a later mutation cannot reuse sequence/generation state.
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        manifest = persistedManifest
        pendingStages.removeValue(forKey: stage.rawValue)
        if let existing = pending.existing, existing.physicalID != pending.physicalID {
            do {
                try removeFileIfPresent(blobURL(existing.physicalID))
            } catch {
                try sealManifestAfterPhysicalCleanupDebt()
            }
        }
        try? trimIfNeeded()
        return try BlobPublication(
            physicalID: pending.physicalID,
            byteCount: pending.byteCount,
            disposition: .created
        )
    }

    /// 丢弃一个尚未发布的阶段；重复或迟到丢弃是幂等的。
    public func discard(_ stage: BlobStage) {
        // After an authority-publication error, a process-visible sidecar/snapshot may already
        // reference this staged blob even though the actor did not adopt that state. Reopen owns
        // reconciliation; unlinking here could turn recoverable authority into data loss.
        guard !requiresReopenBeforeFurtherAccess else { return }
        guard let pending = pendingStages.removeValue(forKey: stage.rawValue),
            pending.createdFile
        else { return }
        let remainsPending = pendingStages.values.contains { candidate in
            candidate.createdFile && candidate.physicalID == pending.physicalID
        }
        let isPublished = manifest.entries.values.contains { entry in
            entry.physicalID == pending.physicalID
        }
        guard !remainsPending, !isPublished else { return }
        _ = try? removeBlobDirectoryEntryIfPresent(blobURL(pending.physicalID))
    }
}
