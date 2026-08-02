import AkashicCore
import Foundation

/// 按不透明 partition 隔离、由清单索引的已验证通用 blob 存储。
public actor FileBlobStore: BlobStoreMaintaining, TransactionalBlobStoring {
    private nonisolated let ioExecutor = BlockingIOExecutor(
        label: "dev.akashic.file-blob-store")
    /// 用于把阻塞文件系统工作移出协作式执行器的专用串行执行器。
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }
    /// 此实现接受并写出的清单模式版本。
    public static let currentSchemaVersion: UInt16 = 2
    static let legacyManifestSchemaVersion: UInt16 = 1
    static let maximumManifestBytes = 64 * 1024 * 1024
    static let maximumManifestRecordBytes = 16 * 1024
    static let manifestCheckpointRecordLimit = 512
    static let maximumManifestEntryCount = 100_000
    static let maximumSupportedBlobBytes = 1024 * 1024 * 1024
    private static let writerLeaseAcquirer = StoreWriterLeaseAcquirer()

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: UInt16
    }

    struct LegacyManifest: Codable {
        let schemaVersion: UInt16
        var entries: [String: Entry]
    }

    struct Manifest: Codable {
        let schemaVersion: UInt16
        let generation: UInt64
        var entries: [String: Entry]

        init(
            schemaVersion: UInt16 = FileBlobStore.currentSchemaVersion,
            generation: UInt64 = 1,
            entries: [String: Entry] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.generation = generation
            self.entries = entries
        }
    }

    struct ManifestRecord: Codable {
        static let currentSchemaVersion: UInt16 = 1
        let schemaVersion: UInt16
        let generation: UInt64
        let sequence: UInt64
        let key: String
        let entry: Entry?

        init(generation: UInt64, sequence: UInt64, key: String, entry: Entry?) {
            self.schemaVersion = Self.currentSchemaVersion
            self.generation = generation
            self.sequence = sequence
            self.key = key
            self.entry = entry
        }
    }

    struct Entry: Codable, Equatable {
        let physicalID: PhysicalBlobID
        let partition: CachePartitionID
        let digest: BlobDigest
        let byteCount: Int
        let lastAccess: Date
    }

    struct PendingStage {
        let key: String
        let physicalID: PhysicalBlobID
        let partition: CachePartitionID
        let digest: BlobDigest
        let byteCount: Int
        let existing: Entry?
        let createdFile: Bool
    }

    let blobs: URL
    let manifestURL: URL
    let limits: FileBlobStoreLimits
    private let writerLease: StoreWriterLease
    let faultInjector: FileBlobStoreFaultInjector
    var manifest: Manifest
    var manifestRecordSequence: UInt64 = 0
    var manifestRecordCount: Int = 0
    var runtimeLastAccess: [String: Date] = [:]
    var pendingStages: [UUID: PendingStage] = [:]

    private init(
        root: URL,
        limits: FileBlobStoreLimits,
        writerLease: consuming StoreWriterLease,
        faultInjector: @escaping FileBlobStoreFaultInjector
    ) {
        self.blobs = root.appendingPathComponent("blobs", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json")
        self.limits = limits
        self.writerLease = writerLease
        self.faultInjector = faultInjector
        self.manifest = Manifest()
    }

    /// 打开、验证、校准并裁剪 partition 隔离的 blob 存储。
    public static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits()
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: { _ in }
        )
    }

    package static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector
    ) async throws -> FileBlobStore {
        let writerLease = try await writerLeaseAcquirer.acquire(root: root)
        let store = FileBlobStore(
            root: root,
            limits: limits,
            writerLease: writerLease,
            faultInjector: faultInjector
        )
        try await store.bootstrap(root: root)
        return store
    }

    /// 打开单数据块上限与总软上限共享同一字节预算的存储。
    public static func open(
        root: URL,
        softLimitBytes: Int
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: softLimitBytes,
                maximumBlobBytes: softLimitBytes
            )
        )
    }

    private func bootstrap(root: URL) throws {
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(blobs)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try BoundedFileReader.read(
                from: manifestURL,
                maximumBytes: Self.maximumManifestBytes
            )
            guard let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data)
            else { throw AkashicError.invalidManifest }
            switch envelope.schemaVersion {
            case Self.legacyManifestSchemaVersion:
                let legacy = try JSONDecoder().decode(LegacyManifest.self, from: data)
                let migrated = Manifest(entries: legacy.entries)
                guard isValidManifest(migrated) else {
                    throw AkashicError.invalidManifest
                }
                try persistManifestSnapshot(migrated, injectFaults: false)
                manifest = migrated
            case Self.currentSchemaVersion:
                let decoded = try JSONDecoder().decode(Manifest.self, from: data)
                guard isValidManifest(decoded) else {
                    throw AkashicError.invalidManifest
                }
                manifest = decoded
                try replayManifestRecords()
            default:
                throw AkashicError.unsupportedSchema
            }
        } else {
            let initial = Manifest()
            try persistManifestSnapshot(initial, injectFaults: false)
            manifest = initial
        }
        try reconcileStorageAfterBootstrap()
        try trimIfNeeded()
    }

    /// 读取并验证一个 partition blob，同时隔离损坏条目。
    public func read(digest: BlobDigest, partition: CachePartitionID) throws -> Data {
        let key = FileBlobStoreIdentity.manifestKey(
            digest: digest, partition: partition)
        guard let entry = manifest.entries[key], entry.partition == partition
        else {
            throw AkashicError.notFound
        }
        let url = blobURL(entry.physicalID)
        let data: Data
        do {
            data = try BoundedFileReader.read(
                from: url,
                maximumBytes: entry.byteCount,
                expectedBytes: entry.byteCount
            )
        } catch let error as POSIXError
            where FileBlobStoreIdentity.isInvalidBlobPath(error.code)
        {
            try quarantineEntry(key: key, blobURL: url)
            throw AkashicError.integrityMismatch
        } catch is AkashicError {
            try quarantineEntry(key: key, blobURL: url)
            throw AkashicError.integrityMismatch
        } catch {
            throw AkashicError.storageUnavailable
        }
        guard data.count == entry.byteCount,
            FileBlobStoreIdentity.digestMatches(data: data, digest: digest)
        else {
            try quarantineEntry(key: key, blobURL: url)
            throw AkashicError.integrityMismatch
        }
        recordAccess(for: key, blobURL: url)
        return data
    }

    /// 原子发布已验证字节，并在安全时修复原有损坏数据块。
    @discardableResult
    public func commit(data: Data, digest: BlobDigest, partition: CachePartitionID) throws -> BlobPublication {
        if let publication = try commitFastPath(
            data: data,
            digest: digest,
            partition: partition
        ) {
            return publication
        }
        let stage = try stage(data: data, digest: digest, partition: partition)
        defer { discard(stage) }
        return try publish(stage)
    }

    /// 写入尚未进入逻辑清单的耐久数据块；此时 `read` 与 `physicalID` 不可观察它。
    public func stage(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID
    ) throws -> BlobStage {
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
            pending.key == key
                && pending.partition == partition
                && pending.digest == digest
                && pending.byteCount == data.count
                && FileManager.default.fileExists(atPath: blobURL(pending.physicalID).path)
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
        do {
            try DurableFileWriter.writeReplacing(
                data,
                to: destination,
                faultInjector: { point in
                    switch point {
                    case .afterDataWritten:
                        try faultInjector(.afterBlobDataWritten)
                    case .afterFileSynced:
                        try faultInjector(.afterBlobFileSynced)
                    case .afterRename:
                        try faultInjector(.afterBlobRenamed)
                    case .afterDirectorySynced:
                        try faultInjector(.afterBlobDirectorySynced)
                    }
                }
            )
            // DurableFileWriter 已在同一 inode 上设置保护属性并完成 rename；此处只复核
            // 发布路径仍指向该私有普通文件，避免重复 xattr/chmod 写入放大每次提交成本。
            try StorageDirectorySecurity.validateRegularFile(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
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
            pendingStages.removeValue(forKey: stage.rawValue)
            recordAccess(for: pending.key, blobURL: blobURL(pending.physicalID))
            return try BlobPublication(
                physicalID: pending.physicalID,
                byteCount: pending.byteCount,
                disposition: .reused
            )
        }

        let destination = blobURL(pending.physicalID)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AkashicError.storageUnavailable
        }
        var next = manifest
        next.entries[pending.key] = Entry(
            physicalID: pending.physicalID,
            partition: pending.partition,
            digest: pending.digest,
            byteCount: pending.byteCount,
            lastAccess: Date()
        )
        try faultInjector(.beforeManifestPublished)
        let persistedManifest = try persistManifest(next)
        try faultInjector(.afterManifestPublished)
        manifest = persistedManifest
        pendingStages.removeValue(forKey: stage.rawValue)
        if let existing = pending.existing, existing.physicalID != pending.physicalID {
            try? FileManager.default.removeItem(at: blobURL(existing.physicalID))
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
        try? FileManager.default.removeItem(at: blobURL(pending.physicalID))
    }
}
