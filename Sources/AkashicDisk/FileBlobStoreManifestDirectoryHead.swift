import AkashicCore
import CryptoKit
import Darwin
import Foundation

package struct FileBlobStoreDirectoryHeadOperations: @unchecked Sendable {
    package let listAttributes: @Sendable (URL, Int) throws -> [String]
    package let readAttribute: @Sendable (String, URL, Int) throws -> Data
    package let setAttribute: @Sendable (String, Data, URL, Int32) throws -> Void
    package let removeAttribute: @Sendable (String, URL) throws -> Void
    package let synchronizeDirectory: @Sendable (URL) throws -> Void

    package init(
        listAttributes: @escaping @Sendable (URL, Int) throws -> [String],
        readAttribute: @escaping @Sendable (String, URL, Int) throws -> Data,
        setAttribute: @escaping @Sendable (String, Data, URL, Int32) throws -> Void,
        removeAttribute: @escaping @Sendable (String, URL) throws -> Void,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.listAttributes = listAttributes
        self.readAttribute = readAttribute
        self.setAttribute = setAttribute
        self.removeAttribute = removeAttribute
        self.synchronizeDirectory = synchronizeDirectory
    }

    package static let system = FileBlobStoreDirectoryHeadOperations(
        listAttributes: { url, maximumBytes in
            try FileBlobStore.directoryHeadListAttributes(
                at: url,
                maximumBytes: maximumBytes
            )
        },
        readAttribute: { name, url, maximumBytes in
            try FileBlobStore.directoryHeadReadAttribute(
                name,
                from: url,
                maximumBytes: maximumBytes
            )
        },
        setAttribute: { name, value, url, flags in
            try FileBlobStore.directoryHeadSetAttribute(
                name,
                value: value,
                at: url,
                flags: flags
            )
        },
        removeAttribute: { name, url in
            try FileBlobStore.directoryHeadRemoveAttribute(name, at: url)
        },
        synchronizeDirectory: { url in
            try FileBlobStore.directoryHeadSynchronizeDirectory(url)
        }
    )
}

extension FileBlobStore {
    enum DeltaCarrierProfile: String, Codable, Sendable {
        /// Directory-head carrier whose root snapshot is protected by a semantic SHA-256
        /// corruption seal. The seal is not keyed authentication; it detects non-coherent on-disk
        /// mutation of the schema/profile/generation/compact-entry transcript.
        case directoryHeadV2 = "directory-head-v2"
    }

    struct DirectoryHeadRecordIdentity: Equatable, Hashable, Sendable {
        private static let familyPrefix = "dev.akashic.md1."
        private static let namePrefix = "dev.akashic.md1.g"
        private static let lowercaseBase32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

        let generation: UInt64
        let sequence: UInt64
        let key: String

        var name: String {
            let keyBytes = Self.decodeManifestKey(key)!
            return "\(Self.namePrefix)\(Self.hex16(generation)).s\(Self.hex16(sequence)).\(Self.base32(keyBytes))"
        }

        static func make(generation: UInt64, sequence: UInt64, key: String) throws -> Self {
            guard generation > 0,
                sequence > 0,
                let keyBytes = decodeManifestKey(key),
                keyBytes.count == 32
            else { throw AkashicError.invalidManifest }
            let encoded = base32(keyBytes)
            guard encoded.utf8.count == 52,
                decodeBase32(encoded) == keyBytes
            else { throw AkashicError.invalidManifest }
            return Self(generation: generation, sequence: sequence, key: key)
        }

        static func parse(_ name: String) throws -> Self? {
            guard name.hasPrefix(familyPrefix) else { return nil }
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 6,
                parts[0] == "dev",
                parts[1] == "akashic",
                parts[2] == "md1",
                parts[3].first == "g",
                parts[4].first == "s",
                let generation = parseHex16(parts[3].dropFirst()),
                generation > 0,
                let sequence = parseHex16(parts[4].dropFirst()),
                sequence > 0,
                let keyBytes = decodeBase32(String(parts[5])),
                keyBytes.count == 32
            else { throw AkashicError.invalidManifest }
            let identity = Self(
                generation: generation,
                sequence: sequence,
                key: encodeManifestKey(keyBytes)
            )
            guard identity.name == name else { throw AkashicError.invalidManifest }
            return identity
        }

        static func keyBytes(_ key: String) throws -> Data {
            guard let data = decodeManifestKey(key), data.count == 32 else {
                throw AkashicError.invalidManifest
            }
            return data
        }

        private static func parseHex16(_ text: Substring) -> UInt64? {
            let bytes = Array(text.utf8)
            guard bytes.count == 16,
                bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return nil }
            return UInt64(String(decoding: bytes, as: UTF8.self), radix: 16)
        }

        private static func hex16(_ value: UInt64) -> String {
            let table = Array("0123456789abcdef".utf8)
            var output = [UInt8](repeating: 48, count: 16)
            var remaining = value
            for index in stride(from: 15, through: 0, by: -1) {
                output[index] = table[Int(remaining & 0x0F)]
                remaining >>= 4
            }
            return String(decoding: output, as: UTF8.self)
        }

        private static func decodeManifestKey(_ key: String) -> Data? {
            let bytes = Array(key.utf8)
            guard bytes.count == 64 else { return nil }
            var result = Data(capacity: 32)
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                guard let high = hexNibble(bytes[offset]),
                    let low = hexNibble(bytes[offset + 1])
                else { return nil }
                result.append((high << 4) | low)
            }
            return result
        }

        private static func encodeManifestKey(_ data: Data) -> String {
            let table = Array("0123456789abcdef".utf8)
            var output = [UInt8]()
            output.reserveCapacity(data.count * 2)
            for byte in data {
                output.append(table[Int(byte >> 4)])
                output.append(table[Int(byte & 0x0F)])
            }
            return String(decoding: output, as: UTF8.self)
        }

        private static func hexNibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 97...102: byte - 87
            default: nil
            }
        }

        private static func base32(_ data: Data) -> String {
            var output = [UInt8]()
            output.reserveCapacity((data.count * 8 + 4) / 5)
            var buffer: UInt32 = 0
            var bits = 0
            for byte in data {
                buffer = (buffer << 8) | UInt32(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    output.append(
                        lowercaseBase32Alphabet[Int((buffer >> UInt32(bits)) & 31)]
                    )
                }
                if bits == 0 {
                    buffer = 0
                } else {
                    buffer &= (UInt32(1) << UInt32(bits)) - 1
                }
            }
            if bits > 0 {
                output.append(
                    lowercaseBase32Alphabet[Int((buffer << UInt32(5 - bits)) & 31)]
                )
            }
            return String(decoding: output, as: UTF8.self)
        }

        private static func decodeBase32(_ text: String) -> Data? {
            let bytes = Array(text.utf8)
            guard bytes.count == 52 else { return nil }
            var output = Data(capacity: 32)
            var buffer: UInt32 = 0
            var bits = 0
            for byte in bytes {
                let value: UInt8
                switch byte {
                case 97...122:
                    let index = Int(byte - 97)
                    guard index < 26 else { return nil }
                    value = UInt8(index)
                case 50...55:
                    value = 26 + (byte - 50)
                default:
                    return nil
                }
                buffer = (buffer << 5) | UInt32(value)
                bits += 5
                while bits >= 8 {
                    bits -= 8
                    output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
                }
                if bits == 0 {
                    buffer = 0
                } else {
                    buffer &= (UInt32(1) << UInt32(bits)) - 1
                }
            }
            guard output.count == 32,
                bits == 4,
                buffer == 0
            else { return nil }
            return output
        }
    }

    struct DirectoryHeadIdentity: Equatable, Hashable, Sendable {
        private static let familyPrefix = "dev.akashic.mh1."
        private static let namePrefix = "dev.akashic.mh1.g"

        let generation: UInt64
        let slot: UInt8

        var name: String {
            "\(Self.namePrefix)\(Self.hex16(generation)).\(slot)"
        }

        static func parse(_ name: String) throws -> Self? {
            guard name.hasPrefix(familyPrefix) else { return nil }
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 5,
                parts[0] == "dev",
                parts[1] == "akashic",
                parts[2] == "mh1",
                parts[3].first == "g",
                let generation = parseHex16(parts[3].dropFirst()),
                generation > 0,
                let slot = UInt8(parts[4]),
                slot <= 1
            else { throw AkashicError.invalidManifest }
            let identity = Self(generation: generation, slot: slot)
            guard identity.name == name else { throw AkashicError.invalidManifest }
            return identity
        }

        private static func parseHex16(_ text: Substring) -> UInt64? {
            let bytes = Array(text.utf8)
            guard bytes.count == 16,
                bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { return nil }
            return UInt64(String(decoding: bytes, as: UTF8.self), radix: 16)
        }

        private static func hex16(_ value: UInt64) -> String {
            let table = Array("0123456789abcdef".utf8)
            var output = [UInt8](repeating: 48, count: 16)
            var remaining = value
            for index in stride(from: 15, through: 0, by: -1) {
                output[index] = table[Int(remaining & 0x0F)]
                remaining >>= 4
            }
            return String(decoding: output, as: UTF8.self)
        }
    }

    struct DirectoryHeadValue: Codable, Equatable, Sendable {
        let v: UInt16
        let g: UInt64
        let p: UInt8
        let s: UInt64
        let c: UInt16
        let r: Data
        let h: Data
    }

    struct DirectoryHeadLatestRecord: Sendable {
        let identity: DirectoryHeadRecordIdentity
        let data: Data
        let record: ManifestRecord
        let leaf: Data
    }

    struct DirectoryHeadRecoveredState: Sendable {
        var activeSlot: UInt8
        var activeHead: DirectoryHeadValue
        var latest: [String: DirectoryHeadLatestRecord]
        var uncommittedRecordNames: [String]
        var staleCommittedByKey: [String: String]

        var staleCommittedRecordNames: [String] {
            staleCommittedByKey.values.sorted()
        }
    }

    static let directoryHeadVersion: UInt16 = 1
    package static let maximumDirectoryHeadXattrListBytes = 512 * 1024
    static let maximumDirectoryHeadValueBytes = 4096
    static let directoryHeadZeroRoot = Data(repeating: 0, count: 32)

    static func makeDirectoryHead(
        generation: UInt64,
        slot: UInt8,
        sequence: UInt64,
        count: Int,
        root: Data
    ) throws -> DirectoryHeadValue {
        guard generation > 0,
            slot <= 1,
            (0..<manifestCheckpointRecordLimit).contains(count),
            root.count == 32,
            let compactCount = UInt16(exactly: count)
        else { throw AkashicError.invalidManifest }
        let checksum = directoryHeadChecksum(
            version: directoryHeadVersion,
            generation: generation,
            slot: slot,
            sequence: sequence,
            count: compactCount,
            root: root
        )
        return DirectoryHeadValue(
            v: directoryHeadVersion,
            g: generation,
            p: slot,
            s: sequence,
            c: compactCount,
            r: root,
            h: checksum
        )
    }

    static func initialDirectoryHeads(generation: UInt64) throws -> (
        DirectoryHeadValue,
        DirectoryHeadValue
    ) {
        (
            try makeDirectoryHead(
                generation: generation,
                slot: 0,
                sequence: 0,
                count: 0,
                root: directoryHeadZeroRoot
            ),
            try makeDirectoryHead(
                generation: generation,
                slot: 1,
                sequence: 0,
                count: 0,
                root: directoryHeadZeroRoot
            )
        )
    }

    static func encodeDirectoryHead(_ head: DirectoryHeadValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(head)
        guard data.count <= maximumDirectoryHeadValueBytes else {
            throw AkashicError.invalidManifest
        }
        return data
    }

    static func decodeDirectoryHead(
        _ data: Data,
        expected identity: DirectoryHeadIdentity
    ) throws -> DirectoryHeadValue {
        guard data.count <= maximumDirectoryHeadValueBytes else {
            throw AkashicError.invalidManifest
        }
        let head: DirectoryHeadValue
        do {
            head = try JSONDecoder().decode(DirectoryHeadValue.self, from: data)
        } catch {
            throw AkashicError.invalidManifest
        }
        guard head.v == directoryHeadVersion,
            head.g == identity.generation,
            head.p == identity.slot,
            head.c < manifestCheckpointRecordLimit,
            head.r.count == 32,
            head.h.count == 32,
            head.h == directoryHeadChecksum(
                version: head.v,
                generation: head.g,
                slot: head.p,
                sequence: head.s,
                count: head.c,
                root: head.r
            )
        else { throw AkashicError.invalidManifest }
        return head
    }

    static func directoryHeadLeaf(
        identity: DirectoryHeadRecordIdentity,
        recordData: Data
    ) throws -> Data {
        var input = Data("akashic-directory-record-leaf-v1\u{0}".utf8)
        appendDirectoryHeadBigEndian(identity.generation, to: &input)
        appendDirectoryHeadBigEndian(identity.sequence, to: &input)
        input.append(try DirectoryHeadRecordIdentity.keyBytes(identity.key))
        input.append(Data(SHA256.hash(data: recordData)))
        return Data(SHA256.hash(data: input))
    }

    static func directoryHeadXor(_ lhs: Data, _ rhs: Data) throws -> Data {
        guard lhs.count == 32, rhs.count == 32 else { throw AkashicError.invalidManifest }
        return Data(zip(lhs, rhs).map { $0 ^ $1 })
    }

    private static func directoryHeadChecksum(
        version: UInt16,
        generation: UInt64,
        slot: UInt8,
        sequence: UInt64,
        count: UInt16,
        root: Data
    ) -> Data {
        var data = Data("akashic-directory-head-v1\u{0}".utf8)
        appendDirectoryHeadBigEndian(version, to: &data)
        appendDirectoryHeadBigEndian(generation, to: &data)
        data.append(slot)
        appendDirectoryHeadBigEndian(sequence, to: &data)
        appendDirectoryHeadBigEndian(count, to: &data)
        data.append(root)
        return Data(SHA256.hash(data: data))
    }

    private static func appendDirectoryHeadBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }


}
