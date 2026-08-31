import AkashicCore
import AkashicDisk
import Foundation

extension SegmentedManifestShadowProbe {
    struct Schema5IndexedRecoveryControlResult {
        let unaffectedConflictRejected: Bool
        let sameRunSwapAccepted: Bool
        let corruptRunRejected: Bool
    }

    static func schema5IndexedRecoveryControls(
        root: URL
    ) throws -> Schema5IndexedRecoveryControlResult {
        let baseEntries = try makeBaseEntries(count: 4)
        let baseShadow = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let baseState = schema5Entries(baseShadow)
        let baseSnapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: schema5ShadowEntries(baseShadow)
        )
        return Schema5IndexedRecoveryControlResult(
            unaffectedConflictRejected: try schema5UnaffectedConflictRejected(
                root: root,
                baseEntries: baseEntries,
                baseSnapshot: baseSnapshot
            ),
            sameRunSwapAccepted: try schema5SameRunSwapAccepted(
                root: root,
                baseEntries: baseEntries,
                baseState: baseState,
                baseSnapshot: baseSnapshot
            ),
            corruptRunRejected: try schema5IndexedCorruptRunRejected(
                root: root,
                baseEntries: baseEntries,
                baseSnapshot: baseSnapshot
            )
        )
    }

    private static func schema5UnaffectedConflictRejected(
        root: URL,
        baseEntries: [SegmentedShadowEntry],
        baseSnapshot: Data
    ) throws -> Bool {
        let caseRoot = root.appendingPathComponent("indexed-conflict", isDirectory: true)
        let segments = caseRoot.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(caseRoot)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseSnapshot,
            entryCount: baseEntries.count,
            fileName: "base-indexed-conflict.json",
            directory: segments
        )
        let target = baseEntries[0]
        let unaffectedOwner = baseEntries[1]
        let conflict = SegmentedManifestEntry(
            key: target.key,
            physicalID: unaffectedOwner.physicalID,
            partition: target.partition,
            digest: target.digest,
            byteCount: target.byteCount,
            lastAccess: target.lastAccess
        )
        let run = try SegmentedManifestPrototypeV1.writeRun(
            [.upsert(conflict)],
            fileName: "run-indexed-conflict.seg",
            directory: segments
        )
        let manifestRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 2,
            base: base,
            runs: [run]
        )
        let rootURL = caseRoot.appendingPathComponent("manifest.json")
        try SegmentedManifestPrototypeV1.writeRoot(manifestRoot, to: rootURL)
        do {
            _ = try SegmentedManifestPrototypeV1.recover(
                rootURL: rootURL,
                segmentDirectory: segments
            )
            return false
        } catch {
            return true
        }
    }

    private static func schema5SameRunSwapAccepted(
        root: URL,
        baseEntries: [SegmentedShadowEntry],
        baseState: [String: SegmentedManifestEntry],
        baseSnapshot: Data
    ) throws -> Bool {
        let caseRoot = root.appendingPathComponent("indexed-swap", isDirectory: true)
        let segments = caseRoot.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(caseRoot)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseSnapshot,
            entryCount: baseEntries.count,
            fileName: "base-indexed-swap.json",
            directory: segments
        )
        let first = baseEntries[0]
        let second = baseEntries[1]
        let swappedFirst = SegmentedManifestEntry(
            key: first.key,
            physicalID: second.physicalID,
            partition: first.partition,
            digest: first.digest,
            byteCount: first.byteCount,
            lastAccess: first.lastAccess
        )
        let swappedSecond = SegmentedManifestEntry(
            key: second.key,
            physicalID: first.physicalID,
            partition: second.partition,
            digest: second.digest,
            byteCount: second.byteCount,
            lastAccess: second.lastAccess
        )
        let mutations: [SegmentedManifestMutation] = [
            .upsert(swappedFirst), .upsert(swappedSecond),
        ].sorted { $0.key < $1.key }
        let run = try SegmentedManifestPrototypeV1.writeRun(
            mutations,
            fileName: "run-indexed-swap.seg",
            directory: segments
        )
        let manifestRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 2,
            base: base,
            runs: [run]
        )
        let rootURL = caseRoot.appendingPathComponent("manifest.json")
        try SegmentedManifestPrototypeV1.writeRoot(manifestRoot, to: rootURL)
        let recovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: rootURL,
            segmentDirectory: segments
        )
        var expected = baseState
        expected[first.key] = swappedFirst
        expected[second.key] = swappedSecond
        return recovered == expected
    }

    private static func schema5IndexedCorruptRunRejected(
        root: URL,
        baseEntries: [SegmentedShadowEntry],
        baseSnapshot: Data
    ) throws -> Bool {
        let caseRoot = root.appendingPathComponent("indexed-corrupt", isDirectory: true)
        let segments = caseRoot.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(caseRoot)
        try StorageDirectorySecurity.prepareDirectory(segments)
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseSnapshot,
            entryCount: baseEntries.count,
            fileName: "base-indexed-corrupt.json",
            directory: segments
        )
        let source = baseEntries[0]
        let repair = SegmentedManifestEntry(
            key: source.key,
            physicalID: PhysicalBlobID(),
            partition: source.partition,
            digest: source.digest,
            byteCount: source.byteCount,
            lastAccess: source.lastAccess
        )
        let run = try SegmentedManifestPrototypeV1.writeRun(
            [.upsert(repair)],
            fileName: "run-indexed-corrupt.seg",
            directory: segments
        )
        let runURL = segments.appendingPathComponent(run.fileName)
        var data = try BoundedFileReader.read(from: runURL, maximumBytes: run.byteCount)
        data[data.startIndex + SegmentedManifestPrototypeV1.headerBytes + 3] ^= 0x01
        try DurableFileWriter.writeReplacing(data, to: runURL)
        let manifestRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 2,
            base: base,
            runs: [run]
        )
        let rootURL = caseRoot.appendingPathComponent("manifest.json")
        try SegmentedManifestPrototypeV1.writeRoot(manifestRoot, to: rootURL)
        do {
            _ = try SegmentedManifestPrototypeV1.recover(
                rootURL: rootURL,
                segmentDirectory: segments
            )
            return false
        } catch {
            return true
        }
    }
}
