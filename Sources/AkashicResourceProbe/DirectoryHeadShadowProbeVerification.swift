import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Dispatch
import Foundation

extension DirectoryHeadShadowProbe {
    static func verifyCurrentRecordDeletionRejected(
        root: URL,
        generation: UInt64
    ) throws -> Bool {
        let recovered = try recover(root: root, generation: generation, base: [:])
        guard let latest = recovered.latest.values.first else { return false }
        try DirectoryHeadShadowIO.removeAttribute(latest.identity.name, at: root)
        let rejected = rejectsRecovery(root: root, generation: generation)
        try DirectoryHeadShadowIO.setAttribute(
            latest.identity.name,
            value: latest.data,
            at: root,
            flags: XATTR_CREATE
        )
        try DirectoryHeadShadowIO.synchronize(root)
        return rejected
    }

    static func verifyCurrentRecordCorruptionRejected(
        root: URL,
        generation: UInt64
    ) throws -> Bool {
        let recovered = try recover(root: root, generation: generation, base: [:])
        guard let latest = recovered.latest.values.dropFirst().first ?? recovered.latest.values.first else {
            return false
        }
        try DirectoryHeadShadowIO.setAttribute(
            latest.identity.name,
            value: Data("corrupt-current-record".utf8),
            at: root,
            flags: XATTR_REPLACE
        )
        let rejected = rejectsRecovery(root: root, generation: generation)
        try DirectoryHeadShadowIO.setAttribute(
            latest.identity.name,
            value: latest.data,
            at: root,
            flags: XATTR_REPLACE
        )
        try DirectoryHeadShadowIO.synchronize(root)
        return rejected
    }

    static func verifyStaleRecordCorruptionIgnored(
        root: URL,
        generation: UInt64,
        expected: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> Bool {
        let recovered = try recover(root: root, generation: generation, base: [:])
        for identity in recovered.recordIdentities {
            guard let current = recovered.latest[identity.key],
                identity.sequence < current.identity.sequence
            else { continue }
            let old = try XattrShadowProbeIO.readAttribute(identity.name, from: root)
            try DirectoryHeadShadowIO.setAttribute(
                identity.name,
                value: Data("corrupt-stale-record".utf8),
                at: root,
                flags: XATTR_REPLACE
            )
            let matched = try recover(root: root, generation: generation, base: [:]).logical == expected
            try DirectoryHeadShadowIO.setAttribute(
                identity.name,
                value: old,
                at: root,
                flags: XATTR_REPLACE
            )
            try DirectoryHeadShadowIO.synchronize(root)
            return matched
        }
        return false
    }

    static func verifyUncommittedCorruptionIgnored(
        root: URL,
        generation: UInt64,
        identity: Identity,
        expected: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> Bool {
        let recovered = try recover(root: root, generation: generation, base: [:])
        let sequence = recovered.activeHead.s + 1
        let recordIdentity = try DirectoryHeadRecordIdentity.make(
            generation: generation,
            sequence: sequence,
            key: identity.key
        )
        try DirectoryHeadShadowIO.setAttribute(
            recordIdentity.name,
            value: Data("corrupt-uncommitted-record".utf8),
            at: root,
            flags: XATTR_CREATE
        )
        let matched = try recover(root: root, generation: generation, base: [:]).logical == expected
        try DirectoryHeadShadowIO.removeAttribute(recordIdentity.name, at: root)
        try DirectoryHeadShadowIO.synchronize(root)
        return matched
    }

    static func verifyHeadDeletionRejected(root: URL, generation: UInt64) throws -> Bool {
        for slot: UInt8 in [0, 1] {
            let name = DirectoryHeadIdentity(generation: generation, slot: slot).name
            let old = try XattrShadowProbeIO.readAttribute(name, from: root)
            try DirectoryHeadShadowIO.removeAttribute(name, at: root)
            let rejected = rejectsRecovery(root: root, generation: generation)
            try DirectoryHeadShadowIO.setAttribute(name, value: old, at: root, flags: XATTR_CREATE)
            try DirectoryHeadShadowIO.synchronize(root)
            guard rejected else { return false }
        }
        return true
    }

    static func verifyHeadCorruptionRejected(root: URL, generation: UInt64) throws -> Bool {
        for slot: UInt8 in [0, 1] {
            let name = DirectoryHeadIdentity(generation: generation, slot: slot).name
            let old = try XattrShadowProbeIO.readAttribute(name, from: root)
            try DirectoryHeadShadowIO.setAttribute(
                name,
                value: Data("corrupt-head".utf8),
                at: root,
                flags: XATTR_REPLACE
            )
            let rejected = rejectsRecovery(root: root, generation: generation)
            try DirectoryHeadShadowIO.setAttribute(name, value: old, at: root, flags: XATTR_REPLACE)
            try DirectoryHeadShadowIO.synchronize(root)
            guard rejected else { return false }
        }
        return true
    }

    static func verifyDuplicateSequenceRejected(
        root: URL,
        generation: UInt64,
        freshIdentity: Identity
    ) throws -> Bool {
        let recovered = try recover(root: root, generation: generation, base: [:])
        guard recovered.activeHead.s > 0 else { return false }
        let identity = try DirectoryHeadRecordIdentity.make(
            generation: generation,
            sequence: recovered.activeHead.s,
            key: freshIdentity.key
        )
        if recovered.recordIdentities.contains(identity) { return false }
        try DirectoryHeadShadowIO.setAttribute(
            identity.name,
            value: Data("duplicate-sequence".utf8),
            at: root,
            flags: XATTR_CREATE
        )
        let rejected = rejectsRecovery(root: root, generation: generation)
        try DirectoryHeadShadowIO.removeAttribute(identity.name, at: root)
        return rejected
    }

    static func verifyFutureGenerationRejected(
        root: URL,
        generation: UInt64,
        identity: Identity
    ) throws -> Bool {
        let future = try DirectoryHeadRecordIdentity.make(
            generation: generation + 1,
            sequence: 1,
            key: identity.key
        )
        try DirectoryHeadShadowIO.setAttribute(
            future.name,
            value: Data("future-generation".utf8),
            at: root,
            flags: XATTR_CREATE
        )
        let rejected = rejectsRecovery(root: root, generation: generation)
        try DirectoryHeadShadowIO.removeAttribute(future.name, at: root)
        return rejected
    }

    static func verifyMalformedBase32Rejected(root: URL, generation: UInt64) throws -> Bool {
        let name = "dev.akashic.md1.g\(String(format: "%016llx", generation)).s0000000000000001.\(String(repeating: "!", count: 52))"
        try DirectoryHeadShadowIO.setAttribute(
            name,
            value: Data("malformed-name".utf8),
            at: root,
            flags: XATTR_CREATE
        )
        let rejected = rejectsRecovery(root: root, generation: generation)
        try DirectoryHeadShadowIO.removeAttribute(name, at: root)
        return rejected
    }

    static func verifyKeyBodyMismatchRejected(
        parent: URL,
        generation: UInt64,
        identities: (Identity, Identity)
    ) throws -> Bool {
        let root = parent.appendingPathComponent("key-mismatch", isDirectory: true)
        try createPrivateDirectory(root)
        try initializeHeads(root: root, generation: generation)
        let entry = FileBlobStoreRecordShadowEntry(
            physicalID: PhysicalBlobID(),
            partition: identities.0.partition,
            digest: identities.0.digest,
            byteCount: identities.0.byteCount,
            lastAccess: Date()
        )
        let mutation = FileBlobStoreRecordShadowMutation(
            generation: generation,
            sequence: 1,
            key: identities.0.key,
            entry: entry
        )
        let data = try FileBlobStore.resourceProbeEncodeManifestRecord(mutation)
        let nameIdentity = try DirectoryHeadRecordIdentity.make(
            generation: generation,
            sequence: 1,
            key: identities.1.key
        )
        try DirectoryHeadShadowIO.setAttribute(nameIdentity.name, value: data, at: root, flags: XATTR_CREATE)
        let head = try makeHead(
            generation: generation,
            slot: 1,
            sequence: 1,
            count: 1,
            root: try leaf(identity: nameIdentity, recordData: data)
        )
        try writeHead(head, at: root, create: false)
        try DirectoryHeadShadowIO.synchronize(root)
        return rejectsRecovery(root: root, generation: generation)
    }

    static func verifyDuplicatePhysicalOwnershipRejected(
        parent: URL,
        generation: UInt64,
        identities: (Identity, Identity)
    ) throws -> Bool {
        let root = parent.appendingPathComponent("duplicate-physical", isDirectory: true)
        try createPrivateDirectory(root)
        try initializeHeads(root: root, generation: generation)
        let shared = PhysicalBlobID()
        let first = FileBlobStoreRecordShadowEntry(
            physicalID: shared,
            partition: identities.0.partition,
            digest: identities.0.digest,
            byteCount: identities.0.byteCount,
            lastAccess: Date(timeIntervalSinceReferenceDate: 1)
        )
        _ = try performMutation(root: root, generation: generation, key: identities.0.key, entry: first)

        let recovered = try recover(root: root, generation: generation, base: [:])
        let second = FileBlobStoreRecordShadowEntry(
            physicalID: shared,
            partition: identities.1.partition,
            digest: identities.1.digest,
            byteCount: identities.1.byteCount,
            lastAccess: Date(timeIntervalSinceReferenceDate: 2)
        )
        let sequence = recovered.activeHead.s + 1
        let mutation = FileBlobStoreRecordShadowMutation(
            generation: generation,
            sequence: sequence,
            key: identities.1.key,
            entry: second
        )
        let data = try FileBlobStore.resourceProbeEncodeManifestRecord(mutation)
        let recordIdentity = try DirectoryHeadRecordIdentity.make(
            generation: generation,
            sequence: sequence,
            key: identities.1.key
        )
        try DirectoryHeadShadowIO.setAttribute(recordIdentity.name, value: data, at: root, flags: XATTR_CREATE)
        var rootCommitment = recovered.activeHead.r
        rootCommitment = xor(rootCommitment, try leaf(identity: recordIdentity, recordData: data))
        let inactive: UInt8 = recovered.activeSlot == 0 ? 1 : 0
        let head = try makeHead(
            generation: generation,
            slot: inactive,
            sequence: sequence,
            count: Int(recovered.activeHead.c) + 1,
            root: rootCommitment
        )
        try writeHead(head, at: root, create: false)
        try DirectoryHeadShadowIO.synchronize(root)
        return rejectsRecovery(root: root, generation: generation)
    }

    static func initializeHeads(root: URL, generation: UInt64) throws {
        try writeHead(
            try makeHead(generation: generation, slot: 0, sequence: 0, count: 0, root: zeroRoot),
            at: root,
            create: true
        )
        try writeHead(
            try makeHead(generation: generation, slot: 1, sequence: 0, count: 0, root: zeroRoot),
            at: root,
            create: true
        )
        try DirectoryHeadShadowIO.synchronize(root)
    }

    static func rejectsRecovery(root: URL, generation: UInt64) -> Bool {
        do {
            _ = try recover(root: root, generation: generation, base: [:])
            return false
        } catch {
            return true
        }
    }
}
