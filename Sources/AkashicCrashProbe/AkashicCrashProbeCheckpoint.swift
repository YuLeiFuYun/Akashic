import AkashicCore
import AkashicDisk
import Darwin
import Foundation

extension AkashicCrashProbe {
    enum DirectoryHeadCheckpointCrashPoint: String {
        case afterSnapshotDataWritten
        case afterSnapshotFileSynced
        case afterSnapshotRenamed
        case afterSnapshotDirectorySynced
        case afterFirstHeadSet
        case afterSecondHeadSet
        case afterHeadDirectorySynced
    }

    static let directoryHeadCheckpointSeedCount =
        FileBlobStore.manifestCheckpointRecordLimit - 1

    static func runDirectoryHeadCheckpointSeed(root: URL) async throws {
        let store = try await FileBlobStore.open(root: root)
        guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
            fputs("directory-head carrier unavailable\n", stderr)
            Darwin.exit(66)
        }
        let partition = try directoryHeadCheckpointPartition()
        for index in 0..<directoryHeadCheckpointSeedCount {
            let payload = directoryHeadCheckpointPayload(index: index)
            _ = try await store.commit(
                data: payload,
                digest: BlobDigest.sha256(of: payload),
                partition: partition
            )
        }
    }

    static func runDirectoryHeadCheckpointCrash(
        root: URL,
        point: DirectoryHeadCheckpointCrashPoint
    ) async throws {
        let system = FileBlobStoreDirectoryHeadOperations.system
        let headSetCounter = DirectoryHeadCheckpointHeadSetCounter()
        let operations = FileBlobStoreDirectoryHeadOperations(
            listAttributes: system.listAttributes,
            readAttribute: system.readAttribute,
            setAttribute: { name, value, url, flags in
                try system.setAttribute(name, value, url, flags)
                guard let ordinal = headSetCounter.observe(name: name) else { return }
                if point == .afterFirstHeadSet, ordinal == 1 {
                    Darwin._exit(crashExitCode)
                }
                if point == .afterSecondHeadSet, ordinal == 2 {
                    Darwin._exit(crashExitCode)
                }
            },
            removeAttribute: system.removeAttribute,
            synchronizeDirectory: { url in
                try system.synchronizeDirectory(url)
                if point == .afterHeadDirectorySynced { Darwin._exit(crashExitCode) }
            }
        )
        let store = try await FileBlobStore.open(
            root: root,
            faultInjector: { observed in
                if point == .afterSnapshotDataWritten,
                    observed == .afterManifestDataWritten
                {
                    Darwin._exit(crashExitCode)
                }
                if point == .afterSnapshotFileSynced,
                    observed == .afterManifestFileSynced
                {
                    Darwin._exit(crashExitCode)
                }
                if point == .afterSnapshotRenamed, observed == .afterManifestRenamed {
                    Darwin._exit(crashExitCode)
                }
                if point == .afterSnapshotDirectorySynced,
                    observed == .afterManifestDirectorySynced
                {
                    Darwin._exit(crashExitCode)
                }
            },
            directoryHeadOperations: operations
        )
        let payload = directoryHeadCheckpointPayload(index: directoryHeadCheckpointSeedCount)
        _ = try await store.commit(
            data: payload,
            digest: BlobDigest.sha256(of: payload),
            partition: directoryHeadCheckpointPartition()
        )
    }

    static func runDirectoryHeadCheckpointRecoveryCrash(root: URL) async throws {
        let system = FileBlobStoreDirectoryHeadOperations.system
        let operations = FileBlobStoreDirectoryHeadOperations(
            listAttributes: system.listAttributes,
            readAttribute: system.readAttribute,
            setAttribute: { name, value, url, flags in
                try system.setAttribute(name, value, url, flags)
                if name.hasPrefix("dev.akashic.mh1.") {
                    Darwin._exit(crashExitCode)
                }
            },
            removeAttribute: system.removeAttribute,
            synchronizeDirectory: system.synchronizeDirectory
        )
        _ = try await FileBlobStore.open(
            root: root,
            faultInjector: { _ in },
            directoryHeadOperations: operations
        )
    }

    static func inspectDirectoryHeadCheckpointRaw(root: URL) throws {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestData = try Data(contentsOf: manifestURL)
        let envelope = try JSONDecoder().decode(
            DirectoryHeadCheckpointManifestEnvelope.self,
            from: manifestData
        )
        let generationHex = String(format: "%016llx", envelope.generation)
        let headNames = [
            "dev.akashic.mh1.g\(generationHex).0",
            "dev.akashic.mh1.g\(generationHex).1",
        ]
        let currentRecordPrefix = "dev.akashic.md1.g\(generationHex)."
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let names = try FileBlobStoreDirectoryHeadOperations.system.listAttributes(
            blobs,
            FileBlobStore.maximumDirectoryHeadXattrListBytes
        )
        let currentHeads = headNames.filter { names.contains($0) }.sorted()
        let currentRecords = names.filter { $0.hasPrefix(currentRecordPrefix) }.sorted()
        let result: [String: Any] = [
            "schemaVersion": 1,
            "manifestGeneration": envelope.generation,
            "currentHeadCount": currentHeads.count,
            "currentHeadNames": currentHeads,
            "currentRecordCount": currentRecords.count,
            "currentRecordNames": currentRecords,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    static func inspectDirectoryHeadCheckpoint(root: URL) async throws {
        let store = try await FileBlobStore.open(root: root)
        let partition = try directoryHeadCheckpointPartition()
        let expectedCount = directoryHeadCheckpointSeedCount + 1
        var missingIndices: [Int] = []
        missingIndices.reserveCapacity(expectedCount)
        for index in 0..<expectedCount {
            let payload = directoryHeadCheckpointPayload(index: index)
            let digest = BlobDigest.sha256(of: payload)
            if await store.physicalID(digest: digest, partition: partition) == nil {
                missingIndices.append(index)
            }
        }

        let sentinelIndices = [0, directoryHeadCheckpointSeedCount / 2,
            directoryHeadCheckpointSeedCount - 1, directoryHeadCheckpointSeedCount]
        var sentinelFailures: [Int] = []
        for index in sentinelIndices {
            let payload = directoryHeadCheckpointPayload(index: index)
            let digest = BlobDigest.sha256(of: payload)
            do {
                let restored = try await store.read(digest: digest, partition: partition)
                if restored != payload { sentinelFailures.append(index) }
            } catch {
                sentinelFailures.append(index)
            }
        }

        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let visibleChildren = (try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let temporaryCount = recursiveChildren(root: root).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(".durable-tmp-")
                || name.hasPrefix(".tmp-")
                || name.hasPrefix(".fast-xattr-blob-")
                || name.hasPrefix(".fast-blob-")
                || name.hasPrefix(".fast-record-")
        }.count
        let result: [String: Any] = [
            "schemaVersion": 1,
            "expectedEntryCount": expectedCount,
            "missingEntryCount": missingIndices.count,
            "missingIndices": missingIndices,
            "sentinelFailureCount": sentinelFailures.count,
            "sentinelFailures": sentinelFailures,
            "blobCount": visibleChildren.count,
            "temporaryCount": temporaryCount,
            "manifestExists": FileManager.default.fileExists(
                atPath: root.appendingPathComponent("manifest.json").path
            ),
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    static func directoryHeadCheckpointPayload(index: Int) -> Data {
        Data("akashic-directory-head-checkpoint-\(index)".utf8)
    }

    static func directoryHeadCheckpointPartition() throws -> CachePartitionID {
        try CachePartitionID.derive(
            domain: "akashic-directory-head-checkpoint-crash-matrix",
            material: Data([0x01])
        )
    }
}

struct DirectoryHeadCheckpointManifestEnvelope: Decodable {
    let generation: UInt64
}

final class DirectoryHeadCheckpointHeadSetCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func observe(name: String) -> Int? {
        guard name.hasPrefix("dev.akashic.mh1.") else { return nil }
        lock.lock()
        count += 1
        let observed = count
        lock.unlock()
        return observed
    }
}
