import Foundation

/// ``FileBlobStore`` 使用的字节、条目和扫描硬限制。
public struct FileBlobStoreLimits: Equatable, Sendable {
    private static let maximumSoftTotalBytes = 1024 * 1024 * 1024 * 1024
    private static let maximumSupportedBlobBytes = 1024 * 1024 * 1024
    private static let maximumSupportedDirectoryEntries = 1_000_000

    /// 机会式最近访问裁剪后的近似字节目标。
    public let softTotalBytes: Int
    /// 单个 blob 的硬上限。
    public let maximumBlobBytes: Int
    /// 一次直接目录读取允许接收的最大子项数。
    public let maximumDirectoryEntryCount: Int

    public init(
        softTotalBytes: Int = 128 * 1024 * 1024,
        maximumBlobBytes: Int = 64 * 1024 * 1024,
        maximumDirectoryEntryCount: Int = 201_024
    ) {
        let normalizedTotal = min(
            Self.maximumSoftTotalBytes,
            max(1, softTotalBytes)
        )
        self.softTotalBytes = normalizedTotal
        self.maximumBlobBytes = min(
            Self.maximumSupportedBlobBytes,
            max(1, min(maximumBlobBytes, normalizedTotal))
        )
        self.maximumDirectoryEntryCount = min(
            Self.maximumSupportedDirectoryEntries,
            max(1, maximumDirectoryEntryCount)
        )
    }
}
