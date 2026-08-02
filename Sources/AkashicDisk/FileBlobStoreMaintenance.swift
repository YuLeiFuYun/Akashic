import AkashicCore
import Foundation

extension FileBlobStore {
    /// 删除所有未被指定活动引用保留的物理数据块。
    public func garbageCollect(
        retaining references: Set<LiveBlobReference>,
        limits: BlobMaintenanceLimits
    ) async throws -> BlobMaintenanceResult {
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
            let removed = try removeUnreferencedBlobFiles()
            return try BlobMaintenanceResult(
                removedBlobCount: removed.fileCount,
                removedByteCount: removed.byteCount
            )
        }

        var next = manifest
        for key in victims.keys { next.entries.removeValue(forKey: key) }
        manifest = try persistManifest(next)
        for key in victims.keys { runtimeLastAccess.removeValue(forKey: key) }

        var firstError: (any Error)?
        var removed = BlobPhysicalRemovalSummary()
        for entry in victims.values {
            do {
                try FileManager.default.removeItem(at: blobURL(entry.physicalID))
                removed.record(byteCount: entry.byteCount)
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
        if firstError != nil { throw AkashicError.storageUnavailable }
        return try BlobMaintenanceResult(
            removedBlobCount: removed.fileCount,
            removedByteCount: removed.byteCount
        )
    }

    /// 返回活动 partition/digest 对应的不透明物理定位符。
    public func physicalID(digest: BlobDigest, partition: CachePartitionID) -> PhysicalBlobID? {
        let entry = manifest.entries[
            FileBlobStoreIdentity.manifestKey(
                digest: digest, partition: partition)
        ]
        return entry?.partition == partition ? entry?.physicalID : nil
    }

    /// 先删除一个逻辑条目，再删除其物理数据块。
    public func remove(digest: BlobDigest, partition: CachePartitionID) throws {
        let key = FileBlobStoreIdentity.manifestKey(
            digest: digest, partition: partition)
        discardPendingStages { $0.key == key }
        guard let entry = manifest.entries[key] else { return }

        var next = manifest
        next.entries.removeValue(forKey: key)
        manifest = try persistManifest(next)
        runtimeLastAccess.removeValue(forKey: key)
        try removeFileIfPresent(blobURL(entry.physicalID))
    }

    /// 删除某 partition 拥有的全部逻辑与物理条目。
    public func removeAll(partition: CachePartitionID) throws {
        discardPendingStages { $0.partition == partition }
        let victims = manifest.entries.filter {
            $0.value.partition == partition
        }
        guard !victims.isEmpty else { return }

        var next = manifest
        for key in victims.keys { next.entries.removeValue(forKey: key) }
        manifest = try persistManifest(next)
        for key in victims.keys { runtimeLastAccess.removeValue(forKey: key) }

        var firstFailure: (any Error)?
        for entry in victims.values {
            do {
                try removeFileIfPresent(blobURL(entry.physicalID))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    func quarantineEntry(key: String, blobURL: URL) throws {
        var next = manifest
        next.entries.removeValue(forKey: key)
        do {
            manifest = try persistManifest(next)
        } catch {
            throw AkashicError.storageUnavailable
        }
        runtimeLastAccess.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: blobURL)
    }

    func removeFileIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    func reconcileStorageAfterBootstrap() throws {
        let fileManager = FileManager.default
        try removeManifestTemporaryFiles()
        _ = try removeUnreferencedBlobFiles()

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
            try StorageDirectorySecurity.securePublishedFile(url)
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

    func removeUnreferencedBlobFiles() throws -> BlobPhysicalRemovalSummary {
        let fileManager = FileManager.default
        let files = try boundedChildren(
            at: blobs,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )
        let referencedNames = Set(
            manifest.entries.values.map { $0.physicalID.rawValue.uuidString.lowercased() }
                + pendingStages.values.filter(\.createdFile).map { $0.physicalID.rawValue.uuidString.lowercased() }
        )
        var removed = BlobPhysicalRemovalSummary()
        for file in files {
            let name = file.lastPathComponent
            if isManifestRecordName(name) { continue }
            guard name.hasPrefix(".tmp-") || name.hasPrefix(".durable-tmp-")
                || !referencedNames.contains(name)
            else { continue }
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            try fileManager.removeItem(at: file)
            if values?.isRegularFile == true {
                removed.record(byteCount: values?.fileSize ?? 0)
            }
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
        var total = manifest.entries.values.reduce(0) { $0 + $1.byteCount }
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
        for victim in victims {
            runtimeLastAccess.removeValue(forKey: victim.key)
            try? FileManager.default.removeItem(at: blobURL(victim.entry.physicalID))
        }
    }

    func isValidManifest(_ manifest: Manifest) -> Bool {
        var physicalIDs = Set<PhysicalBlobID>()
        var totalBytes = 0
        guard manifest.schemaVersion == Self.currentSchemaVersion,
            manifest.generation > 0,
            manifest.entries.count <= Self.maximumManifestEntryCount
        else { return false }
        for (key, entry) in manifest.entries {
            guard entry.byteCount >= 0,
                entry.byteCount <= Self.maximumSupportedBlobBytes,
                entry.lastAccess.timeIntervalSinceReferenceDate.isFinite,
                entry.digest.byteCount == entry.byteCount,
                key
                    == FileBlobStoreIdentity.manifestKey(
                        digest: entry.digest,
                        partition: entry.partition
                    ),
                physicalIDs.insert(entry.physicalID).inserted
            else { return false }
            let addition = totalBytes.addingReportingOverflow(entry.byteCount)
            guard !addition.overflow else { return false }
            totalBytes = addition.partialValue
        }
        return true
    }

    func recordAccess(for key: String, blobURL: URL) {
        // mtime 只承担跨进程近似最近性；运行时字典保留精确顺序。
        runtimeLastAccess[key] = BlobAccessJournal.recordAccess(at: blobURL)
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

    /// 持久化清单变化。单 key 变化写固定大小增量记录；批量变化和周期检查点
    /// 仍原子替换完整快照，从而保留 GC/removeAll 的全有或全无边界。
    func persistManifest(_ candidate: Manifest) throws -> Manifest {
        let next = Manifest(
            generation: manifest.generation,
            entries: candidate.entries
        )
        guard isValidManifest(next) else { throw AkashicError.storageUnavailable }

        let changedKeys = Set(manifest.entries.keys).union(next.entries.keys).filter {
            manifest.entries[$0] != next.entries[$0]
        }
        guard !changedKeys.isEmpty else { return manifest }
        guard changedKeys.count == 1, let key = changedKeys.first else {
            return try checkpointManifest(next)
        }

        let recordURL = manifestRecordURL(for: key)
        let createsRecord = !FileManager.default.fileExists(atPath: recordURL.path)
        if manifestRecordCount + (createsRecord ? 1 : 0) >= Self.manifestCheckpointRecordLimit {
            return try checkpointManifest(next)
        }
        let sequence = manifestRecordSequence.addingReportingOverflow(1)
        guard !sequence.overflow else { return try checkpointManifest(next) }
        let record = ManifestRecord(
            generation: manifest.generation,
            sequence: sequence.partialValue,
            key: key,
            entry: next.entries[key]
        )
        try persistManifestRecord(record, to: recordURL)
        manifestRecordSequence = sequence.partialValue
        if createsRecord { manifestRecordCount += 1 }
        return next
    }

    func persistManifestSnapshot(
        _ snapshot: Manifest,
        injectFaults: Bool
    ) throws {
        guard isValidManifest(snapshot) else { throw AkashicError.storageUnavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumManifestBytes else {
            throw AkashicError.storageUnavailable
        }
        let injector = faultInjector
        try DurableFileWriter.writeReplacing(
            data,
            to: manifestURL,
            faultInjector: { point in
                guard injectFaults else { return }
                try Self.forwardManifestFault(point, to: injector)
            }
        )
    }

    func replayManifestRecords() throws {
        let candidates = try boundedChildren(at: blobs, includingPropertiesForKeys: nil)
            .filter { isManifestRecordName($0.lastPathComponent) }
        var records: [ManifestRecord] = []
        var sequences = Set<UInt64>()
        var staleURLs: [URL] = []
        for url in candidates {
            let record: ManifestRecord
            do {
                let data = try BoundedFileReader.read(
                    from: url,
                    maximumBytes: Self.maximumManifestRecordBytes
                )
                record = try JSONDecoder().decode(ManifestRecord.self, from: data)
            } catch {
                throw AkashicError.invalidManifest
            }
            guard record.schemaVersion == ManifestRecord.currentSchemaVersion,
                isValidManifestKey(record.key),
                url == manifestRecordURL(for: record.key),
                record.sequence > 0
            else { throw AkashicError.invalidManifest }
            if record.generation < manifest.generation {
                staleURLs.append(url)
                continue
            }
            guard record.generation == manifest.generation,
                records.count < Self.manifestCheckpointRecordLimit,
                sequences.insert(record.sequence).inserted
            else { throw AkashicError.invalidManifest }
            if let entry = record.entry {
                guard record.key
                    == FileBlobStoreIdentity.manifestKey(
                        digest: entry.digest,
                        partition: entry.partition
                    )
                else { throw AkashicError.invalidManifest }
            }
            records.append(record)
        }

        records.sort { $0.sequence < $1.sequence }
        for record in records {
            if let entry = record.entry {
                manifest.entries[record.key] = entry
            } else {
                manifest.entries.removeValue(forKey: record.key)
            }
        }
        guard isValidManifest(manifest) else { throw AkashicError.invalidManifest }
        manifestRecordSequence = records.last?.sequence ?? 0
        manifestRecordCount = records.count
        for url in staleURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func checkpointManifest(_ candidate: Manifest) throws -> Manifest {
        let generation = manifest.generation.addingReportingOverflow(1)
        guard !generation.overflow else { throw AkashicError.storageUnavailable }
        let snapshot = Manifest(
            generation: generation.partialValue,
            entries: candidate.entries
        )
        try persistManifestSnapshot(snapshot, injectFaults: true)
        manifestRecordSequence = 0
        manifestRecordCount = 0
        removeManifestRecordsBestEffort()
        return snapshot
    }

    private func persistManifestRecord(
        _ record: ManifestRecord,
        to destination: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumManifestRecordBytes else {
            throw AkashicError.storageUnavailable
        }
        let injector = faultInjector
        try DurableFileWriter.writeReplacing(
            data,
            to: destination,
            faultInjector: { point in
                try Self.forwardManifestFault(point, to: injector)
            }
        )
    }

    nonisolated private static func forwardManifestFault(
        _ point: DurableFileWriteSwitchPoint,
        to injector: FileBlobStoreFaultInjector
    ) throws {
        switch point {
        case .afterDataWritten:
            try injector(.afterManifestDataWritten)
        case .afterFileSynced:
            try injector(.afterManifestFileSynced)
        case .afterRename:
            try injector(.afterManifestRenamed)
        case .afterDirectorySynced:
            try injector(.afterManifestDirectorySynced)
        }
    }

    private func manifestRecordURL(for key: String) -> URL {
        blobs.appendingPathComponent(
            ".manifest-entry-\(key).json",
            isDirectory: false
        )
    }

    private func isManifestRecordName(_ name: String) -> Bool {
        guard name.hasPrefix(".manifest-entry-"), name.hasSuffix(".json") else {
            return false
        }
        let key = String(name.dropFirst(".manifest-entry-".count).dropLast(".json".count))
        return isValidManifestKey(key)
    }

    private func isValidManifestKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func removeManifestRecordsBestEffort() {
        guard let children = try? boundedChildren(at: blobs, includingPropertiesForKeys: nil)
        else { return }
        for url in children where isManifestRecordName(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func blobURL(_ id: PhysicalBlobID) -> URL {
        blobs.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
    }
}
