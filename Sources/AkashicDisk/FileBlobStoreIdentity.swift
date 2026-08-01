import AkashicCore
import CryptoKit
import Foundation

/// 定义 typed blob 的完整性校验和 partition-scoped 清单键。
enum FileBlobStoreIdentity {
    static func digestMatches(data: Data, digest: BlobDigest) -> Bool {
        digest.matches(data)
    }

    static func manifestKey(
        digest: BlobDigest,
        partition: CachePartitionID
    ) -> String {
        var input = Data("akashic-file-blob-key-v1\u{0}".utf8)
        input.append(partition.canonicalBytes)
        input.append(0)
        input.append(Data(digest.canonicalString.utf8))
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
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
