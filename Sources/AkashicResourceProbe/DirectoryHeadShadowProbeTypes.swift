import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Dispatch
import Foundation

enum DirectoryHeadShadowError: Error {
    case invalidArguments
    case invalidName
    case invalidHead
    case invalidRecord
    case duplicateSequence
    case duplicatePhysicalOwnership
    case stateMismatch
    case posix(Int32)
}

struct DirectoryHeadFaultShadowReport: Codable {
    struct Case: Codable {
        let id: String
        let simulatedSideEffect: String
        let recoveredState: String
        let writerPolicy: String
    }

    let schemaVersion: Int
    let status: String
    let cases: [Case]
    let claims: Claims

    struct Claims: Codable {
        let realSyscallFailureInjected: Bool
        let recoveryStateUsesRealXattrs: Bool
        let productionAuthorityChanged: Bool
        let processCrash: Bool
        let powerLoss: Bool
    }
}

struct DirectoryHeadScaleReport: Codable {
    let schemaVersion: Int
    let payloadEntryCount: Int
    let deltaKeyCount: Int
    let recordAttributeCount: Int
    let iterations: Int
    let medianRecoveryNanoseconds: UInt64
    let logicalEntryCount: Int
    let claims: Claims

    struct Claims: Codable {
        let formalPerformance: Bool
        let physicalDevice: Bool
        let productionAuthorityChanged: Bool
    }
}

struct DirectoryHeadCrashVerifyReport: Codable {
    let schemaVersion: Int
    let state: String
    let headSequence: UInt64?
    let recordAttributeCount: Int?
    let processCrashClaim: Bool
    let powerLossClaim: Bool
}

struct DirectoryHeadShadowReport: Codable {
    let schemaVersion: Int
    let status: String
    let generation: UInt64
    let operationCount: Int
    let maximumRecordNameBytes: Int
    let maximumRecordValueBytes: Int
    let maximumHeadNameBytes: Int
    let maximumHeadValueBytes: Int
    let maximumRecordAttributes: Int
    let maximumRecordsPerKey: Int
    let randomReplayMatched: Bool
    let currentRecordDeletionRejected: Bool
    let currentRecordCorruptionRejected: Bool
    let staleRecordCorruptionIgnored: Bool
    let uncommittedRecordCorruptionIgnored: Bool
    let headDeletionRejected: Bool
    let headCorruptionRejected: Bool
    let duplicateSequenceRejected: Bool
    let futureGenerationRejected: Bool
    let malformedBase32Rejected: Bool
    let keyBodyMismatchRejected: Bool
    let duplicatePhysicalOwnershipRejected: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionAuthorityChanged: Bool
        let productionSchemaChanged: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

struct DirectoryHeadRecordIdentity: Equatable, Hashable {
    private static let familyPrefix = "dev.akashic.md1."
    private static let namePrefix = "dev.akashic.md1.g"

    let generation: UInt64
    let sequence: UInt64
    let key: String

    var name: String {
        let keyBytes = Self.decodeHexKey(key)!
        return "\(Self.namePrefix)\(Self.hex16(generation)).s\(Self.hex16(sequence)).\(Self.base32(keyBytes))"
    }

    static func make(generation: UInt64, sequence: UInt64, key: String) throws -> Self {
        guard generation > 0,
            sequence > 0,
            let keyBytes = decodeHexKey(key),
            keyBytes.count == 32
        else { throw DirectoryHeadShadowError.invalidName }
        let encoded = base32(keyBytes)
        guard encoded.utf8.count == 52,
            decodeBase32(encoded) == keyBytes
        else { throw DirectoryHeadShadowError.invalidName }
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
            parts[4].first == "s"
        else { throw DirectoryHeadShadowError.invalidName }
        let generationText = parts[3].dropFirst()
        let sequenceText = parts[4].dropFirst()
        guard let generation = parseHex16(generationText), generation > 0,
            let sequence = parseHex16(sequenceText), sequence > 0,
            let keyBytes = decodeBase32(String(parts[5])), keyBytes.count == 32
        else { throw DirectoryHeadShadowError.invalidName }
        let key = encodeHexKey(keyBytes)
        let identity = Self(generation: generation, sequence: sequence, key: key)
        guard identity.name == name else { throw DirectoryHeadShadowError.invalidName }
        return identity
    }

    static func keyBytes(_ key: String) throws -> Data {
        guard let decoded = decodeHexKey(key), decoded.count == 32 else {
            throw DirectoryHeadShadowError.invalidName
        }
        return decoded
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
        var bytes = [UInt8](repeating: 48, count: 16)
        var remaining = value
        for index in stride(from: 15, through: 0, by: -1) {
            bytes[index] = table[Int(remaining & 0xF)]
            remaining >>= 4
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeHexKey(_ key: String) -> Data? {
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

    private static func encodeHexKey(_ data: Data) -> String {
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

    private static let base32Alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

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
                output.append(base32Alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
            if bits == 0 {
                buffer = 0
            } else {
                buffer &= (UInt32(1) << UInt32(bits)) - 1
            }
        }
        if bits > 0 {
            output.append(base32Alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
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

struct DirectoryHeadIdentity: Equatable {
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
        else { throw DirectoryHeadShadowError.invalidName }
        let identity = Self(generation: generation, slot: slot)
        guard identity.name == name else { throw DirectoryHeadShadowError.invalidName }
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
        var bytes = [UInt8](repeating: 48, count: 16)
        var remaining = value
        for index in stride(from: 15, through: 0, by: -1) {
            bytes[index] = table[Int(remaining & 0xF)]
            remaining >>= 4
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

struct DirectoryHeadValue: Codable, Equatable {
    let v: UInt16
    let g: UInt64
    let p: UInt8
    let s: UInt64
    let c: UInt16
    let r: Data
    let h: Data
}

struct DirectoryHeadLatest {
    let identity: DirectoryHeadRecordIdentity
    let data: Data
    let mutation: FileBlobStoreRecordShadowMutation
    let leaf: Data
}

struct DirectoryHeadRecovered {
    let logical: [String: FileBlobStoreRecordShadowEntry]
    let latest: [String: DirectoryHeadLatest]
    let activeSlot: UInt8
    let activeHead: DirectoryHeadValue
    let recordIdentities: [DirectoryHeadRecordIdentity]
}

enum DirectoryHeadShadowIO {
    static func setAttribute(
        _ name: String,
        value: Data,
        at directory: URL,
        flags: Int32
    ) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        let result = name.withCString { namePointer in
            value.withUnsafeBytes { bytes in
                Darwin.fsetxattr(
                    descriptor,
                    namePointer,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    flags
                )
            }
        }
        guard result == 0 else { throw posixError() }
    }

    static func removeAttribute(_ name: String, at directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        let result = name.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
        guard result == 0 else { throw posixError() }
    }

    static func synchronize(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        while true {
            if Darwin.fsync(descriptor) == 0 { return }
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func posixError() -> DirectoryHeadShadowError {
        .posix(errno)
    }
}
