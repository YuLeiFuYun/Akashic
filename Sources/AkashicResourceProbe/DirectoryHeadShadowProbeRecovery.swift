import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Dispatch
import Foundation

extension DirectoryHeadShadowProbe {
    static func recover(
        root: URL,
        generation: UInt64,
        base: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> DirectoryHeadRecovered {
        let names = try XattrShadowProbeIO.listAttributes(root)
        var headNames: [UInt8: String] = [:]
        var records: [DirectoryHeadRecordIdentity] = []

        for name in names {
            if let headIdentity = try DirectoryHeadIdentity.parse(name) {
                if headIdentity.generation < generation { continue }
                guard headIdentity.generation == generation else {
                    throw DirectoryHeadShadowError.invalidHead
                }
                guard headNames[headIdentity.slot] == nil else {
                    throw DirectoryHeadShadowError.invalidHead
                }
                headNames[headIdentity.slot] = name
                continue
            }
            if let recordIdentity = try DirectoryHeadRecordIdentity.parse(name) {
                if recordIdentity.generation < generation { continue }
                guard recordIdentity.generation == generation else {
                    throw DirectoryHeadShadowError.invalidRecord
                }
                records.append(recordIdentity)
            }
        }

        guard let head0Name = headNames[0],
            let head1Name = headNames[1],
            headNames.count == 2
        else { throw DirectoryHeadShadowError.invalidHead }
        let head0 = try decodeHead(
            try XattrShadowProbeIO.readAttribute(head0Name, from: root),
            expected: DirectoryHeadIdentity(generation: generation, slot: 0)
        )
        let head1 = try decodeHead(
            try XattrShadowProbeIO.readAttribute(head1Name, from: root),
            expected: DirectoryHeadIdentity(generation: generation, slot: 1)
        )
        let activeSlot: UInt8
        let activeHead: DirectoryHeadValue
        if head0.s == head1.s {
            guard head0.s == 0,
                head0.c == 0,
                head1.c == 0,
                head0.r == zeroRoot,
                head1.r == zeroRoot
            else { throw DirectoryHeadShadowError.invalidHead }
            activeSlot = 0
            activeHead = head0
        } else if head0.s > head1.s {
            activeSlot = 0
            activeHead = head0
        } else {
            activeSlot = 1
            activeHead = head1
        }

        let eligible = records.filter { $0.sequence <= activeHead.s }
        var sequences = Set<UInt64>()
        var latestIdentities: [String: DirectoryHeadRecordIdentity] = [:]
        for identity in eligible {
            guard sequences.insert(identity.sequence).inserted else {
                throw DirectoryHeadShadowError.duplicateSequence
            }
            if let old = latestIdentities[identity.key] {
                if identity.sequence > old.sequence { latestIdentities[identity.key] = identity }
            } else {
                latestIdentities[identity.key] = identity
            }
        }

        guard latestIdentities.count == Int(activeHead.c) else {
            throw DirectoryHeadShadowError.invalidHead
        }
        if activeHead.s == 0 {
            guard latestIdentities.isEmpty, activeHead.r == zeroRoot else {
                throw DirectoryHeadShadowError.invalidHead
            }
        } else {
            guard latestIdentities.values.map(\.sequence).max() == activeHead.s else {
                throw DirectoryHeadShadowError.invalidHead
            }
        }

        var latest: [String: DirectoryHeadLatest] = [:]
        var calculatedRoot = zeroRoot
        for (key, identity) in latestIdentities {
            let data = try XattrShadowProbeIO.readAttribute(identity.name, from: root)
            let mutation: FileBlobStoreRecordShadowMutation
            do {
                mutation = try FileBlobStore.resourceProbeDecodeManifestRecord(data)
            } catch {
                throw DirectoryHeadShadowError.invalidRecord
            }
            guard mutation.generation == generation,
                mutation.sequence == identity.sequence,
                mutation.key == key
            else { throw DirectoryHeadShadowError.invalidRecord }
            let recordLeaf = try leaf(identity: identity, recordData: data)
            calculatedRoot = xor(calculatedRoot, recordLeaf)
            latest[key] = DirectoryHeadLatest(
                identity: identity,
                data: data,
                mutation: mutation,
                leaf: recordLeaf
            )
        }
        guard calculatedRoot == activeHead.r else {
            throw DirectoryHeadShadowError.invalidHead
        }

        var logical = base
        for item in latest.values.sorted(by: { $0.mutation.sequence < $1.mutation.sequence }) {
            if let entry = item.mutation.entry {
                logical[item.mutation.key] = entry
            } else {
                logical.removeValue(forKey: item.mutation.key)
            }
        }
        var physicalIDs = Set<PhysicalBlobID>()
        for entry in logical.values {
            guard physicalIDs.insert(entry.physicalID).inserted else {
                throw DirectoryHeadShadowError.duplicatePhysicalOwnership
            }
        }
        return DirectoryHeadRecovered(
            logical: logical,
            latest: latest,
            activeSlot: activeSlot,
            activeHead: activeHead,
            recordIdentities: records
        )
    }

    static func makeHead(
        generation: UInt64,
        slot: UInt8,
        sequence: UInt64,
        count: Int,
        root: Data
    ) throws -> DirectoryHeadValue {
        guard generation > 0,
            slot <= 1,
            count >= 0,
            count <= 511,
            root.count == 32,
            let compactCount = UInt16(exactly: count)
        else { throw DirectoryHeadShadowError.invalidHead }
        let checksum = headChecksum(
            version: headVersion,
            generation: generation,
            slot: slot,
            sequence: sequence,
            count: compactCount,
            root: root
        )
        return DirectoryHeadValue(
            v: headVersion,
            g: generation,
            p: slot,
            s: sequence,
            c: compactCount,
            r: root,
            h: checksum
        )
    }

    static func headChecksum(
        version: UInt16,
        generation: UInt64,
        slot: UInt8,
        sequence: UInt64,
        count: UInt16,
        root: Data
    ) -> Data {
        var data = Data("akashic-directory-head-v1\u{0}".utf8)
        appendBigEndian(version, to: &data)
        appendBigEndian(generation, to: &data)
        data.append(slot)
        appendBigEndian(sequence, to: &data)
        appendBigEndian(count, to: &data)
        data.append(root)
        return Data(SHA256.hash(data: data))
    }

    static func encodeHead(_ head: DirectoryHeadValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(head)
    }

    static func decodeHead(
        _ data: Data,
        expected identity: DirectoryHeadIdentity
    ) throws -> DirectoryHeadValue {
        let head: DirectoryHeadValue
        do {
            head = try JSONDecoder().decode(DirectoryHeadValue.self, from: data)
        } catch {
            throw DirectoryHeadShadowError.invalidHead
        }
        guard head.v == headVersion,
            head.g == identity.generation,
            head.p == identity.slot,
            head.c <= 511,
            head.r.count == 32,
            head.h.count == 32,
            head.h == headChecksum(
                version: head.v,
                generation: head.g,
                slot: head.p,
                sequence: head.s,
                count: head.c,
                root: head.r
            )
        else { throw DirectoryHeadShadowError.invalidHead }
        return head
    }

    static func writeHead(
        _ head: DirectoryHeadValue,
        at root: URL,
        create: Bool
    ) throws {
        let identity = DirectoryHeadIdentity(generation: head.g, slot: head.p)
        try DirectoryHeadShadowIO.setAttribute(
            identity.name,
            value: try encodeHead(head),
            at: root,
            flags: create ? XATTR_CREATE : XATTR_REPLACE
        )
    }

    static func leaf(
        identity: DirectoryHeadRecordIdentity,
        recordData: Data
    ) throws -> Data {
        var input = Data("akashic-directory-record-leaf-v1\u{0}".utf8)
        appendBigEndian(identity.generation, to: &input)
        appendBigEndian(identity.sequence, to: &input)
        input.append(try DirectoryHeadRecordIdentity.keyBytes(identity.key))
        input.append(Data(SHA256.hash(data: recordData)))
        return Data(SHA256.hash(data: input))
    }

    static func xor(_ lhs: Data, _ rhs: Data) -> Data {
        precondition(lhs.count == rhs.count)
        return Data(zip(lhs, rhs).map { $0 ^ $1 })
    }

    static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
