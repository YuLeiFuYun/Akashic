import AkashicCore
import Dispatch
import Foundation

package struct FileBlobStoreRecordShadowEntry: Sendable, Equatable {
    package let physicalID: PhysicalBlobID
    package let partition: CachePartitionID
    package let digest: BlobDigest
    package let byteCount: Int
    package let lastAccess: Date

    package init(
        physicalID: PhysicalBlobID,
        partition: CachePartitionID,
        digest: BlobDigest,
        byteCount: Int,
        lastAccess: Date
    ) {
        self.physicalID = physicalID
        self.partition = partition
        self.digest = digest
        self.byteCount = byteCount
        self.lastAccess = lastAccess
    }
}

package struct FileBlobStoreRecordShadowMutation: Sendable, Equatable {
    package let generation: UInt64
    package let sequence: UInt64
    package let key: String
    package let entry: FileBlobStoreRecordShadowEntry?

    package init(
        generation: UInt64,
        sequence: UInt64,
        key: String,
        entry: FileBlobStoreRecordShadowEntry?
    ) {
        self.generation = generation
        self.sequence = sequence
        self.key = key
        self.entry = entry
    }
}

package struct FileBlobStoreManifestShadowSnapshot: Sendable, Equatable {
    package let generation: UInt64
    package let entries: [String: FileBlobStoreRecordShadowEntry]

    package init(
        generation: UInt64,
        entries: [String: FileBlobStoreRecordShadowEntry]
    ) {
        self.generation = generation
        self.entries = entries
    }
}

package struct FileBlobStoreDirectoryHeadEpochShadowSnapshot: Sendable, Equatable {
    package let generation: UInt64
    package let activeSequence: UInt64
    package let distinctKeyCount: Int
    package let commitmentRoot: Data
    package let mutations: [FileBlobStoreRecordShadowMutation]

    package init(
        generation: UInt64,
        activeSequence: UInt64,
        distinctKeyCount: Int,
        commitmentRoot: Data,
        mutations: [FileBlobStoreRecordShadowMutation]
    ) {
        self.generation = generation
        self.activeSequence = activeSequence
        self.distinctKeyCount = distinctKeyCount
        self.commitmentRoot = commitmentRoot
        self.mutations = mutations
    }
}

package struct FileBlobStoreRecordReplayDiagnostic: Sendable {
    package let recordCount: Int
    package let enumerationAndParseNanoseconds: [UInt64]
    package let boundedReadNanoseconds: [UInt64]
    package let decodeFreshDecoderNanoseconds: [UInt64]
    package let decodeSharedDecoderNanoseconds: [UInt64]
    package let keyValidationNanoseconds: [UInt64]
    package let fullManifestValidationNanoseconds: [UInt64]
}

extension FileBlobStore {
    package func resourceProbePendingStageEntry(
        _ stage: BlobStage
    ) -> FileBlobStoreRecordShadowEntry? {
        guard let pending = pendingStages[stage.rawValue] else { return nil }
        return FileBlobStoreRecordShadowEntry(
            physicalID: pending.physicalID,
            partition: pending.partition,
            digest: pending.digest,
            byteCount: pending.byteCount,
            lastAccess: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    package static var resourceProbeManifestCheckpointRecordLimit: Int {
        manifestCheckpointRecordLimit
    }

    package static var resourceProbeMaximumManifestEntryCount: Int {
        maximumManifestEntryCount
    }

    package static func resourceProbeManifestKey(
        digest: BlobDigest,
        partition: CachePartitionID
    ) -> String {
        FileBlobStoreIdentity.manifestKey(digest: digest, partition: partition)
    }

    package func resourceProbeManifestShadowSnapshot() -> FileBlobStoreManifestShadowSnapshot {
        var entries: [String: FileBlobStoreRecordShadowEntry] = [:]
        entries.reserveCapacity(manifest.entries.count)
        for (key, entry) in manifest.entries {
            entries[key] = FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
        return FileBlobStoreManifestShadowSnapshot(
            generation: manifest.generation,
            entries: entries
        )
    }

    package func resourceProbeDirectoryHeadEpochSnapshot()
        throws -> FileBlobStoreDirectoryHeadEpochShadowSnapshot
    {
        guard manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2
        else { throw AkashicError.unsupportedSchema }
        let state = try currentDirectoryHeadState()
        let mutations = state.latest.map { key, latest -> FileBlobStoreRecordShadowMutation in
            let entry: FileBlobStoreRecordShadowEntry?
            if let source = latest.record.entry {
                entry = FileBlobStoreRecordShadowEntry(
                    physicalID: source.physicalID,
                    partition: source.partition,
                    digest: source.digest,
                    byteCount: source.byteCount,
                    lastAccess: source.lastAccess
                )
            } else {
                entry = nil
            }
            return FileBlobStoreRecordShadowMutation(
                generation: latest.record.generation,
                sequence: latest.record.sequence,
                key: key,
                entry: entry
            )
        }.sorted { $0.key < $1.key }
        guard mutations.count == Int(state.activeHead.c),
            mutations.allSatisfy({ $0.generation == manifest.generation }),
            state.activeHead.g == manifest.generation
        else { throw AkashicError.invalidManifest }
        return FileBlobStoreDirectoryHeadEpochShadowSnapshot(
            generation: manifest.generation,
            activeSequence: state.activeHead.s,
            distinctKeyCount: Int(state.activeHead.c),
            commitmentRoot: state.activeHead.r,
            mutations: mutations
        )
    }

    package static func resourceProbeEncodeManifestRecord(
        _ mutation: FileBlobStoreRecordShadowMutation
    ) throws -> Data {
        guard mutation.generation > 0,
            mutation.sequence > 0,
            ManifestRecord.fileName(generation: mutation.generation, key: mutation.key) != nil
        else {
            throw AkashicError.invalidManifest
        }
        let entry: Entry?
        if let candidate = mutation.entry {
            let decoded = Entry(
                physicalID: candidate.physicalID,
                partition: candidate.partition,
                digest: candidate.digest,
                byteCount: candidate.byteCount,
                lastAccess: candidate.lastAccess
            )
            guard decoded.byteCount >= 0,
                decoded.byteCount <= maximumSupportedBlobBytes,
                decoded.lastAccess.timeIntervalSinceReferenceDate.isFinite,
                decoded.digest.byteCount == decoded.byteCount,
                mutation.key
                    == FileBlobStoreIdentity.manifestKey(
                        digest: decoded.digest,
                        partition: decoded.partition
                    )
            else {
                throw AkashicError.invalidManifest
            }
            entry = decoded
        } else {
            entry = nil
        }
        let record = ManifestRecord(
            generation: mutation.generation,
            sequence: mutation.sequence,
            key: mutation.key,
            entry: entry
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    package static func resourceProbeDecodeManifestRecord(
        _ data: Data
    ) throws -> FileBlobStoreRecordShadowMutation {
        let record: ManifestRecord
        do {
            record = try JSONDecoder().decode(ManifestRecord.self, from: data)
        } catch {
            throw AkashicError.invalidManifest
        }
        guard record.schemaVersion == ManifestRecord.currentSchemaVersion,
            record.generation > 0,
            record.sequence > 0
        else {
            throw AkashicError.invalidManifest
        }
        let key: String
        let shadowEntry: FileBlobStoreRecordShadowEntry?
        if let entry = record.entry {
            let expectedKey = FileBlobStoreIdentity.manifestKey(
                digest: entry.digest,
                partition: entry.partition
            )
            if let persistedKey = record.persistedKey, persistedKey != expectedKey {
                throw AkashicError.invalidManifest
            }
            guard ManifestRecord.fileName(
                generation: record.generation,
                key: expectedKey
            ) != nil,
                entry.byteCount >= 0,
                entry.byteCount <= maximumSupportedBlobBytes,
                entry.lastAccess.timeIntervalSinceReferenceDate.isFinite,
                entry.digest.byteCount == entry.byteCount
            else {
                throw AkashicError.invalidManifest
            }
            key = expectedKey
            shadowEntry = FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        } else {
            guard let persistedKey = record.persistedKey,
                ManifestRecord.fileName(
                    generation: record.generation,
                    key: persistedKey
                ) != nil
            else {
                throw AkashicError.invalidManifest
            }
            key = persistedKey
            shadowEntry = nil
        }
        return FileBlobStoreRecordShadowMutation(
            generation: record.generation,
            sequence: record.sequence,
            key: key,
            entry: shadowEntry
        )
    }

    /// 仅供同 package 的资源探针隔离 Manifest 编码成本。
    ///
    /// 该入口不改变 store 状态、不参与逻辑 authority，也不对宿主暴露。返回真实当前
    /// in-memory Manifest 的默认 JSON 编码，使资源探针能够把 Codable/object traversal
    /// 与 durable file I/O 分开测量。
    package func resourceProbeEncodedManifestSnapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    /// 仅供 checkpoint 资源实验构造与真实 schema4 snapshot 编码完全相同的 synthetic state。
    /// 不持久化、不改变 store authority，也不向外部 consumer 暴露。
    package static func resourceProbeEncodeDirectoryHeadSnapshot(
        generation: UInt64,
        entries source: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> Data {
        guard generation > 0, source.count <= maximumManifestEntryCount else {
            throw AkashicError.invalidManifest
        }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(source.count)
        var physicalIDs = Set<PhysicalBlobID>()
        physicalIDs.reserveCapacity(source.count)
        for (key, shadow) in source {
            guard shadow.byteCount >= 0,
                shadow.byteCount <= maximumSupportedBlobBytes,
                shadow.digest.byteCount == shadow.byteCount,
                shadow.lastAccess.timeIntervalSinceReferenceDate.isFinite,
                key == FileBlobStoreIdentity.manifestKey(
                    digest: shadow.digest,
                    partition: shadow.partition
                ),
                physicalIDs.insert(shadow.physicalID).inserted
            else { throw AkashicError.invalidManifest }
            entries[key] = Entry(
                physicalID: shadow.physicalID,
                partition: shadow.partition,
                digest: shadow.digest,
                byteCount: shadow.byteCount,
                lastAccess: shadow.lastAccess
            )
        }
        let manifest = Manifest(
            schemaVersion: directoryHeadManifestSchemaVersion,
            generation: generation,
            deltaCarrierProfile: .directoryHeadV2,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumManifestBytes else { throw AkashicError.storageUnavailable }
        return data
    }

    package static func resourceProbeDecodeDirectoryHeadSnapshot(
        _ data: Data
    ) throws -> [String: FileBlobStoreRecordShadowEntry] {
        guard data.count <= maximumManifestBytes else { throw AkashicError.invalidManifest }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw AkashicError.invalidManifest
        }
        guard manifest.schemaVersion == directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            manifest.entries.count <= maximumManifestEntryCount
        else { throw AkashicError.invalidManifest }
        return manifest.entries.mapValues { entry in
            FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }

    /// 仅供资源探针量化完整 Manifest invariant/key validation 成本。
    package func resourceProbeValidateManifest() -> Bool {
        isValidManifest(manifest)
    }

    /// 仅供资源探针拆解当前 generation incremental-record replay 成本。
    package func resourceProbeRecordReplayDiagnostic(
        repetitions: Int = 5
    ) throws -> FileBlobStoreRecordReplayDiagnostic {
        let repetitions = max(1, repetitions)
        let children = try FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: nil,
            options: []
        )
        let recordURLs = children.filter {
            ManifestRecord.fileIdentity(from: $0.lastPathComponent)?.generation == manifest.generation
        }
        let recordData = try recordURLs.map {
            try BoundedFileReader.read(from: $0, maximumBytes: Self.maximumManifestRecordBytes)
        }
        let decodedRecords = try recordData.map {
            try JSONDecoder().decode(ManifestRecord.self, from: $0)
        }

        var enumerationAndParse: [UInt64] = []
        var reads: [UInt64] = []
        var freshDecode: [UInt64] = []
        var sharedDecode: [UInt64] = []
        var keyValidation: [UInt64] = []
        var manifestValidation: [UInt64] = []
        for _ in 0 ..< repetitions {
            var start = DispatchTime.now().uptimeNanoseconds
            let listed = try FileManager.default.contentsOfDirectory(
                at: blobs,
                includingPropertiesForKeys: nil,
                options: []
            )
            var parsedCount = 0
            for url in listed {
                if ManifestRecord.fileIdentity(from: url.lastPathComponent) != nil {
                    parsedCount += 1
                }
            }
            precondition(parsedCount >= recordURLs.count)
            enumerationAndParse.append(DispatchTime.now().uptimeNanoseconds &- start)

            start = DispatchTime.now().uptimeNanoseconds
            var readBytes = 0
            for url in recordURLs {
                readBytes += try BoundedFileReader.read(
                    from: url,
                    maximumBytes: Self.maximumManifestRecordBytes
                ).count
            }
            precondition(readBytes > 0 || recordURLs.isEmpty)
            reads.append(DispatchTime.now().uptimeNanoseconds &- start)

            start = DispatchTime.now().uptimeNanoseconds
            var freshCount = 0
            for data in recordData {
                _ = try JSONDecoder().decode(ManifestRecord.self, from: data)
                freshCount += 1
            }
            precondition(freshCount == recordData.count)
            freshDecode.append(DispatchTime.now().uptimeNanoseconds &- start)

            let decoder = JSONDecoder()
            start = DispatchTime.now().uptimeNanoseconds
            var sharedCount = 0
            for data in recordData {
                _ = try decoder.decode(ManifestRecord.self, from: data)
                sharedCount += 1
            }
            precondition(sharedCount == recordData.count)
            sharedDecode.append(DispatchTime.now().uptimeNanoseconds &- start)

            start = DispatchTime.now().uptimeNanoseconds
            var validated = 0
            for record in decodedRecords {
                if let entry = record.entry {
                    _ = FileBlobStoreIdentity.manifestKey(
                        digest: entry.digest,
                        partition: entry.partition
                    )
                    validated += 1
                }
            }
            precondition(validated <= decodedRecords.count)
            keyValidation.append(DispatchTime.now().uptimeNanoseconds &- start)

            start = DispatchTime.now().uptimeNanoseconds
            precondition(isValidManifest(manifest))
            manifestValidation.append(DispatchTime.now().uptimeNanoseconds &- start)
        }
        return FileBlobStoreRecordReplayDiagnostic(
            recordCount: recordURLs.count,
            enumerationAndParseNanoseconds: enumerationAndParse,
            boundedReadNanoseconds: reads,
            decodeFreshDecoderNanoseconds: freshDecode,
            decodeSharedDecoderNanoseconds: sharedDecode,
            keyValidationNanoseconds: keyValidation,
            fullManifestValidationNanoseconds: manifestValidation
        )
    }

    /// 仅供资源探针对比 reopen reconciliation 的“无条件修复”与纯验证成本。
    package func resourceProbePublishedFileSecurityPass(repair: Bool) throws -> Int {
        var count = 0
        for entry in manifest.entries.values {
            let url = blobURL(entry.physicalID)
            if repair {
                try StorageDirectorySecurity.securePublishedFile(url)
            } else {
                try StorageDirectorySecurity.validateRegularFile(url)
            }
            count += 1
        }
        return count
    }
}
