import CryptoKit
import Foundation

/// Akashic 首版接受的有限摘要算法集合。
public enum BlobDigestAlgorithm: String, CaseIterable, Codable, Hashable, Sendable {
    case sha256

    /// 算法要求的摘要字节数。
    public var digestByteCount: Int {
        switch self {
        case .sha256: 32
        }
    }
}

/// 指定字节域的内容完整性身份。
///
/// `BlobDigest` 只绑定算法、摘要字节和精确载荷长度。它不表示来源、
/// 授权、真实性、持久化许可或上层派生语义。
public struct BlobDigest: Hashable, Sendable, Codable {
    public let algorithm: BlobDigestAlgorithm
    public let bytes: Data
    public let byteCount: Int

    public init(
        algorithm: BlobDigestAlgorithm,
        bytes: Data,
        byteCount: Int
    ) throws {
        guard bytes.count == algorithm.digestByteCount, byteCount >= 0 else {
            throw AkashicError.invalidIdentity
        }
        self.algorithm = algorithm
        self.bytes = bytes
        self.byteCount = byteCount
    }

    /// 为完整数据计算首版 SHA-256 blob 身份。
    public static func sha256(of data: Data) -> Self {
        let digest = SHA256.hash(data: data)
        return try! BlobDigest(
            algorithm: .sha256,
            bytes: Data(digest),
            byteCount: data.count
        )
    }

    /// 解析 `sha256:<lowercase-hex>:<canonical-byte-count>`。
    public init(canonicalString: String) throws {
        let parts = canonicalString.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let algorithm = BlobDigestAlgorithm(rawValue: String(parts[0])),
            let bytes = Self.decodeLowercaseHex(parts[1]),
            let byteCount = Self.parseCanonicalNonnegativeInteger(parts[2])
        else {
            throw AkashicError.invalidIdentity
        }
        try self.init(algorithm: algorithm, bytes: bytes, byteCount: byteCount)
    }

    /// 跨语言和磁盘清单使用的规范字符串。
    public var canonicalString: String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(algorithm.rawValue):\(hex):\(byteCount)"
    }

    /// 由 store 独立重算摘要和长度，不能信任调用方的匹配声明。
    public func matches(_ data: Data) -> Bool {
        guard data.count == byteCount else { return false }
        switch algorithm {
        case .sha256:
            return Data(SHA256.hash(data: data)) == bytes
        }
    }

    private enum CodingKeys: String, CodingKey {
        case canonical
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .canonical)
        do {
            try self.init(canonicalString: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .canonical,
                in: container,
                debugDescription: "Invalid canonical BlobDigest"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalString, forKey: .canonical)
    }

    private static func decodeLowercaseHex(_ value: Substring) -> Data? {
        guard value.count.isMultiple(of: 2),
            value.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            })
        else { return nil }

        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func parseCanonicalNonnegativeInteger(_ value: Substring) -> Int? {
        guard !value.isEmpty,
            value.utf8.allSatisfy({ (48...57).contains($0) }),
            !(value.count > 1 && value.first == "0"),
            let parsed = Int(value),
            parsed >= 0,
            String(parsed) == value
        else { return nil }
        return parsed
    }
}

/// Store 内的不透明逻辑隔离域。
///
/// Akashic 不解释该值在宿主中的业务含义。公开 API 只接受固定长度字节，
/// 或由调用方选择的中立域与不透明材料进行派生。
public struct CachePartitionID: Hashable, Sendable, Codable {
    private static let byteCount = 32
    private let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw AkashicError.invalidIdentity }
        self.bytes = bytes
    }

    /// 使用调用方选择的中立域和不透明材料派生固定长度分区 ID。
    public static func derive(domain: String, material: Data) throws -> Self {
        let domainBytes = Data(domain.utf8)
        guard !domainBytes.isEmpty,
            domainBytes.count <= 128,
            domain.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e })
        else { throw AkashicError.invalidIdentity }
        var input = Data("akashic-partition-v1\u{0}".utf8)
        input.append(domainBytes)
        input.append(0)
        input.append(material)
        return try CachePartitionID(bytes: Data(SHA256.hash(data: input)))
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .value)
        guard let data = Data(base64Encoded: value), data.count == Self.byteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "Invalid CachePartitionID"
            )
        }
        self.bytes = data
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bytes.base64EncodedString(), forKey: .value)
    }

    package var canonicalBytes: Data { bytes }
}

/// 单个 store generation 内的不透明物理定位符。
public struct PhysicalBlobID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// 磁盘格式和兼容域的不可变代际身份。
public struct StoreGenerationID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// 尚未发布、只能由创建 store 解释的一次性阶段令牌。
public struct BlobStage: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}
