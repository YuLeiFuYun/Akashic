import AkashicCore
import Foundation

extension FileBlobStore {
    static func loadDirectoryHeadState(
        directory: URL,
        generation: UInt64,
        operations: FileBlobStoreDirectoryHeadOperations
    ) throws -> DirectoryHeadRecoveredState {
        let names = try operations.listAttributes(
            directory,
            maximumDirectoryHeadXattrListBytes
        )
        var headNames: [UInt8: String] = [:]
        var records: [DirectoryHeadRecordIdentity] = []
        records.reserveCapacity(min(names.count, manifestCheckpointRecordLimit * 2))

        for name in names {
            if let headIdentity = try DirectoryHeadIdentity.parse(name) {
                if headIdentity.generation < generation { continue }
                guard headIdentity.generation == generation,
                    headNames[headIdentity.slot] == nil
                else { throw AkashicError.invalidManifest }
                headNames[headIdentity.slot] = name
                continue
            }
            if let recordIdentity = try DirectoryHeadRecordIdentity.parse(name) {
                if recordIdentity.generation < generation { continue }
                guard recordIdentity.generation == generation else {
                    throw AkashicError.invalidManifest
                }
                records.append(recordIdentity)
                guard records.count <= manifestCheckpointRecordLimit * 2 else {
                    throw AkashicError.invalidManifest
                }
            }
        }

        guard let head0Name = headNames[0],
            let head1Name = headNames[1],
            headNames.count == 2
        else { throw AkashicError.invalidManifest }
        let head0 = try decodeDirectoryHead(
            operations.readAttribute(
                head0Name,
                directory,
                maximumDirectoryHeadValueBytes
            ),
            expected: DirectoryHeadIdentity(generation: generation, slot: 0)
        )
        let head1 = try decodeDirectoryHead(
            operations.readAttribute(
                head1Name,
                directory,
                maximumDirectoryHeadValueBytes
            ),
            expected: DirectoryHeadIdentity(generation: generation, slot: 1)
        )

        let activeSlot: UInt8
        let activeHead: DirectoryHeadValue
        if head0.s == head1.s {
            guard head0.s == 0,
                head0.c == 0,
                head1.c == 0,
                head0.r == directoryHeadZeroRoot,
                head1.r == directoryHeadZeroRoot
            else { throw AkashicError.invalidManifest }
            activeSlot = 0
            activeHead = head0
        } else if head0.s > head1.s {
            activeSlot = 0
            activeHead = head0
        } else {
            activeSlot = 1
            activeHead = head1
        }

        var seenSequences = Set<UInt64>()
        var latestIdentities: [String: DirectoryHeadRecordIdentity] = [:]
        var uncommittedNames: [String] = []
        for identity in records {
            if identity.sequence > activeHead.s {
                uncommittedNames.append(identity.name)
                continue
            }
            guard seenSequences.insert(identity.sequence).inserted else {
                throw AkashicError.invalidManifest
            }
            if let old = latestIdentities[identity.key] {
                if identity.sequence > old.sequence {
                    latestIdentities[identity.key] = identity
                }
            } else {
                latestIdentities[identity.key] = identity
            }
        }
        guard latestIdentities.count == Int(activeHead.c) else {
            throw AkashicError.invalidManifest
        }
        if activeHead.s == 0 {
            guard latestIdentities.isEmpty, activeHead.r == directoryHeadZeroRoot else {
                throw AkashicError.invalidManifest
            }
        } else {
            guard latestIdentities.values.map(\.sequence).max() == activeHead.s else {
                throw AkashicError.invalidManifest
            }
        }

        var latest: [String: DirectoryHeadLatestRecord] = [:]
        latest.reserveCapacity(latestIdentities.count)
        var calculatedRoot = directoryHeadZeroRoot
        for (key, identity) in latestIdentities {
            let data = try operations.readAttribute(
                identity.name,
                directory,
                maximumManifestRecordBytes
            )
            let record: ManifestRecord
            do {
                record = try JSONDecoder().decode(ManifestRecord.self, from: data)
            } catch {
                throw AkashicError.invalidManifest
            }
            guard record.generation == generation,
                record.sequence == identity.sequence,
                record.persistedKey == nil || record.persistedKey == key,
                directoryHeadRecordMatchesKey(record, key: key)
            else { throw AkashicError.invalidManifest }
            let leaf = try directoryHeadLeaf(identity: identity, recordData: data)
            calculatedRoot = try directoryHeadXor(calculatedRoot, leaf)
            latest[key] = DirectoryHeadLatestRecord(
                identity: identity,
                data: data,
                record: record,
                leaf: leaf
            )
        }
        guard calculatedRoot == activeHead.r else {
            throw AkashicError.invalidManifest
        }

        let latestNames = Set(latest.values.map(\.identity.name))
        var staleCommittedByKey: [String: String] = [:]
        staleCommittedByKey.reserveCapacity(latest.count)
        for identity in records {
            guard identity.sequence <= activeHead.s,
                !latestNames.contains(identity.name)
            else { continue }
            guard staleCommittedByKey.updateValue(identity.name, forKey: identity.key) == nil else {
                // The bounded protocol permits at most one superseded committed body per key.
                throw AkashicError.invalidManifest
            }
        }
        return DirectoryHeadRecoveredState(
            activeSlot: activeSlot,
            activeHead: activeHead,
            latest: latest,
            uncommittedRecordNames: uncommittedNames,
            staleCommittedByKey: staleCommittedByKey
        )
    }

    static func applyDirectoryHeadState(
        _ state: DirectoryHeadRecoveredState,
        to base: Manifest
    ) throws -> Manifest {
        var next = base
        for item in state.latest.values.sorted(by: { $0.record.sequence < $1.record.sequence }) {
            if let entry = item.record.entry {
                next.entries[item.identity.key] = entry
            } else {
                next.entries.removeValue(forKey: item.identity.key)
            }
        }
        return next
    }

    private static func directoryHeadRecordMatchesKey(_ record: ManifestRecord, key: String) -> Bool {
        if let entry = record.entry {
            return key == FileBlobStoreIdentity.manifestKey(
                digest: entry.digest,
                partition: entry.partition
            )
        }
        return record.persistedKey == key
    }
}
