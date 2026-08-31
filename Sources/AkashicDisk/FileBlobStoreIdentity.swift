import AkashicCore
import CryptoKit
import Foundation

/// 定义 typed blob 的完整性校验和 partition-scoped 清单键。
enum FileBlobStoreIdentity {
    private static let manifestKeyDomain = Data("akashic-file-blob-key-v1\u{0}".utf8)
    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    static func digestMatches(data: Data, digest: BlobDigest) -> Bool {
        digest.matches(data)
    }

    static func manifestKey(
        digest: BlobDigest,
        partition: CachePartitionID
    ) -> String {
        let hashed = manifestKeyDigest(digest: digest, partition: partition)
        var encoded = [UInt8]()
        encoded.reserveCapacity(64)
        for byte in hashed {
            encoded.append(lowercaseHexDigits[Int(byte >> 4)])
            encoded.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func manifestKeyDigest(
        digest: BlobDigest,
        partition: CachePartitionID
    ) -> SHA256.Digest {
        var input = Data(capacity: manifestKeyDomain.count + 32 + 1 + 7 + 64 + 1 + 20)
        input.append(manifestKeyDomain)
        input.append(partition.canonicalBytes)
        input.append(0)
        input.append(contentsOf: digest.algorithm.rawValue.utf8)
        input.append(58)
        appendLowercaseHex(digest.bytes, to: &input)
        input.append(58)
        input.append(contentsOf: String(digest.byteCount).utf8)
        return SHA256.hash(data: input)
    }

    private static func appendLowercaseHex(_ bytes: Data, to output: inout Data) {
        output.reserveCapacity(output.count + bytes.count * 2)
        for byte in bytes {
            output.append(lowercaseHexDigits[Int(byte >> 4)])
            output.append(lowercaseHexDigits[Int(byte & 0x0F)])
        }
    }

    static func isInvalidBlobPath(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ENOENT, .ELOOP, .ENOTDIR:
            return true
        default:
            return false
        }
    }
}
