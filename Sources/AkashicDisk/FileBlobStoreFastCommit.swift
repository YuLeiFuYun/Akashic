import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    /// 对最常见的单 blob 新建/替换执行紧凑增量事务。
    ///
    /// 支持 manifest xattr 的文件系统把正文与 create authority 放在同一临时 inode，
    /// 一次 file fsync 后用 UUID rename 同时发布两者；明确不支持该 xattr 表示时才回退
    /// 到旧双文件 sidecar transaction。两条路径都在 rename 后做 parent-directory fsync。
    /// rename 前 hard failure 保持 clean miss；rename 后目录同步失败属于“已可见但耐久性
    /// 未证明”的错误边界，调用方必须以 reopen/reconciliation 收敛而不能猜测旧状态。
    func commitFastPath(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID
    ) throws -> BlobPublication? {
        // Schema 4 has a different logical commit point (directory-head replacement). Until a
        // dedicated schema-4 fast transaction is proved, force it through stage -> publish so the
        // only current-generation authority is the directory-head protocol.
        guard manifest.schemaVersion != Self.directoryHeadManifestSchemaVersion else { return nil }
        guard pendingStages.count < Self.maximumManifestEntryCount,
            data.count <= limits.maximumBlobBytes
        else { throw AkashicError.storageUnavailable }
        guard FileBlobStoreIdentity.digestMatches(data: data, digest: digest) else {
            throw AkashicError.integrityMismatch
        }

        let key = FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
        guard !pendingStages.values.contains(where: { $0.key == key }) else { return nil }

        let existing = manifest.entries[key]
        if let existing, existing.partition == partition {
            let existingURL = blobURL(existing.physicalID)
            do {
                let existingData = try BoundedFileReader.read(
                    from: existingURL,
                    maximumBytes: existing.byteCount,
                    expectedBytes: existing.byteCount
                )
                if existingData.count == existing.byteCount,
                    FileBlobStoreIdentity.digestMatches(data: existingData, digest: digest)
                {
                    recordAccess(for: key, blobURL: existingURL)
                    return try BlobPublication(
                        physicalID: existing.physicalID,
                        byteCount: existing.byteCount,
                        disposition: .reused
                    )
                }
            } catch let error as POSIXError
                where !FileBlobStoreIdentity.isInvalidBlobPath(error.code)
            {
                throw AkashicError.storageUnavailable
            } catch let error as AkashicError where error == .notFound {
                throw error
            } catch {
                // 损坏或缺失的旧正文由新事务替换；旧清单在记录 rename 前仍保持权威。
            }
        }

        let recordURL = manifestRecordURL(for: key)
        let createsRecord = !manifestRecordKeys.contains(key)
        guard manifestRecordCount + (createsRecord ? 1 : 0) < Self.manifestCheckpointRecordLimit
        else { return nil }
        guard let xattrIdentity = ManifestXattrIdentity.make(
            generation: manifest.generation,
            key: key
        ) else {
            throw AkashicError.storageUnavailable
        }
        let sequence = manifestRecordSequence.addingReportingOverflow(1)
        guard !sequence.overflow else { return nil }
        repayManifestRecordCleanupDebtBestEffort()

        let physicalID = PhysicalBlobID()
        let destination = blobURL(physicalID)
        let entry = Entry(
            physicalID: physicalID,
            partition: partition,
            digest: digest,
            byteCount: data.count,
            lastAccess: Date()
        )
        let record = ManifestRecord(
            generation: manifest.generation,
            sequence: sequence.partialValue,
            key: key,
            entry: entry
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let recordData = try encoder.encode(record)
        guard recordData.count <= Self.maximumManifestRecordBytes else {
            throw AkashicError.storageUnavailable
        }

        // The sidecar fallback can expose two new direct children at once (payload + record).
        // Near the configured recovery scan ceiling, leave the fast path and let stage/publish use
        // the root-checkpoint fallback, which needs only the payload slot.
        guard canReserveBlobDirectoryEntries(2) else { return nil }
        let directoryReservation = try reserveBlobDirectoryEntries(2)
        var directoryReservationSettled = false
        defer {
            if !directoryReservationSettled {
                reconcileBlobDirectoryReservationAfterFailure(directoryReservation)
            }
        }

        let publishedWithXattr = try publishBlobWithManifestXattr(
            blobData: data,
            blobDestination: destination,
            recordData: recordData,
            xattrIdentity: xattrIdentity
        )
        if publishedWithXattr {
            settleBlobDirectoryReservation(directoryReservation, newEntryCount: 1)
            directoryReservationSettled = true
        } else {
            try publishBlobAndManifestRecord(
                blobData: data,
                blobDestination: destination,
                recordData: recordData,
                recordDestination: recordURL
            )
            settleBlobDirectoryReservation(
                directoryReservation,
                newEntryCount: createsRecord ? 2 : 1
            )
            directoryReservationSettled = true
        }
        try faultInjector(.afterManifestPublished)

        var next = manifest
        next.entries[key] = entry
        manifest = next
        manifestRecordSequence = sequence.partialValue
        if createsRecord { manifestRecordKeys.insert(key) }
        if let cached = manifestLiveByteCount {
            let previousByteCount = existing?.byteCount ?? 0
            let subtraction = cached.subtractingReportingOverflow(previousByteCount)
            if !subtraction.overflow, subtraction.partialValue >= 0 {
                let addition = subtraction.partialValue.addingReportingOverflow(data.count)
                manifestLiveByteCount = addition.overflow ? nil : addition.partialValue
            } else {
                manifestLiveByteCount = nil
            }
        }
        if let existing, existing.physicalID != physicalID {
            do {
                try removeFileIfPresent(blobURL(existing.physicalID))
            } catch {
                // The new authority is already committed, but the lower-sequence payload carrier
                // remains physically reachable. Seal the current logical state into a new
                // generation before this replacement is allowed to report success.
                try sealManifestAfterPhysicalCleanupDebt()
            }
        }
        // Primary authority and actor state now agree. End the provisional fast-publication state
        // before optional trim: if trim/checkpoint itself hits a post-rename error it must be able to
        // re-poison the actor without being cleared on the success return below.
        requiresReopenBeforeFurtherAccess = false
        try? trimIfNeeded()
        return try BlobPublication(
            physicalID: physicalID,
            byteCount: data.count,
            disposition: .created
        )
    }

    private func publishBlobWithManifestXattr(
        blobData: Data,
        blobDestination: URL,
        recordData: Data,
        xattrIdentity: ManifestXattrIdentity
    ) throws -> Bool {
        let temporary = blobs.appendingPathComponent(
            ".fast-xattr-blob-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        var descriptor: Int32 = -1
        var isOpen = false
        var renamed = false
        defer {
            if isOpen { _ = fastCommitOperations.close(descriptor) }
            if !renamed { try? FileManager.default.removeItem(at: temporary) }
        }

        descriptor = fastCommitOperations.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        isOpen = true
        try StorageDirectorySecurity.secureNewPrivateFile(
            temporary,
            descriptor: descriptor
        )
        try writeAll(blobData, descriptor: descriptor)
        try faultInjector(.afterBlobDataWritten)

        let xattrSupported = try Self.setManifestXattrIfSupported(
            recordData: recordData,
            identity: xattrIdentity,
            descriptor: descriptor,
            setOperation: fastCommitOperations.setManifestXattr
        )
        guard xattrSupported else {
            // No logical authority has been published. The caller may safely retry the same
            // transaction through the legacy sidecar fast path, but a close failure is not retried:
            // descriptor state is unknown after close(2) reports an error.
            let closeResult = fastCommitOperations.close(descriptor)
            isOpen = false
            guard closeResult == 0 else { throw currentPOSIXError() }
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        try faultInjector(.afterManifestDataWritten)

        // One inode fsync covers both raw blob bytes and its authority xattr.
        try synchronize(descriptor)
        try faultInjector(.afterBlobFileSynced)
        try faultInjector(.afterManifestFileSynced)
        let closeResult = fastCommitOperations.close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw currentPOSIXError() }

        // For the xattr fast path, publishing the UUID name also publishes manifest authority.
        try faultInjector(.beforeManifestPublished)
        guard fastCommitOperations.rename(temporary.path, blobDestination.path) == 0 else {
            throw currentPOSIXError()
        }
        renamed = true
        // From this point the UUID carrier itself publishes logical authority. Keep the actor
        // provisional until commitFastPath adopts the matching manifest/sequence state; any error
        // in between requires reopen before another operation may run.
        requiresReopenBeforeFurtherAccess = true
        try faultInjector(.afterBlobRenamed)
        try faultInjector(.afterBlobFilePublished)
        try faultInjector(.afterManifestRenamed)

        try synchronizeDirectory(blobs)
        try faultInjector(.afterBlobDirectorySynced)
        try faultInjector(.afterManifestDirectorySynced)
        return true
    }

    private func publishBlobAndManifestRecord(
        blobData: Data,
        blobDestination: URL,
        recordData: Data,
        recordDestination: URL
    ) throws {
        let blobTemporary = blobs.appendingPathComponent(
            ".fast-blob-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let recordTemporary = blobs.appendingPathComponent(
            ".fast-record-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        var blobRenamed = false
        var recordRenamed = false
        defer {
            try? FileManager.default.removeItem(at: blobTemporary)
            try? FileManager.default.removeItem(at: recordTemporary)
            if !recordRenamed, blobRenamed {
                try? FileManager.default.removeItem(at: blobDestination)
            }
        }

        try writeSynchronizedTemporary(
            blobData,
            to: blobTemporary,
            afterDataWritten: .afterBlobDataWritten,
            afterFileSynced: .afterBlobFileSynced
        )
        guard fastCommitOperations.rename(blobTemporary.path, blobDestination.path) == 0 else {
            throw currentPOSIXError()
        }
        blobRenamed = true
        try faultInjector(.afterBlobRenamed)
        try faultInjector(.afterBlobFilePublished)
        try faultInjector(.beforeManifestPublished)

        try writeSynchronizedTemporary(
            recordData,
            to: recordTemporary,
            afterDataWritten: .afterManifestDataWritten,
            afterFileSynced: .afterManifestFileSynced
        )
        guard fastCommitOperations.rename(recordTemporary.path, recordDestination.path) == 0 else {
            throw currentPOSIXError()
        }
        recordRenamed = true
        // The sidecar rename is the logical authority switch for this fallback transaction.
        requiresReopenBeforeFurtherAccess = true
        try faultInjector(.afterManifestRenamed)

        try synchronizeDirectory(blobs)
        try faultInjector(.afterBlobDirectorySynced)
        try faultInjector(.afterManifestDirectorySynced)
    }

    private func writeSynchronizedTemporary(
        _ data: Data,
        to temporary: URL,
        afterDataWritten: FileBlobStoreSwitchPoint,
        afterFileSynced: FileBlobStoreSwitchPoint
    ) throws {
        let descriptor = fastCommitOperations.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var isOpen = true
        do {
            try StorageDirectorySecurity.secureNewPrivateFile(
                temporary,
                descriptor: descriptor
            )
            try writeAll(data, descriptor: descriptor)
            try faultInjector(afterDataWritten)
            try synchronize(descriptor)
            try faultInjector(afterFileSynced)
            let closeResult = fastCommitOperations.close(descriptor)
            isOpen = false
            guard closeResult == 0 else { throw currentPOSIXError() }
        } catch {
            if isOpen { _ = fastCommitOperations.close(descriptor) }
            throw error
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = fastCommitOperations.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                written += result
            }
        }
    }

    private func synchronize(_ descriptor: Int32) throws {
        while true {
            if fastCommitOperations.synchronize(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = fastCommitOperations.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = fastCommitOperations.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        try synchronize(descriptor)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
