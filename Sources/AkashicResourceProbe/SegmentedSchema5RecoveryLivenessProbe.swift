import AkashicCore
import AkashicDisk
import Foundation

private struct Schema5RecoveryLivenessReport: Codable {
    let schemaVersion: Int
    let beforeCount: Int
    let afterCommitCount: Int
    let afterReopenCount: Int
    let candidateAbsentBefore: Bool
    let commitSucceeded: Bool
    let candidatePresentAfterCommit: Bool
    let candidatePresentAfterReopen: Bool
    let preexistingAuthorityPreservedAfterCommit: Bool
    let preexistingAuthorityPreservedAfterReopen: Bool
    let finalRootGeneration: UInt64
    let finalRootRunCount: Int
    let finalActiveDistinctKeys: Int
    let claims: Claims

    struct Claims: Codable {
        let authorityAdvanceExactness: Bool
        let recoveryLivenessMechanism: Bool
        let crashConsistencyByItself: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
    }
}

enum SegmentedSchema5RecoveryLivenessProbe {
    static func run(arguments: [String]) async throws {
        let root = try parseRoot(arguments)
        let limits = FileBlobStoreLimits(
            softTotalBytes: 64 * 1_024 * 1_024,
            maximumBlobBytes: 1 * 1_024 * 1_024
        )
        var store: FileBlobStore? = try await FileBlobStore.open(root: root, limits: limits)
        let before = await store!.resourceProbeManifestShadowSnapshot()
        let partition = try CachePartitionID.derive(
            domain: "schema5-recovery-liveness-v1",
            material: Data("post-recovery-independent-key".utf8)
        )
        let data = Data("post-recovery-independent-payload-v1".utf8)
        let digest = BlobDigest.sha256(of: data)
        let key = FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition)
        let candidateAbsentBefore = before.entries[key] == nil

        var commitSucceeded = false
        if candidateAbsentBefore {
            _ = try await store!.commit(data: data, digest: digest, partition: partition)
            commitSucceeded = true
        }
        let afterCommit = await store!.resourceProbeManifestShadowSnapshot()
        let candidatePresentAfterCommit = afterCommit.entries[key] != nil
        let preexistingAuthorityPreservedAfterCommit = before.entries.allSatisfy {
            afterCommit.entries[$0.key] == $0.value
        }
        store = nil

        store = try await FileBlobStore.open(root: root, limits: limits)
        let reopened = await store!.resourceProbeManifestShadowSnapshot()
        let head = try await store!.resourceProbeDirectoryHeadEpochSnapshot()
        let finalRoot = try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let candidatePresentAfterReopen = reopened.entries[key] != nil
        let preexistingAuthorityPreservedAfterReopen = before.entries.allSatisfy {
            reopened.entries[$0.key] == $0.value
        }
        store = nil

        let report = Schema5RecoveryLivenessReport(
            schemaVersion: 1,
            beforeCount: before.entries.count,
            afterCommitCount: afterCommit.entries.count,
            afterReopenCount: reopened.entries.count,
            candidateAbsentBefore: candidateAbsentBefore,
            commitSucceeded: commitSucceeded,
            candidatePresentAfterCommit: candidatePresentAfterCommit,
            candidatePresentAfterReopen: candidatePresentAfterReopen,
            preexistingAuthorityPreservedAfterCommit: preexistingAuthorityPreservedAfterCommit,
            preexistingAuthorityPreservedAfterReopen: preexistingAuthorityPreservedAfterReopen,
            finalRootGeneration: finalRoot.generation,
            finalRootRunCount: finalRoot.runs.count,
            finalActiveDistinctKeys: head.distinctKeyCount,
            claims: .init(
                authorityAdvanceExactness: true,
                recoveryLivenessMechanism: true,
                crashConsistencyByItself: false,
                formalPerformance: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))

        guard candidateAbsentBefore,
            commitSucceeded,
            candidatePresentAfterCommit,
            candidatePresentAfterReopen,
            afterCommit.entries.count == before.entries.count + 1,
            reopened.entries == afterCommit.entries,
            preexistingAuthorityPreservedAfterCommit,
            preexistingAuthorityPreservedAfterReopen
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func parseRoot(_ arguments: [String]) throws -> URL {
        guard arguments.count == 2,
            arguments[0] == "--root",
            arguments[1].hasPrefix("/")
        else { throw ProbeError.invalidArguments }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }
}
