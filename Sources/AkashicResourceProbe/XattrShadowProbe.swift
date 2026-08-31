import AkashicCore
import AkashicDisk
import Darwin
import Foundation

enum XattrShadowError: Error {
    case invalidArguments
    case invalidName
    case invalidRecord
    case duplicateSequence
    case duplicatePhysicalOwnership
    case physicalIdentityMismatch
    case stateMismatch
    case posix(Int32)
}

private struct XattrShadowReport: Codable {
    let schemaVersion: Int
    let status: String
    let generation: UInt64
    let operationCount: Int
    let xattrRecordCount: Int
    let mixedSidecarCount: Int
    let maximumRecordValueBytes: Int
    let maximumXattrNameBytes: Int
    let renameRetainedAttributes: Bool
    let replacementOrderingMatched: Bool
    let mixedTombstoneOrderingMatched: Bool
    let staleCorruptAttributeIgnoredByName: Bool
    let wrongNameKeyRejected: Bool
    let wrongPhysicalIDRejected: Bool
    let duplicateSequenceRejected: Bool
    let futureGenerationRejected: Bool
    let duplicatePhysicalOwnershipRejected: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionAuthorityChanged: Bool
        let productionXattrImplemented: Bool
        let filesystemOrderingProven: Bool
        let physicalDevice: Bool
    }
}

struct ManifestXattrIdentity: Equatable {
    static let prefix = "dev.akashic.manifest-entry-v1.g"

    let generation: UInt64
    let key: String

    var name: String {
        "\(Self.prefix)\(String(format: "%016llx", generation)).\(key)"
    }

    static func parse(_ name: String) -> Self? {
        let bytes = Array(name.utf8)
        let prefix = Array(Self.prefix.utf8)
        guard bytes.count == prefix.count + 16 + 1 + 64,
            bytes.prefix(prefix.count).elementsEqual(prefix),
            bytes[prefix.count + 16] == 46
        else { return nil }
        let generationBytes = bytes[prefix.count ..< (prefix.count + 16)]
        let keyBytes = bytes[(prefix.count + 17) ..< bytes.count]
        guard generationBytes.allSatisfy(isLowercaseHex),
            keyBytes.allSatisfy(isLowercaseHex),
            let generation = UInt64(String(decoding: generationBytes, as: UTF8.self), radix: 16),
            generation > 0
        else { return nil }
        return Self(
            generation: generation,
            key: String(decoding: keyBytes, as: UTF8.self)
        )
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

private struct XattrRecoveredRecord {
    let mutation: FileBlobStoreRecordShadowMutation
    let carrierPhysicalID: PhysicalBlobID?
}

enum XattrShadowProbe {
    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw XattrShadowError.invalidArguments }
        let generation: UInt64 = 23
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-xattr-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let identities = try identityPool(count: 24)
        var expected: [String: FileBlobStoreRecordShadowEntry] = [:]
        var maximumRecordBytes = 0
        var maximumNameBytes = 0
        var sequence: UInt64 = 0
        var operationCount = 0
        var xattrRecordCount = 0

        for round in 0..<4 {
            for index in identities.indices {
                sequence += 1
                operationCount += 1
                let identity = identities[(index + round * 5) % identities.count]
                let physicalID = PhysicalBlobID()
                let entry = FileBlobStoreRecordShadowEntry(
                    physicalID: physicalID,
                    partition: identity.partition,
                    digest: identity.digest,
                    byteCount: identity.byteCount,
                    lastAccess: Date(timeIntervalSinceReferenceDate: Double(sequence))
                )
                let mutation = FileBlobStoreRecordShadowMutation(
                    generation: generation,
                    sequence: sequence,
                    key: identity.key,
                    entry: entry
                )
                let value = try FileBlobStore.resourceProbeEncodeManifestRecord(mutation)
                let name = ManifestXattrIdentity(
                    generation: generation,
                    key: identity.key
                ).name
                maximumRecordBytes = max(maximumRecordBytes, value.count)
                maximumNameBytes = max(maximumNameBytes, name.utf8.count)
                _ = try XattrShadowProbeIO.writeBlobAndPublish(
                    root: root,
                    data: identity.data,
                    physicalID: physicalID,
                    attributes: [(name, value)]
                )
                expected[identity.key] = entry
                xattrRecordCount += 1
            }
        }

        // A stale-generation attribute with deliberately invalid bytes must not be read merely to
        // determine that it lacks current authority.
        let staleIdentity = identities[0]
        let stalePhysicalID = PhysicalBlobID()
        let staleName = ManifestXattrIdentity(
            generation: generation - 1,
            key: staleIdentity.key
        ).name
        let staleURL = try XattrShadowProbeIO.writeBlobAndPublish(
            root: root,
            data: staleIdentity.data,
            physicalID: stalePhysicalID,
            attributes: [(staleName, Data("not-a-record".utf8))]
        )

        let baseRecovery = try recover(
            root: root,
            generation: generation,
            sidecars: []
        )
        guard baseRecovery == expected else { throw XattrShadowError.stateMismatch }

        let renameRetainedAttributes = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .contains { url in
                (try? XattrShadowProbeIO.listAttributes(url).contains(where: {
                    ManifestXattrIdentity.parse($0)?.generation == generation
                })) == true
            }
        guard renameRetainedAttributes else { throw XattrShadowError.stateMismatch }

        let staleCorruptAttributeIgnoredByName = try XattrShadowProbeIO.listAttributes(staleURL)
            .contains(staleName) && baseRecovery == expected

        // Mix a later tombstone sidecar into the same sequence domain. The stale carrier blob can
        // remain physically present; the later tombstone must remove its logical authority.
        sequence += 1
        let tombstoneTarget = identities[3]
        let tombstone = FileBlobStoreRecordShadowMutation(
            generation: generation,
            sequence: sequence,
            key: tombstoneTarget.key,
            entry: nil
        )
        let tombstoneData = try FileBlobStore.resourceProbeEncodeManifestRecord(tombstone)
        var expectedAfterTombstone = expected
        expectedAfterTombstone.removeValue(forKey: tombstoneTarget.key)
        let mixedRecovery = try recover(
            root: root,
            generation: generation,
            sidecars: [tombstoneData]
        )
        let mixedTombstoneOrderingMatched = mixedRecovery == expectedAfterTombstone
        guard mixedTombstoneOrderingMatched else { throw XattrShadowError.stateMismatch }

        let wrongNameKeyRejected = try verifyWrongNameKeyRejected(
            root: root,
            generation: generation,
            identities: identities,
            nextSequence: sequence + 1
        )
        let wrongPhysicalIDRejected = try verifyWrongPhysicalIDRejected(
            root: root,
            generation: generation,
            identity: identities[5],
            nextSequence: sequence + 2
        )
        let duplicateSequenceRejected = try verifyDuplicateSequenceRejected(
            root: root,
            generation: generation,
            identity: identities[6],
            duplicateSequence: sequence
        )
        let futureGenerationRejected = try verifyFutureGenerationRejected(
            root: root,
            generation: generation,
            identity: identities[7],
            nextSequence: sequence + 3
        )
        let duplicatePhysicalOwnershipRejected = try verifyDuplicatePhysicalOwnershipRejected(
            root: root,
            generation: generation,
            identities: identities,
            nextSequence: sequence + 4
        )
        guard wrongNameKeyRejected,
            wrongPhysicalIDRejected,
            duplicateSequenceRejected,
            futureGenerationRejected,
            duplicatePhysicalOwnershipRejected
        else { throw XattrShadowError.stateMismatch }

        let report = XattrShadowReport(
            schemaVersion: 1,
            status: "passed",
            generation: generation,
            operationCount: operationCount,
            xattrRecordCount: xattrRecordCount,
            mixedSidecarCount: 1,
            maximumRecordValueBytes: maximumRecordBytes,
            maximumXattrNameBytes: maximumNameBytes,
            renameRetainedAttributes: renameRetainedAttributes,
            replacementOrderingMatched: baseRecovery == expected,
            mixedTombstoneOrderingMatched: mixedTombstoneOrderingMatched,
            staleCorruptAttributeIgnoredByName: staleCorruptAttributeIgnoredByName,
            wrongNameKeyRejected: wrongNameKeyRejected,
            wrongPhysicalIDRejected: wrongPhysicalIDRejected,
            duplicateSequenceRejected: duplicateSequenceRejected,
            futureGenerationRejected: futureGenerationRejected,
            duplicatePhysicalOwnershipRejected: duplicatePhysicalOwnershipRejected,
            claims: .init(
                productionAuthorityChanged: false,
                productionXattrImplemented: false,
                filesystemOrderingProven: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    struct Identity {
        let key: String
        let partition: CachePartitionID
        let digest: BlobDigest
        let byteCount: Int
        let data: Data
    }

    private static func identityPool(count: Int) throws -> [Identity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "akashic-xattr-shadow-v1",
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("xattr-payload-\(index)-\(String(repeating: "z", count: index % 19))".utf8)
            let digest = BlobDigest.sha256(of: data)
            return Identity(
                key: FileBlobStore.resourceProbeManifestKey(
                    digest: digest,
                    partition: partition
                ),
                partition: partition,
                digest: digest,
                byteCount: data.count,
                data: data
            )
        }
    }

    static func recover(
        root: URL,
        generation: UInt64,
        sidecars: [Data]
    ) throws -> [String: FileBlobStoreRecordShadowEntry] {
        var records: [XattrRecoveredRecord] = []
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in children {
            guard let uuid = UUID(uuidString: url.lastPathComponent) else { continue }
            let carrier = PhysicalBlobID(rawValue: uuid)
            for name in try XattrShadowProbeIO.listAttributes(url) {
                guard let identity = ManifestXattrIdentity.parse(name) else { continue }
                if identity.generation < generation { continue }
                guard identity.generation == generation else {
                    throw XattrShadowError.invalidRecord
                }
                let value = try XattrShadowProbeIO.readAttribute(name, from: url)
                let mutation: FileBlobStoreRecordShadowMutation
                do {
                    mutation = try FileBlobStore.resourceProbeDecodeManifestRecord(value)
                } catch {
                    throw XattrShadowError.invalidRecord
                }
                guard mutation.generation == generation,
                    mutation.key == identity.key,
                    let entry = mutation.entry,
                    entry.physicalID == carrier
                else {
                    if mutation.entry?.physicalID != carrier {
                        throw XattrShadowError.physicalIdentityMismatch
                    }
                    throw XattrShadowError.invalidRecord
                }
                records.append(.init(mutation: mutation, carrierPhysicalID: carrier))
            }
        }
        for data in sidecars {
            let mutation: FileBlobStoreRecordShadowMutation
            do {
                mutation = try FileBlobStore.resourceProbeDecodeManifestRecord(data)
            } catch {
                throw XattrShadowError.invalidRecord
            }
            guard mutation.generation == generation else { throw XattrShadowError.invalidRecord }
            records.append(.init(mutation: mutation, carrierPhysicalID: nil))
        }
        records.sort { $0.mutation.sequence < $1.mutation.sequence }
        var sequences = Set<UInt64>()
        var state: [String: FileBlobStoreRecordShadowEntry] = [:]
        for record in records {
            guard sequences.insert(record.mutation.sequence).inserted else {
                throw XattrShadowError.duplicateSequence
            }
            if let entry = record.mutation.entry {
                state[record.mutation.key] = entry
            } else {
                state.removeValue(forKey: record.mutation.key)
            }
        }
        var physicalIDs = Set<PhysicalBlobID>()
        for entry in state.values {
            guard physicalIDs.insert(entry.physicalID).inserted else {
                throw XattrShadowError.duplicatePhysicalOwnership
            }
        }
        return state
    }

}
