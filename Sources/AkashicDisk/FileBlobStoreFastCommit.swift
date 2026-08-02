import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    /// 对最常见的单 blob 新建/替换执行同目录双文件事务。
    ///
    /// blob 与其单 key 清单记录分别完成内容写入和文件 fsync，随后在同一私有目录
    /// 原子 rename，最后只执行一次目录 fsync。记录文件是逻辑可见性开关；任一中途
    /// 失败只留下可在 bootstrap 时清理的孤儿，绝不让未验证正文成为命中。
    func commitFastPath(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID
    ) throws -> BlobPublication? {
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

        let recordURL = blobs.appendingPathComponent(
            ".manifest-entry-\(key).json",
            isDirectory: false
        )
        let createsRecord = !FileManager.default.fileExists(atPath: recordURL.path)
        guard manifestRecordCount + (createsRecord ? 1 : 0) < Self.manifestCheckpointRecordLimit
        else { return nil }
        let sequence = manifestRecordSequence.addingReportingOverflow(1)
        guard !sequence.overflow else { return nil }

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

        try publishBlobAndManifestRecord(
            blobData: data,
            blobDestination: destination,
            recordData: recordData,
            recordDestination: recordURL
        )
        try faultInjector(.afterManifestPublished)

        var next = manifest
        next.entries[key] = entry
        manifest = next
        manifestRecordSequence = sequence.partialValue
        if createsRecord { manifestRecordCount += 1 }
        if let existing, existing.physicalID != physicalID {
            try? FileManager.default.removeItem(at: blobURL(existing.physicalID))
        }
        try? trimIfNeeded()
        return try BlobPublication(
            physicalID: physicalID,
            byteCount: data.count,
            disposition: .created
        )
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
        guard Darwin.rename(blobTemporary.path, blobDestination.path) == 0 else {
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
        guard Darwin.rename(recordTemporary.path, recordDestination.path) == 0 else {
            throw currentPOSIXError()
        }
        recordRenamed = true
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
        let descriptor = Darwin.open(
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
            guard Darwin.close(descriptor) == 0 else { throw currentPOSIXError() }
            isOpen = false
        } catch {
            if isOpen { _ = Darwin.close(descriptor) }
            throw error
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
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
            if Darwin.fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(descriptor) }
        try StorageDirectorySecurity.validateOpenedDirectory(descriptor)
        try synchronize(descriptor)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
