import AkashicCore
import Darwin
import Foundation

/// 标识一个完成初始化的持久化 store generation 及其根目录。
public struct StoreGenerationHandle: Hashable, Sendable {
    public let identifier: StoreGenerationID
    public let compatibilityFingerprint: String
    public let root: URL

    package init(
        identifier: StoreGenerationID,
        compatibilityFingerprint: String,
        root: URL
    ) {
        self.identifier = identifier
        self.compatibilityFingerprint = compatibilityFingerprint
        self.root = root
    }

    public var descriptor: StoreGenerationDescriptor {
        get throws {
            try StoreGenerationDescriptor(
                identifier: identifier,
                compatibilityFingerprint: compatibilityFingerprint
            )
        }
    }
}

package enum StoreGenerationSwitchPoint: CaseIterable, Sendable {
    case afterGenerationDirectoryCreated
    case afterGenerationDescriptorPublished
    case afterPointerStaged
    case afterPointerPublished
}

/// 创建带版本的持久化 store generation，并原子切换活动指针。
public enum StoreGenerationDirectory {
    private static let schemaVersion: UInt16 = 1
    private static let processLock = NSLock()
    private static let ioExecutor = BlockingIOExecutor(
        label: "dev.akashic.store-generation"
    )
    private static let currentName = "current-generation.json"
    private static let generationsName = "generations"
    private static let descriptorName = "generation.json"
    private static let lockName = ".akashic-store-generation.lock"
    private static let temporaryPrefix = ".current-generation.tmp-"
    private static let maximumMetadataBytes = 64 * 1024
    private static let maximumCompatibilityFingerprintBytes = 1_024

    private struct Descriptor: Codable, Hashable {
        let schemaVersion: UInt16
        let identifier: StoreGenerationID
        let compatibilityFingerprint: String
        let createdAt: Date
    }

    private struct Pointer: Codable {
        let schemaVersion: UInt16
        let identifier: StoreGenerationID
        let compatibilityFingerprint: String
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: UInt16
    }

    /// 复用或原子创建与给定兼容指纹匹配的完整 generation。
    ///
    /// 目录扫描、文件锁、耐久写入和 fsync 均在专用阻塞 I/O 通道执行。
    public static func open(
        root: URL,
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationHandle {
        try await ioExecutor.run {
            try openSynchronously(
                root: root,
                compatibilityFingerprint: compatibilityFingerprint
            )
        }
    }

    package static func openSynchronously(
        root: URL,
        compatibilityFingerprint: String
    ) throws -> StoreGenerationHandle {
        try open(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        ) { _ in }
    }

    package static func open(
        root: URL,
        compatibilityFingerprint: String,
        faultInjector: (StoreGenerationSwitchPoint) throws -> Void
    ) throws -> StoreGenerationHandle {
        processLock.lock()
        defer { processLock.unlock() }
        try StorageDirectorySecurity.prepareDirectory(root)
        return try withCrossProcessLock(root: root) {
            try openWhileHoldingProcessLock(
                root: root,
                compatibilityFingerprint: compatibilityFingerprint,
                faultInjector: faultInjector
            )
        }
    }

    private static func withCrossProcessLock<T>(
        root: URL,
        operation: () throws -> T
    ) throws -> T {
        let lockURL = root.appendingPathComponent(lockName, isDirectory: false)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        defer {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = Darwin.close(descriptor)
        }
        try StorageDirectorySecurity.validateOpenedPrivateRegularFile(descriptor)
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw posixError()
        }
        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else { throw posixError() }
        }
        return try operation()
    }

    private static func openWhileHoldingProcessLock(
        root: URL,
        compatibilityFingerprint: String,
        faultInjector: (StoreGenerationSwitchPoint) throws -> Void
    ) throws -> StoreGenerationHandle {
        guard let normalized = normalizedCompatibilityFingerprint(compatibilityFingerprint) else {
            throw AkashicError.invalidIdentity
        }

        let generations = root.appendingPathComponent(generationsName, isDirectory: true)
        let pointerURL = root.appendingPathComponent(currentName, isDirectory: false)
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(generations)
        try reconcileIncompleteState(root: root, generations: generations)

        if let active = try validHandle(
            pointerURL: pointerURL,
            generations: generations,
            expectedFingerprint: normalized
        ) {
            return active
        }

        if let recovered = try newestCompleteGeneration(
            generations: generations,
            compatibilityFingerprint: normalized
        ) {
            try publishPointer(for: recovered, root: root, faultInjector: faultInjector)
            return recovered
        }

        let identifier = StoreGenerationID()
        let generationRoot = generations.appendingPathComponent(
            directoryName(for: identifier),
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(generationRoot)
        try faultInjector(.afterGenerationDirectoryCreated)

        let descriptor = Descriptor(
            schemaVersion: schemaVersion,
            identifier: identifier,
            compatibilityFingerprint: normalized,
            createdAt: Date()
        )
        let descriptorURL = generationRoot.appendingPathComponent(
            descriptorName,
            isDirectory: false
        )
        try DurableFileWriter.writeReplacing(
            JSONEncoder().encode(descriptor),
            to: descriptorURL
        )
        try faultInjector(.afterGenerationDescriptorPublished)

        let handle = StoreGenerationHandle(
            identifier: identifier,
            compatibilityFingerprint: normalized,
            root: generationRoot
        )
        try publishPointer(for: handle, root: root, faultInjector: faultInjector)
        return handle
    }

    private static func reconcileIncompleteState(root: URL, generations: URL) throws {
        let fileManager = FileManager.default
        for url in try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) where url.lastPathComponent.hasPrefix(temporaryPrefix) {
            try fileManager.removeItem(at: url)
        }

        for generation in try fileManager.contentsOfDirectory(
            at: generations,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) {
            let values = try generation.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let descriptorURL = generation.appendingPathComponent(
                descriptorName,
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: descriptorURL.path) else {
                try fileManager.removeItem(at: generation)
                continue
            }
            // 已有 descriptor 的未知或未来 generation 必须保留；旧版本不得改写。
            try StorageDirectorySecurity.prepareDirectory(generation)
        }
    }

    private static func validHandle(
        pointerURL: URL,
        generations: URL,
        expectedFingerprint: String
    ) throws -> StoreGenerationHandle? {
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        let data = try BoundedFileReader.read(
            from: pointerURL,
            maximumBytes: maximumMetadataBytes
        )
        if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
            envelope.schemaVersion != schemaVersion
        {
            throw AkashicError.unsupportedSchema
        }
        guard let pointer = try? JSONDecoder().decode(Pointer.self, from: data),
            pointer.compatibilityFingerprint == expectedFingerprint
        else { return nil }

        let generationRoot = generations.appendingPathComponent(
            directoryName(for: pointer.identifier),
            isDirectory: true
        )
        let descriptor = try validDescriptor(at: generationRoot)
        guard descriptor.identifier == pointer.identifier,
            descriptor.compatibilityFingerprint == pointer.compatibilityFingerprint
        else { return nil }
        return StoreGenerationHandle(
            identifier: descriptor.identifier,
            compatibilityFingerprint: descriptor.compatibilityFingerprint,
            root: generationRoot
        )
    }

    private static func newestCompleteGeneration(
        generations: URL,
        compatibilityFingerprint: String
    ) throws -> StoreGenerationHandle? {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: generations,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ).compactMap { root -> (Descriptor, URL)? in
            guard let descriptor = try? validDescriptor(at: root),
                descriptor.compatibilityFingerprint == compatibilityFingerprint
            else { return nil }
            return (descriptor, root)
        }
        guard
            let selected = candidates.max(by: { lhs, rhs in
                if lhs.0.createdAt == rhs.0.createdAt {
                    return directoryName(for: lhs.0.identifier)
                        < directoryName(for: rhs.0.identifier)
                }
                return lhs.0.createdAt < rhs.0.createdAt
            })
        else { return nil }
        return StoreGenerationHandle(
            identifier: selected.0.identifier,
            compatibilityFingerprint: selected.0.compatibilityFingerprint,
            root: selected.1
        )
    }

    private static func validDescriptor(at generationRoot: URL) throws -> Descriptor {
        guard let directoryUUID = UUID(uuidString: generationRoot.lastPathComponent) else {
            throw AkashicError.invalidManifest
        }
        let descriptorURL = generationRoot.appendingPathComponent(
            descriptorName,
            isDirectory: false
        )
        try StorageDirectorySecurity.validateDirectory(generationRoot)
        let data = try BoundedFileReader.read(
            from: descriptorURL,
            maximumBytes: maximumMetadataBytes
        )
        if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
            envelope.schemaVersion != schemaVersion
        {
            throw AkashicError.unsupportedSchema
        }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
        guard descriptor.schemaVersion == schemaVersion,
            descriptor.identifier.rawValue == directoryUUID,
            normalizedCompatibilityFingerprint(descriptor.compatibilityFingerprint)
                == descriptor.compatibilityFingerprint
        else { throw AkashicError.invalidManifest }
        return descriptor
    }

    private static func normalizedCompatibilityFingerprint(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = normalized.utf8
        guard !bytes.isEmpty,
            bytes.count <= maximumCompatibilityFingerprintBytes,
            normalized.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 && scalar.value != 0x7f
            })
        else { return nil }
        return normalized
    }

    private static func publishPointer(
        for handle: StoreGenerationHandle,
        root: URL,
        faultInjector: (StoreGenerationSwitchPoint) throws -> Void
    ) throws {
        let pointer = Pointer(
            schemaVersion: schemaVersion,
            identifier: handle.identifier,
            compatibilityFingerprint: handle.compatibilityFingerprint
        )
        let temporary = root.appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        let current = root.appendingPathComponent(currentName, isDirectory: false)
        do {
            try JSONEncoder().encode(pointer).write(
                to: temporary,
                options: [.withoutOverwriting]
            )
            try StorageDirectorySecurity.securePublishedFile(temporary)
            try synchronizeFile(at: temporary)
            try faultInjector(.afterPointerStaged)
            try atomicReplace(temporary: temporary, destination: current)
            try synchronizeDirectory(at: root)
            try faultInjector(.afterPointerPublished)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func directoryName(for identifier: StoreGenerationID) -> String {
        identifier.rawValue.uuidString.lowercased()
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        let fileType = status.st_mode & S_IFMT
        guard (fileType == S_IFREG || fileType == S_IFDIR),
            status.st_uid == Darwin.geteuid()
        else { throw AkashicError.storageUnavailable }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        try synchronizeFile(at: url)
    }

    private static func atomicReplace(temporary: URL, destination: URL) throws {
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard result == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// `StoreGenerationManaging` 的目录实现；需要物理根目录时使用 `openHandle`。
public struct DirectoryStoreGenerationManager: StoreGenerationManaging, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func openGeneration(
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationDescriptor {
        try await openHandle(
            compatibilityFingerprint: compatibilityFingerprint
        ).descriptor
    }

    public func openHandle(
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationHandle {
        try await StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        )
    }
}
