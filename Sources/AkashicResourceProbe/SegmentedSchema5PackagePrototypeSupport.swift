import AkashicDisk

extension SegmentedManifestShadowProbe {
    static func schema5Mutation(
        _ mutation: SegmentedShadowMutation
    ) -> SegmentedManifestMutation {
        switch mutation {
        case .tombstone(let key): .tombstone(key: key)
        case .upsert(let entry): .upsert(schema5Entry(entry))
        }
    }

    static func schema5Entry(_ entry: SegmentedShadowEntry) -> SegmentedManifestEntry {
        SegmentedManifestEntry(
            key: entry.key,
            physicalID: entry.physicalID,
            partition: entry.partition,
            digest: entry.digest,
            byteCount: entry.byteCount,
            lastAccess: entry.lastAccess
        )
    }

    static func schema5Entries(
        _ state: [String: SegmentedShadowEntry]
    ) -> [String: SegmentedManifestEntry] {
        state.mapValues(schema5Entry)
    }

    static func schema5ShadowEntries(
        _ state: [String: SegmentedShadowEntry]
    ) -> [String: FileBlobStoreRecordShadowEntry] {
        state.mapValues { entry in
            FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }

    static func schema5ShadowEntriesFromPrototype(
        _ state: [String: SegmentedManifestEntry]
    ) -> [String: FileBlobStoreRecordShadowEntry] {
        state.mapValues { entry in
            FileBlobStoreRecordShadowEntry(
                physicalID: entry.physicalID,
                partition: entry.partition,
                digest: entry.digest,
                byteCount: entry.byteCount,
                lastAccess: entry.lastAccess
            )
        }
    }
}
