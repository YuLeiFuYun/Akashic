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
    let allowsSegmentedProfileV2: Bool
    let allowsSegmentedProfileV3: Bool
    let allowsSegmentedProfileV4: Bool
    let segmentedManifestRunCapacityPolicy: FileBlobStoreSegmentedRunCapacityPolicy
    var manifest: Manifest
    var loadedManifestSchemaVersion: UInt16
    var segmentedManifestRoot: SegmentedManifestRootV1?
    var segmentedManifestCompactionCandidateName: String?
    struct SegmentedManifestCheckpointPresealCandidate: Sendable {
        let generation: UInt64
        let sourceSequence: UInt64
        let sourceDistinctKeyCount: Int
        let sourceHeadRoot: Data
        let descriptor: SegmentedManifestDescriptorV1
    }
    /// Non-authoritative package-only checkpoint-prefix candidate. The file remains reclaimable
    /// physical segment debt until a later root publication references it; bootstrap never treats
    /// this actor-local hint as logical authority.
    var segmentedManifestCheckpointPresealCandidate: SegmentedManifestCheckpointPresealCandidate?
    struct SegmentedManifestCompoundPresealCandidate: Sendable {
        let generation: UInt64
        let sourceSequence: UInt64
        let sourceDistinctKeyCount: Int
        let sourceHeadRoot: Data
        let draft: SegmentedManifestCompoundRunV1.Draft
    }
    /// V4 one-descriptor prefix draft. Like the V3 two-run preseal, this is physical state only;
    /// no root references it until checkpoint finalization succeeds.
    var segmentedManifestCompoundPresealCandidate: SegmentedManifestCompoundPresealCandidate?
    struct SegmentedManifestRunPrefixCollapseCandidate: Sendable {
        let generation: UInt64
        let profile: String
        let base: SegmentedManifestDescriptorV1
        let sourcePrefixRuns: [SegmentedManifestDescriptorV1]
        let replacementRuns: [SegmentedManifestDescriptorV1]
        let touchedKeyCount: Int
        let finalUpsertCount: Int
        let inputRunBytes: Int
        let outputRunBytes: Int
    }
    /// Non-authoritative replacement for an immutable authoritative run prefix. Later checkpoints
    /// may append suffix runs without invalidating this candidate; adoption is allowed only while
    /// the exact original prefix is still present. Candidate files are physical topology only.
    var segmentedManifestRunPrefixCollapseCandidate:
        SegmentedManifestRunPrefixCollapseCandidate?
    /// Detached run-prefix planning task, if any. Hard-cap rescue cancels it cooperatively but
    /// keeps the source read lease until the task has actually stopped touching frozen files.
    var segmentedManifestRunPrefixPreparationTask:
        Task<SegmentedManifestRunCollapsePlanV1?, Error>?
    var segmentedManifestRunPrefixPreparationToken: UUID?
    /// Exact unique output names reserved by detached stable-prefix materialization. Some may not
    /// exist yet; hard-cap capacity accounting treats every missing name as an unmaterialized slot.
    var segmentedManifestRunPrefixMaterializationNames: Set<String>
    var segmentedManifestRunPrefixMaterializationTask:
        Task<[SegmentedManifestDescriptorV1], Error>?
    var segmentedManifestRunPrefixMaterializationToken: UUID?
    /// Actor-local diagnostics/state for the package-only automatic stable-prefix scheduler.
    /// The outer scheduler Task is intentionally not retained by the actor: it strongly retains
    /// the store until the bounded background attempt finishes, preserving writer exclusivity
    /// without creating a store -> task -> store reference cycle.
    var segmentedManifestAutomaticStablePrefixInFlight: Bool
    var segmentedManifestAutomaticStablePrefixAttemptCount: Int
    var segmentedManifestAutomaticStablePrefixPreparedCount: Int
    var segmentedManifestAutomaticStablePrefixAdoptedCount: Int
    var segmentedManifestAutomaticStablePrefixNilCount: Int
    var segmentedManifestAutomaticStablePrefixErrorCount: Int
    var segmentedManifestAutomaticStablePrefixHardCapCancellationCount: Int
    var segmentedManifestAutomaticStablePrefixPlannerNoCandidateCount: Int
    var segmentedManifestAutomaticStablePrefixFrozenDescriptorFloorCount: Int
    var segmentedManifestAutomaticStablePrefixFrozenByteExpansionCount: Int
    var segmentedManifestAutomaticStablePrefixSuffixBeforeMaterializationCount: Int
    var segmentedManifestAutomaticStablePrefixSuffixAfterMaterializationCount: Int
    var segmentedManifestAutomaticStablePrefixStaleOrCancelledCount: Int
    var segmentedManifestAutomaticStablePrefixNextRetryRunCount: Int?
    var segmentedManifestAutomaticStablePrefixLastRejection:
        FileBlobStoreSegmentedRunPrefixPreparationRejection?
    var segmentedManifestAutomaticStablePrefixLastTriggerGeneration: UInt64?
    var segmentedManifestAutomaticStablePrefixLastTriggerRunCount: Int?
    var segmentedManifestAutomaticStablePrefixLastPreparedSuffixRunCount: Int?
    var segmentedManifestAutomaticStablePrefixMaximumPreparedSuffixRunCount: Int
    var segmentedManifestAutomaticStablePrefixPreparationObserver:
        FileBlobStoreSegmentedCompactionPreparationObserver?
    var segmentedManifestAutomaticStablePrefixMaterializationObserver:
        FileBlobStoreSegmentedCompactionPreparationObserver?
    var segmentedManifestCompoundFinalizeFaultInjector:
        SegmentedManifestCompoundRunV1.FinalizeFaultInjector?
    /// Physical read lease for immutable base/run descriptors captured by an in-flight detached
    /// V3 compaction. Foreground topology changes may supersede their logical authority, but must
    /// not unlink these files until detached preparation has finished reading its frozen root.
    var segmentedManifestCompactionReadLeaseNames: Set<String>
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
        readOperations: FileBlobStoreReadOperations,
        allowsSegmentedProfileV2: Bool,
        allowsSegmentedProfileV3: Bool,
        allowsSegmentedProfileV4: Bool,
        segmentedManifestRunCapacityPolicy: FileBlobStoreSegmentedRunCapacityPolicy
    ) {
        self.blobs = root.appendingPathComponent("blobs", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json")
        self.limits = limits
        self.writerLease = writerLease
        self.faultInjector = faultInjector
        self.fastCommitOperations = fastCommitOperations
        self.directoryHeadOperations = directoryHeadOperations
        self.readIO = FileBlobStoreReadIO(maximumInFlightBytes: min(FileBlobStoreReadIO.maximumDefaultInFlightBytes, limits.softTotalBytes), operations: readOperations)
        self.allowsSegmentedProfileV2 = allowsSegmentedProfileV2
        self.allowsSegmentedProfileV3 = allowsSegmentedProfileV3
        self.allowsSegmentedProfileV4 = allowsSegmentedProfileV4
        self.segmentedManifestRunCapacityPolicy = segmentedManifestRunCapacityPolicy
        self.manifest = Manifest()
        self.loadedManifestSchemaVersion = Self.currentSchemaVersion
        self.segmentedManifestRoot = nil
        self.segmentedManifestCompactionCandidateName = nil
        self.segmentedManifestCheckpointPresealCandidate = nil
        self.segmentedManifestCompoundPresealCandidate = nil
        self.segmentedManifestRunPrefixCollapseCandidate = nil
        self.segmentedManifestRunPrefixPreparationTask = nil
        self.segmentedManifestRunPrefixPreparationToken = nil
        self.segmentedManifestRunPrefixMaterializationNames = []
        self.segmentedManifestRunPrefixMaterializationTask = nil
        self.segmentedManifestRunPrefixMaterializationToken = nil
        self.segmentedManifestAutomaticStablePrefixInFlight = false
        self.segmentedManifestAutomaticStablePrefixAttemptCount = 0
        self.segmentedManifestAutomaticStablePrefixPreparedCount = 0
        self.segmentedManifestAutomaticStablePrefixAdoptedCount = 0
        self.segmentedManifestAutomaticStablePrefixNilCount = 0
        self.segmentedManifestAutomaticStablePrefixErrorCount = 0
        self.segmentedManifestAutomaticStablePrefixHardCapCancellationCount = 0
        self.segmentedManifestAutomaticStablePrefixPlannerNoCandidateCount = 0
        self.segmentedManifestAutomaticStablePrefixFrozenDescriptorFloorCount = 0
        self.segmentedManifestAutomaticStablePrefixFrozenByteExpansionCount = 0
        self.segmentedManifestAutomaticStablePrefixSuffixBeforeMaterializationCount = 0
        self.segmentedManifestAutomaticStablePrefixSuffixAfterMaterializationCount = 0
        self.segmentedManifestAutomaticStablePrefixStaleOrCancelledCount = 0
        self.segmentedManifestAutomaticStablePrefixNextRetryRunCount = nil
        self.segmentedManifestAutomaticStablePrefixLastRejection = nil
        self.segmentedManifestAutomaticStablePrefixLastTriggerGeneration = nil
        self.segmentedManifestAutomaticStablePrefixLastTriggerRunCount = nil
        self.segmentedManifestAutomaticStablePrefixLastPreparedSuffixRunCount = nil
        self.segmentedManifestAutomaticStablePrefixMaximumPreparedSuffixRunCount = 0
        self.segmentedManifestAutomaticStablePrefixPreparationObserver = nil
        self.segmentedManifestAutomaticStablePrefixMaterializationObserver = nil
        self.segmentedManifestCompoundFinalizeFaultInjector = nil
        self.segmentedManifestCompactionReadLeaseNames = []
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

    /// Package-only qualification seam for the research V2 binary-base profile. This exercises
    /// the real FileBlobStore mutation/recovery paths without expanding the public open contract.
    package static func openSegmentedV2Candidate(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector = { _ in }
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            bootstrapObserver: { _ in },
            fastCommitOperations: .system,
            directoryHeadOperations: .system,
            readOperations: .system,
            allowsSegmentedProfileV2: true,
            allowsSegmentedProfileV3: false,
            allowsSegmentedProfileV4: false
        )
    }

    package static func openSegmentedV3Candidate(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector = { _ in },
        runCapacityPolicy: FileBlobStoreSegmentedRunCapacityPolicy = .rejectAtHardLimit
    ) async throws -> FileBlobStore {
        try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            bootstrapObserver: { _ in },
            fastCommitOperations: .system,
            directoryHeadOperations: .system,
            readOperations: .system,
            allowsSegmentedProfileV2: false,
            allowsSegmentedProfileV3: true,
            allowsSegmentedProfileV4: false,
            segmentedManifestRunCapacityPolicy: runCapacityPolicy
        )
    }

    /// Package-only qualification seam for the one-descriptor compound-run profile. Public open,
    /// V2, and V3 readers remain fail-closed on this profile.
    package static func openSegmentedV4Candidate(
        root: URL,
        limits: FileBlobStoreLimits = FileBlobStoreLimits(),
        faultInjector: @escaping FileBlobStoreFaultInjector = { _ in },
        runCapacityPolicy: FileBlobStoreSegmentedRunCapacityPolicy = .rejectAtHardLimit
    ) async throws -> FileBlobStore {
        if let prefixRunCount = runCapacityPolicy.automaticV4StablePrefixRunCount,
            !(2...62).contains(prefixRunCount)
        {
            throw AkashicError.limitExceeded
        }
        return try await open(
            root: root,
            limits: limits,
            faultInjector: faultInjector,
            bootstrapObserver: { _ in },
            fastCommitOperations: .system,
            directoryHeadOperations: .system,
            readOperations: .system,
            allowsSegmentedProfileV2: false,
            allowsSegmentedProfileV3: false,
            allowsSegmentedProfileV4: true,
            segmentedManifestRunCapacityPolicy: runCapacityPolicy
        )
    }

    private static func open(
        root: URL,
        limits: FileBlobStoreLimits,
        faultInjector: @escaping FileBlobStoreFaultInjector,
        bootstrapObserver: @escaping FileBlobStoreBootstrapObserver,
        fastCommitOperations: FileBlobStoreFastCommitOperations,
        directoryHeadOperations: FileBlobStoreDirectoryHeadOperations = .system,
        readOperations: FileBlobStoreReadOperations = .system,
        allowsSegmentedProfileV2: Bool = false,
        allowsSegmentedProfileV3: Bool = false,
        allowsSegmentedProfileV4: Bool = false,
        segmentedManifestRunCapacityPolicy: FileBlobStoreSegmentedRunCapacityPolicy = .rejectAtHardLimit
    ) async throws -> FileBlobStore {
        let writerLease = try await writerLeaseAcquirer.acquire(root: root)
        let store = FileBlobStore(
            root: root,
            limits: limits,
            writerLease: writerLease,
            faultInjector: faultInjector,
            fastCommitOperations: fastCommitOperations,
            directoryHeadOperations: directoryHeadOperations,
            readOperations: readOperations,
            allowsSegmentedProfileV2: allowsSegmentedProfileV2,
            allowsSegmentedProfileV3: allowsSegmentedProfileV3,
            allowsSegmentedProfileV4: allowsSegmentedProfileV4,
            segmentedManifestRunCapacityPolicy: segmentedManifestRunCapacityPolicy
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
