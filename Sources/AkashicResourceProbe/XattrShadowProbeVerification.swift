import AkashicCore
import Foundation

import AkashicDisk

extension XattrShadowProbe {
    static func verifyWrongNameKeyRejected(
        root: URL,
        generation: UInt64,
        identities: [Identity],
        nextSequence: UInt64
    ) throws -> Bool {
        let child = root.appendingPathComponent("wrong-key", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: child) }
        let valueIdentity = identities[0]
        let nameIdentity = identities[1]
        let physicalID = PhysicalBlobID()
        let entry = FileBlobStoreRecordShadowEntry(
            physicalID: physicalID,
            partition: valueIdentity.partition,
            digest: valueIdentity.digest,
            byteCount: valueIdentity.byteCount,
            lastAccess: Date()
        )
        let value = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: generation,
                sequence: nextSequence,
                key: valueIdentity.key,
                entry: entry
            )
        )
        let name = ManifestXattrIdentity(generation: generation, key: nameIdentity.key).name
        _ = try XattrShadowProbeIO.writeBlobAndPublish(
            root: child,
            data: valueIdentity.data,
            physicalID: physicalID,
            attributes: [(name, value)]
        )
        do {
            _ = try recover(root: child, generation: generation, sidecars: [])
            return false
        } catch XattrShadowError.invalidRecord {
            return true
        }
    }

    static func verifyWrongPhysicalIDRejected(
        root: URL,
        generation: UInt64,
        identity: Identity,
        nextSequence: UInt64
    ) throws -> Bool {
        let child = root.appendingPathComponent("wrong-physical", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: child) }
        let carrier = PhysicalBlobID()
        let claimed = PhysicalBlobID()
        let entry = FileBlobStoreRecordShadowEntry(
            physicalID: claimed,
            partition: identity.partition,
            digest: identity.digest,
            byteCount: identity.byteCount,
            lastAccess: Date()
        )
        let value = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: generation,
                sequence: nextSequence,
                key: identity.key,
                entry: entry
            )
        )
        let name = ManifestXattrIdentity(generation: generation, key: identity.key).name
        _ = try XattrShadowProbeIO.writeBlobAndPublish(
            root: child,
            data: identity.data,
            physicalID: carrier,
            attributes: [(name, value)]
        )
        do {
            _ = try recover(root: child, generation: generation, sidecars: [])
            return false
        } catch XattrShadowError.physicalIdentityMismatch {
            return true
        }
    }

    static func verifyDuplicateSequenceRejected(
        root: URL,
        generation: UInt64,
        identity: Identity,
        duplicateSequence: UInt64
    ) throws -> Bool {
        let child = root.appendingPathComponent("duplicate-sequence", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: child) }
        let physicalID = PhysicalBlobID()
        let entry = FileBlobStoreRecordShadowEntry(
            physicalID: physicalID,
            partition: identity.partition,
            digest: identity.digest,
            byteCount: identity.byteCount,
            lastAccess: Date()
        )
        let value = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: generation,
                sequence: duplicateSequence,
                key: identity.key,
                entry: entry
            )
        )
        let name = ManifestXattrIdentity(generation: generation, key: identity.key).name
        _ = try XattrShadowProbeIO.writeBlobAndPublish(
            root: child,
            data: identity.data,
            physicalID: physicalID,
            attributes: [(name, value)]
        )
        let tombstone = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: generation,
                sequence: duplicateSequence,
                key: identity.key,
                entry: nil
            )
        )
        do {
            _ = try recover(root: child, generation: generation, sidecars: [tombstone])
            return false
        } catch XattrShadowError.duplicateSequence {
            return true
        }
    }

    static func verifyFutureGenerationRejected(
        root: URL,
        generation: UInt64,
        identity: Identity,
        nextSequence: UInt64
    ) throws -> Bool {
        let child = root.appendingPathComponent("future-generation", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: child) }
        let physicalID = PhysicalBlobID()
        let future = generation + 1
        let entry = FileBlobStoreRecordShadowEntry(
            physicalID: physicalID,
            partition: identity.partition,
            digest: identity.digest,
            byteCount: identity.byteCount,
            lastAccess: Date()
        )
        let value = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: future,
                sequence: nextSequence,
                key: identity.key,
                entry: entry
            )
        )
        let name = ManifestXattrIdentity(generation: future, key: identity.key).name
        _ = try XattrShadowProbeIO.writeBlobAndPublish(
            root: child,
            data: identity.data,
            physicalID: physicalID,
            attributes: [(name, value)]
        )
        do {
            _ = try recover(root: child, generation: generation, sidecars: [])
            return false
        } catch XattrShadowError.invalidRecord {
            return true
        }
    }

    static func verifyDuplicatePhysicalOwnershipRejected(
        root: URL,
        generation: UInt64,
        identities: [Identity],
        nextSequence: UInt64
    ) throws -> Bool {
        // Xattr create records are carrier-bound, so two distinct current files cannot honestly claim
        // one physical UUID. The equivalent final-state ownership attack therefore uses a later
        // sidecar create record that claims an already-current xattr carrier.
        let child = root.appendingPathComponent("duplicate-physical", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: child) }
        let first = identities[0]
        let second = identities[1]
        let shared = PhysicalBlobID()
        let xattrEntry = FileBlobStoreRecordShadowEntry(
            physicalID: shared,
            partition: first.partition,
            digest: first.digest,
            byteCount: first.byteCount,
            lastAccess: Date()
        )
        let xattrValue = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: generation,
                sequence: nextSequence,
                key: first.key,
                entry: xattrEntry
            )
        )
        _ = try XattrShadowProbeIO.writeBlobAndPublish(
            root: child,
            data: first.data,
            physicalID: shared,
            attributes: [(
                ManifestXattrIdentity(generation: generation, key: first.key).name,
                xattrValue
            )]
        )
        let sidecarEntry = FileBlobStoreRecordShadowEntry(
            physicalID: shared,
            partition: second.partition,
            digest: second.digest,
            byteCount: second.byteCount,
            lastAccess: Date()
        )
        let sidecar = try FileBlobStore.resourceProbeEncodeManifestRecord(
            .init(
                generation: generation,
                sequence: nextSequence + 1,
                key: second.key,
                entry: sidecarEntry
            )
        )
        do {
            _ = try recover(root: child, generation: generation, sidecars: [sidecar])
            return false
        } catch XattrShadowError.duplicatePhysicalOwnership {
            return true
        }
    }
}
