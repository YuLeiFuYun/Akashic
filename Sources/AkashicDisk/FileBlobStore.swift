import AkashicCore
import Foundation

package enum FileBlobStoreBootstrapPhase: String, Sendable {
    case directoriesPrepared
    case manifestSnapshotLoaded
    case manifestRecordsReplayed
    case storageReconciled
    case trimCompleted
}

package typealias FileBlobStoreBootstrapObserver = @Sendable (FileBlobStoreBootstrapPhase) -> Void

/// 按不透明 partition 隔离、由清单索引的已验证通用 blob 存储。
public actor FileBlobStore: BlobStoreMaintaining, TransactionalBlobStoring {
    private nonisolated let ioExecutor = BlockingIOExecutor(label: "dev.akashic.file-blob-store")
    /// 用于把阻塞文件系统工作移出协作式执行器的专用串行执行器。
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioExecutor.asUnownedSerialExecutor()
    }
    /// 此实现接受并写出的清单模式版本。
    public static let currentSchemaVersion: UInt16 = 3
    static let legacyManifestSchemaVersion: UInt16 = 2
    static let compactManifestSchemaVersion: UInt16 = 3
    static let directoryHeadManifestSchemaVersion: UInt16 = 4
    static let segmentedManifestSchemaVersion: UInt16 = 5
    static let maximumManifestBytes = 64 * 1024 * 1024
    static let maximumManifestRecordBytes = 16 * 1024
    package static let manifestCheckpointRecordLimit = 512
    static let maximumManifestEntryCount = 100_000
    static let maximumSupportedBlobBytes = 1024 * 1024 * 1024
    private static let writerLeaseAcquirer = StoreWriterLeaseAcquirer()

    let blobs: URL
    let manifestURL: URL
    let limits: FileBlobStoreLimits
    private let writerLease: StoreWriterLease
    let faultInjector: FileBlobStoreFaultInjector
    let fastCommitOperations: FileBlobStoreFastCommitOperations
    let directoryHeadOperations: FileBlobStoreDirectoryHeadOperations
    let readIO: FileBlobStoreReadIO
    var manifest: Manifest
    var loadedManifestSchemaVersion: UInt16
    var segmentedManifestRoot: SegmentedManifestRootV1?
    var directoryHeadState: DirectoryHeadRecoveredState?
    /// Schema4 hot-path ownership proof rebuilt from a fully validated manifest at bootstrap or
    /// checkpoint. Schema3 deliberately leaves this nil; its existing persistence paths keep their
    /// current validation semantics.
    var manifestOwnershipIndex: ManifestOwnershipIndex?
    /// Cached logical resident bytes used only to avoid an O(live entries) soft-limit probe on
    /// every commit. Full bootstrap/checkpoint validation rebuilds it; successful single-key
    /// transitions update it after publication.
    var manifestLiveByteCount: Int?
    var manifestRecordSequence: UInt64 = 0
    /// 当前 generation 已产生增量 authority 的 distinct logical keys。
    ///
    /// 物理载体可以是 sidecar file，也可以是后续的 blob xattr；checkpoint 阈值属于
    /// logical delta cardinality，不应再由某一种物理 record 文件是否存在来决定。
    var manifestRecordKeys: Set<String> = []
    var manifestRecordCount: Int { manifestRecordKeys.count }
    var staleManifestRecordCleanupQueue: [URL] = []
    var staleDirectoryHeadCleanupQueue: [String] = []
    var runtimeLastAccess: [String: Date] = [:]
    var pendingStages: [UUID: PendingStage] = [:]
    /// Exact direct-child count after a bounded bootstrap/GC enumeration, plus any conservative
    /// unresolved reservation debt retained after an ambiguous failed mutation.
    var blobDirectoryEntryCount: Int?
    /// In-flight crash-visible direct-child slots reserved by the currently executing mutation.
    var blobDirectoryReservedEntryCount = 0
    /// On-disk logical authority crossed its rename visibility point but the operation returned
    /// before this actor could converge its manifest/generation state. No further stateful access is
    /// safe until reopen replays the authoritative disk state.
    var requiresReopenBeforeFurtherAccess = false

    private init(
        root: URL,
        limits: FileBlobStoreLimits,
        writerLease: consuming StoreWriterLease,
        faultInjector: @escaping FileBlobStoreFaultInjector,
        fastCommitOperations: FileBlobStoreFastCommitOperations,
        directoryHeadOperations: FileBlobStoreDirectoryHeadOperations,
        readOperations: FileBlobStoreReadOperations
    ) {
        self.blobs = root.appendingPathComponent("blobs", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json")
        self.limits = limits
        self.writerLease = writerLease
        self.faultInjector = faultInjector
        self.fastCommitOperations = fastCommitOperations
        self.directoryHeadOperations = directoryHeadOperations
        self.readIO = FileBlobStoreReadIO(maximumInFlightBytes: min(FileBlobStoreReadIO.maximumDefaultInFlightBytes, limits.softTotalBytes), operations: readOperations)
        self.manifest = Manifest()
        self.loadedManifestSchemaVersion = Self.currentSchemaVersion
        self.segmentedManifestRoot = nil
        self.directoryHeadState = nil
        self.blobDirectoryEntryCount = nil
    }

    /// 打开、验证、校准并裁剪 partition 隔离的 blob 存储。
    public static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits()
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: { _ in }
        )
    }

    package static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            fastCommitOperations: .system
        )
    }

    /// 仅供同 package 的资源探针按 bootstrap phase 做机制归因。
    package static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector,
        bootstrapObserver: @escaping FileBlobStoreBootstrapObserver
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            bootstrapObserver: bootstrapObserver,
            fastCommitOperations: .system
        )
    }

    /// Package-only fast-transaction syscall seam. Production and resource probes bind the real
    /// Darwin table above; disk tests may replace individual calls without altering public storage
    /// construction or unrelated bootstrap I/O.
    package static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector,
        fastCommitOperations: FileBlobStoreFastCommitOperations
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            bootstrapObserver: { _ in },
            fastCommitOperations: fastCommitOperations
        )
    }

    package static func open(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector,
        fastCommitOperations: FileBlobStoreFastCommitOperations = .system,
        directoryHeadOperations: FileBlobStoreDirectoryHeadOperations,
        readOperations: FileBlobStoreReadOperations = .system
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            bootstrapObserver: { _ in },
            fastCommitOperations: fastCommitOperations,
            directoryHeadOperations: directoryHeadOperations,
            readOperations: readOperations
        )
    }

    private static func open(
        root: URL,
        limits: FileBlobStoreLimits,
        faultInjector: @escaping FileBlobStoreFaultInjector,
        bootstrapObserver: @escaping FileBlobStoreBootstrapObserver,
        fastCommitOperations: FileBlobStoreFastCommitOperations,
        directoryHeadOperations: FileBlobStoreDirectoryHeadOperations = .system,
        readOperations: FileBlobStoreReadOperations = .system
    ) async throws -> FileBlobStore {
        let writerLease = try await writerLeaseAcquirer.acquire(root: root)
        let store = FileBlobStore(
            root: root,
            limits: limits,
            writerLease: writerLease,
            faultInjector: faultInjector,
            fastCommitOperations: fastCommitOperations,
            directoryHeadOperations: directoryHeadOperations,
            readOperations: readOperations
        )
        try await store.bootstrap(root: root, observer: bootstrapObserver)
        return store
    }

    /// 打开单数据块上限与总软上限共享同一字节预算的存储。
    public static func open(
        root: URL,
        softLimitBytes: Int
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: softLimitBytes,
                maximumBlobBytes: softLimitBytes
            )
        )
    }


}
