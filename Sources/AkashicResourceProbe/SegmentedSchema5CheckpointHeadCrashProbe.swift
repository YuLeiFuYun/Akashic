import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private final class Schema5CheckpointHeadCrashCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func didWriteHead() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == 1
    }
}

private struct Schema5CheckpointHeadPlanReport: Codable {
    let schemaVersion: Int
    let newEntryCount: Int
    let newIdentityCommitment: String
    let stagedPhysicalID: String
}

extension SegmentedManifestShadowProbe {
    static func schema5CheckpointOneHeadCrash(arguments: [String]) async throws {
        guard arguments.count == 4,
            arguments[0] == "--root",
            arguments[2] == "--plan"
        else { throw SegmentedManifestShadowError.invalidArguments }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let planURL = URL(fileURLWithPath: arguments[3], isDirectory: false)
        let system = FileBlobStoreDirectoryHeadOperations.system
        let counter = Schema5CheckpointHeadCrashCounter()
        let operations = FileBlobStoreDirectoryHeadOperations(
            listAttributes: system.listAttributes,
            readAttribute: system.readAttribute,
            setAttribute: { name, data, url, flags in
                try system.setAttribute(name, data, url, flags)
                if counter.didWriteHead() { Darwin._exit(91) }
            },
            removeAttribute: system.removeAttribute,
            synchronizeDirectory: system.synchronizeDirectory
        )
        let store = try await FileBlobStore.open(
            root: root,
            faultInjector: { _ in },
            directoryHeadOperations: operations
        )
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        guard active.distinctKeyCount == 511 else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let target = try schema5IntegrationIdentities(prefix: "hot", count: 512)[511]
        let before = await store.resourceProbeManifestShadowSnapshot()
        let stage = try await store.stage(
            data: target.data,
            digest: target.digest,
            partition: target.partition
        )
        guard let pending = await store.resourceProbePendingStageEntry(stage) else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var planned = before.entries
        planned[target.key] = pending
        let report = Schema5CheckpointHeadPlanReport(
            schemaVersion: 1,
            newEntryCount: planned.count,
            newIdentityCommitment: try schema5IdentityCommitment(planned),
            stagedPhysicalID: pending.physicalID.rawValue.uuidString.lowercased()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableFileWriter.writeReplacing(try encoder.encode(report), to: planURL)
        _ = try await store.publish(stage)
        Darwin._exit(92)
    }
}
