import Foundation

/// Akashic 公开的稳定错误分类。
public enum AkashicError: Error, Equatable, Sendable {
    case notFound
    case invalidIdentity
    case integrityMismatch
    case invalidManifest
    case unsupportedSchema
    case unsupportedCapability
    case limitExceeded
    case storageUnavailable
    case transactionConflict
}

/// Blob 发布是创建新物理数据还是复用同 partition 的既有数据。
public enum BlobPublicationDisposition: String, Codable, Hashable, Sendable {
    case created
    case reused
}

/// 成功发布 blob 后返回的物理结果；它不是内容身份或授权凭证。
public struct BlobPublication: Hashable, Sendable {
    public let physicalID: PhysicalBlobID
    public let byteCount: Int
    public let disposition: BlobPublicationDisposition

    public init(
        physicalID: PhysicalBlobID,
        byteCount: Int,
        disposition: BlobPublicationDisposition
    ) throws {
        guard byteCount >= 0 else { throw AkashicError.limitExceeded }
        self.physicalID = physicalID
        self.byteCount = byteCount
        self.disposition = disposition
    }
}

/// 有界维护输入中的一个活动逻辑引用。
public struct LiveBlobReference: Hashable, Sendable {
    public let partition: CachePartitionID
    public let digest: BlobDigest

    public init(partition: CachePartitionID, digest: BlobDigest) {
        self.partition = partition
        self.digest = digest
    }
}

/// 垃圾回收和用量查询的硬输入上限。
public struct BlobMaintenanceLimits: Hashable, Sendable {
    public let maximumReferenceCount: Int
    public let maximumReferencedBytes: Int

    public init(
        maximumReferenceCount: Int,
        maximumReferencedBytes: Int
    ) throws {
        guard maximumReferenceCount > 0, maximumReferencedBytes > 0 else {
            throw AkashicError.limitExceeded
        }
        self.maximumReferenceCount = maximumReferenceCount
        self.maximumReferencedBytes = maximumReferencedBytes
    }

    public func validate(_ references: Set<LiveBlobReference>) throws {
        guard references.count <= maximumReferenceCount else {
            throw AkashicError.limitExceeded
        }
        var total = 0
        for reference in references {
            let (next, overflow) = total.addingReportingOverflow(reference.digest.byteCount)
            guard !overflow, next <= maximumReferencedBytes else {
                throw AkashicError.limitExceeded
            }
            total = next
        }
    }
}

/// 一次维护操作确认删除的物理条目和字节数。
public struct BlobMaintenanceResult: Hashable, Sendable {
    public let removedBlobCount: Int
    public let removedByteCount: Int

    public init(removedBlobCount: Int, removedByteCount: Int) throws {
        guard removedBlobCount >= 0, removedByteCount >= 0 else {
            throw AkashicError.limitExceeded
        }
        self.removedBlobCount = removedBlobCount
        self.removedByteCount = removedByteCount
    }
}

/// 通过 typed partition 和 digest 读写通用 blob。
public protocol BlobStoring: Sendable {
    func read(
        digest: BlobDigest,
        partition: CachePartitionID
    ) async throws -> Data

    @discardableResult
    func commit(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID
    ) async throws -> BlobPublication

    func physicalID(
        digest: BlobDigest,
        partition: CachePartitionID
    ) async -> PhysicalBlobID?

    func remove(
        digest: BlobDigest,
        partition: CachePartitionID
    ) async throws

    func removeAll(partition: CachePartitionID) async throws
}

/// 在逻辑索引之外暂存，再显式发布或丢弃 blob。
public protocol TransactionalBlobStoring: BlobStoring {
    func stage(
        data: Data,
        digest: BlobDigest,
        partition: CachePartitionID
    ) async throws -> BlobStage

    func publish(_ stage: BlobStage) async throws -> BlobPublication

    func discard(_ stage: BlobStage) async
}

/// 有界用量、垃圾回收和损坏恢复能力。
public protocol BlobStoreMaintaining: BlobStoring {
    func garbageCollect(
        retaining references: Set<LiveBlobReference>,
        limits: BlobMaintenanceLimits
    ) async throws -> BlobMaintenanceResult
}

/// Store generation 的最小只读描述。
public struct StoreGenerationDescriptor: Hashable, Sendable, Codable {
    public let identifier: StoreGenerationID
    public let compatibilityFingerprint: String

    public init(
        identifier: StoreGenerationID,
        compatibilityFingerprint: String
    ) throws {
        let normalized = compatibilityFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
            normalized.utf8.count <= 1_024,
            normalized.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { throw AkashicError.invalidIdentity }
        self.identifier = identifier
        self.compatibilityFingerprint = normalized
    }
}

/// 打开或创建兼容 store generation 的机制边界。
public protocol StoreGenerationManaging: Sendable {
    func openGeneration(
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationDescriptor
}
