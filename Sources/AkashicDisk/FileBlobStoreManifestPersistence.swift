import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    /// 持久化清单变化。单 key 变化写固定大小增量记录；批量变化和周期检查点
    /// 仍原子替换完整快照，从而保留 GC/removeAll 的全有或全无边界。
    func persistManifest(_ candidate: Manifest) throws -> Manifest {
        if manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion {
            guard manifest.deltaCarrierProfile == .directoryHeadV2 else {
                throw AkashicError.unsupportedSchema
            }
            return try persistDirectoryHeadManifest(candidate)
        }
        repayManifestRecordCleanupDebtBestEffort()
        let next = Manifest(
            generation: manifest.generation,
            entries: candidate.entries
        )
        guard isValidManifest(next) else { throw AkashicError.storageUnavailable }
        let nextLiveByteCount = next.entries.values.reduce(0) { $0 + $1.byteCount }

        let changedKeys = Set(manifest.entries.keys).union(next.entries.keys).filter {
            manifest.entries[$0] != next.entries[$0]
        }
        guard !changedKeys.isEmpty else { return manifest }
        guard changedKeys.count == 1, let key = changedKeys.first else {
            return try checkpointManifest(next)
        }

        let recordURL = manifestRecordURL(for: key)
        let createsRecord = !manifestRecordKeys.contains(key)
        if manifestRecordCount + (createsRecord ? 1 : 0) >= Self.manifestCheckpointRecordLimit {
            return try checkpointManifest(next)
        }
        let sequence = manifestRecordSequence.addingReportingOverflow(1)
        guard !sequence.overflow else { return try checkpointManifest(next) }
        // A sidecar delta uses a same-directory temporary even when replacing an existing record.
        // If no crash-visible direct-child slot remains, publish the same logical transition via
        // the root snapshot instead of creating a state that bounded reopen cannot enumerate.
        guard canReserveBlobDirectoryEntries(1) else {
            return try checkpointManifest(next)
        }
        let record = ManifestRecord(
            generation: manifest.generation,
            sequence: sequence.partialValue,
            key: key,
            entry: next.entries[key]
        )
        try persistManifestRecord(record, to: recordURL)
        manifestRecordSequence = sequence.partialValue
        if createsRecord { manifestRecordKeys.insert(key) }
        manifestLiveByteCount = nextLiveByteCount
        return next
    }

    /// Persist exactly one logical-key transition without allowing a caller-supplied multi-key
    /// candidate to masquerade as a hot-path delta. Schema4 uses this to avoid copying and
    /// revalidating the full live manifest; schema3 preserves its existing generic path.
    func persistSingleKeyManifestEntry(
        key: String,
        entry: Entry?
    ) throws -> Manifest {
        if manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion {
            guard manifest.deltaCarrierProfile == .directoryHeadV2 else {
                throw AkashicError.unsupportedSchema
            }
            return try persistDirectoryHeadSingleKeyEntry(key: key, entry: entry)
        }
        var next = manifest
        if let entry {
            next.entries[key] = entry
        } else {
            next.entries.removeValue(forKey: key)
        }
        return try persistManifest(next)
    }

    func persistManifestSnapshot(
        _ snapshot: Manifest,
        injectFaults: Bool
    ) throws {
        guard isValidManifest(snapshot) else { throw AkashicError.storageUnavailable }
        try persistValidatedManifestSnapshot(snapshot, injectFaults: injectFaults)
    }

    /// 持久化已经由本事务路径完整验证过的 snapshot。
    ///
    /// `persistManifest` 先验证 candidate 的全部 entry；checkpoint 只把同一 entries 的
    /// generation 做已检查的 +1，因此再次逐 entry 重算 manifest key 不会增加正确性
    /// 证据，只会把 O(n) validation 重复放进 checkpoint 临界路径。bootstrap 等其他
    /// 调用者仍必须经过上面的完整 `isValidManifest`。
    func persistValidatedManifestSnapshot(
        _ snapshot: Manifest,
        injectFaults: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumManifestBytes else {
            throw AkashicError.storageUnavailable
        }
        let injector = faultInjector
        var authorityRenamed = false
        do {
            try DurableFileWriter.writeReplacing(
                data,
                to: manifestURL,
                faultInjector: { point in
                    guard injectFaults else { return }
                    try Self.forwardManifestFault(point, to: injector)
                },
                renameObserver: { authorityRenamed = true }
            )
        } catch {
            if authorityRenamed { requiresReopenBeforeFurtherAccess = true }
            throw error
        }
    }

    func replayManifestRecords() throws {
        let children = try boundedChildren(at: blobs, includingPropertiesForKeys: nil)
        var records: [(key: String, record: ManifestRecord)] = []
        var sequences = Set<UInt64>()
        var changedKeys = Set<String>()
        var staleURLs: [URL] = []

        func appendCurrentRecord(key: String, record: ManifestRecord) throws {
            guard record.generation == manifest.generation,
                record.sequence > 0,
                sequences.insert(record.sequence).inserted
            else { throw AkashicError.invalidManifest }
            if changedKeys.insert(key).inserted,
                changedKeys.count >= Self.manifestCheckpointRecordLimit
            {
                throw AkashicError.invalidManifest
            }
            if let entry = record.entry,
                !isValidManifestEntry(key: key, entry: entry)
            {
                throw AkashicError.invalidManifest
            }
            records.append((key: key, record: record))
        }

        for url in children {
            if let fileIdentity = ManifestRecord.fileIdentity(from: url.lastPathComponent) {
                if let filenameGeneration = fileIdentity.generation {
                    if filenameGeneration < manifest.generation {
                        // generation-scoped sidecar identity already proves this record stale.
                        staleURLs.append(url)
                        continue
                    }
                    guard filenameGeneration == manifest.generation else {
                        throw AkashicError.invalidManifest
                    }
                }

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
                    record.sequence > 0
                else { throw AkashicError.invalidManifest }
                if let filenameGeneration = fileIdentity.generation,
                    filenameGeneration != record.generation
                {
                    throw AkashicError.invalidManifest
                }
                let key: String
                if let persistedKey = record.persistedKey {
                    guard persistedKey == fileIdentity.key else {
                        throw AkashicError.invalidManifest
                    }
                    key = persistedKey
                } else {
                    key = fileIdentity.key
                }
                if record.generation < manifest.generation {
                    staleURLs.append(url)
                    continue
                }
                try appendCurrentRecord(key: key, record: record)
                continue
            }

            let name = url.lastPathComponent
            guard let uuid = UUID(uuidString: name),
                uuid.uuidString.lowercased() == name
            else { continue }
            let physicalID = PhysicalBlobID(rawValue: uuid)
            for item in try Self.readCurrentManifestXattrRecords(
                at: url,
                physicalID: physicalID,
                generation: manifest.generation
            ) {
                try appendCurrentRecord(key: item.key, record: item.record)
            }
        }

        records.sort { $0.record.sequence < $1.record.sequence }
        for item in records {
            if let entry = item.record.entry {
                manifest.entries[item.key] = entry
            } else {
                manifest.entries.removeValue(forKey: item.key)
            }
        }
        guard isValidManifest(manifest) else { throw AkashicError.invalidManifest }
        manifestRecordSequence = records.last?.record.sequence ?? 0
        manifestRecordKeys = changedKeys
        staleManifestRecordCleanupQueue = staleURLs
    }

    /// Seal already-committed logical state into the next snapshot generation when physical
    /// cleanup cannot retire an older carrier.
    ///
    /// Schema 3 has no independent commitment over its current-generation delta carriers. If a
    /// higher-sequence record later disappears while a lower-sequence payload carrier remains as
    /// cleanup debt, replay could otherwise roll logical authority backward. Advancing the full
    /// snapshot generation retires every current delta carrier before an API is allowed to report a
    /// successful cleanup-debt outcome. Normal successful cleanup never pays this checkpoint cost.
    func sealManifestAfterPhysicalCleanupDebt() throws {
        guard manifestRecordSequence > 0 || !manifestRecordKeys.isEmpty else { return }
        do {
            manifest = try checkpointManifest(manifest)
        } catch {
            // The logical mutation that created the debt may already be visible on disk. If the
            // protective seal cannot be completed, this writer must not continue from ambiguous
            // generation/sequence state; reopen owns convergence.
            requiresReopenBeforeFurtherAccess = true
            throw AkashicError.storageUnavailable
        }
    }

    func checkpointManifest(
        applying transition: ManifestOwnershipTransition
    ) throws -> Manifest {
        if loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion,
            let profile = segmentedManifestRoot?.profile,
            profile == SegmentedManifestPrototypeV1.profileV3
                || profile == SegmentedManifestPrototypeV1.profileV4
        {
            return try checkpointSegmentedManifest(applying: transition)
        }

        var entries = manifest.entries
        if let entry = transition.newEntry {
            entries[transition.key] = entry
        } else {
            entries.removeValue(forKey: transition.key)
        }
        let candidate = Manifest(
            schemaVersion: manifest.schemaVersion,
            generation: manifest.generation,
            deltaCarrierProfile: manifest.deltaCarrierProfile,
            entries: entries
        )
        return try checkpointManifest(candidate)
    }

    func checkpointManifest(_ candidate: Manifest) throws -> Manifest {
        if loadedManifestSchemaVersion == Self.segmentedManifestSchemaVersion {
            return try checkpointSegmentedManifest(candidate)
        }
        let generation = manifest.generation.addingReportingOverflow(1)
        guard !generation.overflow else { throw AkashicError.storageUnavailable }
        let snapshot = Manifest(
            schemaVersion: manifest.schemaVersion,
            generation: generation.partialValue,
            deltaCarrierProfile: manifest.deltaCarrierProfile,
            entries: candidate.entries
        )
        guard isValidManifestEntriesAndOwnership(snapshot) else {
            throw AkashicError.storageUnavailable
        }

        let previousDirectoryState: DirectoryHeadRecoveredState?
        if manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion {
            guard manifest.deltaCarrierProfile == .directoryHeadV2 else {
                throw AkashicError.unsupportedSchema
            }
            previousDirectoryState = try currentDirectoryHeadState()
            // A checkpoint can be triggered by a multi-key operation with no intervening single-key
            // mutation. Do not let those checkpoints stack stale authority-metadata generations
            // indefinitely: retire all older-generation directory-head debt before publishing the
            // next snapshot. These attributes are already logically stale, so partial pre-cleanup is
            // safe if a removal fails; the snapshot generation has not advanced yet.
            try repayDirectoryHeadCleanupDebtBeforeMutation(
                limit: staleDirectoryHeadCleanupQueue.count
            )
        } else {
            previousDirectoryState = nil
        }

        try persistValidatedManifestSnapshot(snapshot, injectFaults: true)

        if let previousDirectoryState {
            let newState: DirectoryHeadRecoveredState
            do {
                newState = try initializeEmptyDirectoryHeadGeneration(
                    generation: snapshot.generation
                )
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            enqueueCurrentDirectoryHeadGenerationForCleanup(
                state: previousDirectoryState,
                generation: manifest.generation
            )
            directoryHeadState = newState
            manifestRecordSequence = 0
            manifestRecordKeys.removeAll(keepingCapacity: true)
            guard let rebuiltOwnership = validatedManifestOwnershipIndex(snapshot) else {
                requiresReopenBeforeFurtherAccess = true
                throw AkashicError.invalidManifest
            }
            manifestOwnershipIndex = rebuiltOwnership
            manifestLiveByteCount = rebuiltOwnership.totalBytes
            return snapshot
        }

        manifestOwnershipIndex = nil
        guard let rebuiltOwnership = validatedManifestOwnershipIndex(snapshot) else {
            throw AkashicError.invalidManifest
        }
        manifestLiveByteCount = rebuiltOwnership.totalBytes
        manifestRecordSequence = 0
        manifestRecordKeys.removeAll(keepingCapacity: true)
        enqueueManifestRecordsForCleanup(staleBeforeGeneration: snapshot.generation)
        return snapshot
    }

    nonisolated static func forwardManifestFault(
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

    func manifestRecordURL(for key: String, generation: UInt64? = nil) -> URL {
        let targetGeneration = generation ?? manifest.generation
        guard let name = ManifestRecord.fileName(generation: targetGeneration, key: key) else {
            preconditionFailure("validated manifest key and generation must produce a record name")
        }
        return blobs.appendingPathComponent(name, isDirectory: false)
    }

    func isManifestRecordName(_ name: String) -> Bool {
        ManifestRecord.fileIdentity(from: name) != nil
    }

    private func enqueueManifestRecordsForCleanup(staleBeforeGeneration: UInt64) {
        guard let children = try? boundedChildren(at: blobs, includingPropertiesForKeys: nil)
        else { return }
        var known = Set(staleManifestRecordCleanupQueue)
        for url in children {
            guard let identity = ManifestRecord.fileIdentity(from: url.lastPathComponent) else {
                continue
            }
            let isStale = identity.generation.map { $0 < staleBeforeGeneration } ?? true
            if isStale, known.insert(url).inserted {
                staleManifestRecordCleanupQueue.append(url)
            }
        }
    }

    /// Validate that a sidecar-shaped path is actually stale Akashic manifest metadata before it
    /// can enter the physical-cleanup candidate set. Filename shape and matching file metadata alone are
    /// insufficient: the bounded body must decode, its generation/key must agree with the filename,
    /// and any create entry must still project back to the same logical manifest key.
    func validateLegacyManifestRecordCleanupCandidate(
        _ url: URL,
        staleBeforeGeneration: UInt64
    ) throws {
        guard staleBeforeGeneration > 0,
            let identity = ManifestRecord.fileIdentity(from: url.lastPathComponent)
        else { throw AkashicError.invalidManifest }
        let data = try BoundedFileReader.readOwnedRegularFileAllowingPermissionDrift(
            from: url,
            maximumBytes: Self.maximumManifestRecordBytes
        )
        let record: ManifestRecord
        do {
            record = try JSONDecoder().decode(ManifestRecord.self, from: data)
        } catch {
            throw AkashicError.invalidManifest
        }
        guard record.schemaVersion == ManifestRecord.currentSchemaVersion,
            record.generation > 0,
            record.generation < staleBeforeGeneration,
            record.sequence > 0
        else { throw AkashicError.invalidManifest }
        if let filenameGeneration = identity.generation,
            filenameGeneration != record.generation
        {
            throw AkashicError.invalidManifest
        }
        if let persistedKey = record.persistedKey,
            persistedKey != identity.key
        {
            throw AkashicError.invalidManifest
        }
        if let entry = record.entry,
            !isValidManifestEntry(key: identity.key, entry: entry)
        {
            throw AkashicError.invalidManifest
        }
    }

    /// Preserve exact legacy sidecar cleanup debt across schema3 -> schema4 migration without
    /// scanning the full blobs directory. A generation can contain at most 511 changed logical
    /// keys, so probing both scoped and legacy-unscoped filenames remains bounded by delta
    /// cardinality rather than live payload cardinality. Xattr-backed create records simply have no
    /// sidecar candidate and are intentionally left as bounded grandfathered inode metadata.
    func enqueueLegacyManifestRecordCandidatesForCleanup(
        generation: UInt64,
        keys: Set<String>
    ) {
        let fileManager = FileManager.default
        var known = Set(staleManifestRecordCleanupQueue)
        for key in keys {
            let names = [
                ManifestRecord.fileName(generation: generation, key: key),
                ManifestRecord.legacyFileName(key: key),
            ].compactMap { $0 }
            for name in names {
                let url = blobs.appendingPathComponent(name, isDirectory: false)
                guard fileManager.fileExists(atPath: url.path), known.insert(url).inserted else {
                    continue
                }
                guard
                    (try? validateLegacyManifestRecordCleanupCandidate(
                        url,
                        staleBeforeGeneration: manifest.generation
                    )) != nil
                else { continue }
                staleManifestRecordCleanupQueue.append(url)
            }
        }
    }

    /// 每个后续 mutation 最多偿还一个 stale-record physical ownership debt。
    ///
    /// 一个 generation 最多产生 511 个 active records；下一次达到 512-record checkpoint
    /// 之前至少要经历同数量级的 record-producing mutation，因此 budget=1 已足以阻止 debt
    /// 跨 checkpoint 无界累积，同时避免把整批 unlink 重新塞回单次提交长尾。
    func repayManifestRecordCleanupDebtBestEffort() {
        guard let url = staleManifestRecordCleanupQueue.popLast() else { return }
        // Revalidate identity and body immediately before unlink so a stale queue entry cannot turn
        // a replaced lookalike into a deletion target. Validation failure drops only this best-effort
        // physical debt; a later reopen can rediscover the path if it again becomes valid stale
        // Akashic metadata.
        guard
            (try? validateLegacyManifestRecordCleanupCandidate(
                url,
                staleBeforeGeneration: manifest.generation
            )) != nil
        else { return }
        if Darwin.unlink(url.path) == 0 {
            recordBlobDirectoryEntryRemoved()
        } else if errno != ENOENT {
            staleManifestRecordCleanupQueue.append(url)
        }
    }

}
