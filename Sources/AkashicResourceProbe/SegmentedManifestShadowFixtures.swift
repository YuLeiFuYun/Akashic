import AkashicCore
import AkashicDisk
import Foundation

extension SegmentedManifestShadowProbe {
    static func makeBaseEntries(count: Int) throws -> [SegmentedShadowEntry] {
        var entries: [SegmentedShadowEntry] = []
        entries.reserveCapacity(count)
        for index in 0 ..< count {
            let partition = try CachePartitionID.derive(
                domain: "resource-segment-shadow-v1",
                material: Data("partition-\(index % 17)".utf8)
            )
            let payload = Data("shadow-payload-\(index)".utf8)
            let digest = BlobDigest.sha256(of: payload)
            let key = FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
            entries.append(
                SegmentedShadowEntry(
                    key: key,
                    physicalID: PhysicalBlobID(),
                    partition: partition,
                    digest: digest,
                    byteCount: payload.count,
                    lastAccess: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / 1000)
                )
            )
        }
        return entries.sorted { $0.key < $1.key }
    }

    static func makeRunMutations(
        base: [SegmentedShadowEntry],
        count: Int
    ) throws -> [SegmentedShadowMutation] {
        var mutations: [SegmentedShadowMutation] = []
        mutations.reserveCapacity(count)
        for index in 0 ..< count {
            let old = base[index * 2]
            switch index % 3 {
            case 0:
                mutations.append(.tombstone(key: old.key))
            case 1:
                // Same logical object, new physical carrier: the logical key is unchanged because
                // partition+digest are unchanged. This exercises physical repair independently of
                // logical create/delete semantics.
                mutations.append(
                    .upsert(
                        SegmentedShadowEntry(
                            key: old.key,
                            physicalID: PhysicalBlobID(),
                            partition: old.partition,
                            digest: old.digest,
                            byteCount: old.byteCount,
                            lastAccess: Date(timeIntervalSinceReferenceDate: 900_000_000 + Double(index) / 1000)
                        )
                    )
                )
            default:
                let partition = try CachePartitionID.derive(
                    domain: "resource-segment-shadow-create-v1",
                    material: Data("partition-\(index)".utf8)
                )
                let payload = Data("shadow-create-\(index)".utf8)
                let digest = BlobDigest.sha256(of: payload)
                let key = FileBlobStore.resourceProbeManifestKey(
                    digest: digest,
                    partition: partition
                )
                mutations.append(
                    .upsert(
                        SegmentedShadowEntry(
                            key: key,
                            physicalID: PhysicalBlobID(),
                            partition: partition,
                            digest: digest,
                            byteCount: payload.count,
                            lastAccess: Date(timeIntervalSinceReferenceDate: 900_000_000 + Double(index) / 1000)
                        )
                    )
                )
            }
        }
        return mutations.sorted { $0.key < $1.key }
    }

    static func apply(
        _ mutations: [SegmentedShadowMutation],
        to source: [String: SegmentedShadowEntry]
    ) throws -> [String: SegmentedShadowEntry] {
        var result = source
        var previous: String?
        for mutation in mutations {
            if let previous, mutation.key <= previous {
                throw SegmentedManifestShadowError.invalidFormat
            }
            previous = mutation.key
            switch mutation {
            case .upsert(let entry):
                result[entry.key] = entry
            case .tombstone(let key):
                result.removeValue(forKey: key)
            }
        }
        let physicalIDs = result.values.map(\.physicalID)
        guard Set(physicalIDs).count == physicalIDs.count else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        return result
    }

}
