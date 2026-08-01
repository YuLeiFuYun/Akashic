import AkashicCore
import AkashicDisk
import Darwin
import Foundation

@main
struct AkashicCrashProbe {
    private static let crashExitCode: Int32 = 91
    private static let crashPayload = Data("akashic-process-crash-payload-v1".utf8)

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            fputs(
                "usage: AkashicCrashProbe crash|inspect|random-crash|inspect-random|generation "
                    + "|full-volume-seed|full-volume-commit|full-volume-stage-publish "
                    + "|full-volume-inspect|full-volume-durable <root> [argument ...]\n",
                stderr
            )
            Darwin.exit(64)
        }
        let mode = arguments[1]
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        switch mode {
        case "crash":
            guard arguments.count == 4,
                let point = FileBlobStoreSwitchPoint(rawValue: arguments[3])
            else {
                fputs("invalid switch point\n", stderr)
                Darwin.exit(64)
            }
            try await runCrash(root: root, point: point)
            Darwin.exit(92)
        case "inspect":
            try await inspect(root: root, payload: crashPayload)
        case "random-crash":
            guard arguments.count == 4 || arguments.count == 5,
                let payloadByteCount = Int(arguments[3]),
                payloadByteCount > 0,
                payloadByteCount <= 64 * 1024 * 1024,
                let prewriteDelayMicroseconds = arguments.count == 5
                    ? UInt32(arguments[4]) : 0
            else {
                fputs(
                    "usage: AkashicCrashProbe random-crash <root> <payload-bytes> "
                        + "[prewrite-delay-us]\n",
                    stderr
                )
                Darwin.exit(64)
            }
            try await runRandomCrash(
                root: root,
                payloadByteCount: payloadByteCount,
                prewriteDelayMicroseconds: prewriteDelayMicroseconds
            )
        case "inspect-random":
            guard arguments.count == 4,
                let payloadByteCount = Int(arguments[3]),
                payloadByteCount > 0,
                payloadByteCount <= 64 * 1024 * 1024
            else {
                fputs(
                    "usage: AkashicCrashProbe inspect-random <root> <payload-bytes>\n",
                    stderr
                )
                Darwin.exit(64)
            }
            try await inspect(
                root: root,
                payload: deterministicPayload(byteCount: payloadByteCount)
            )
        case "generation":
            guard arguments.count == 5,
                let delayMilliseconds = UInt32(arguments[4])
            else {
                fputs("usage: AkashicCrashProbe generation <root> <fingerprint> <delay-ms>\n", stderr)
                Darwin.exit(64)
            }
            try runGenerationContentionParticipant(
                root: root,
                compatibilityFingerprint: arguments[3],
                delayMilliseconds: delayMilliseconds
            )
        case "full-volume-seed":
            guard arguments.count == 3 else {
                fputs("usage: AkashicCrashProbe full-volume-seed <root>\n", stderr)
                Darwin.exit(64)
            }
            await FullVolumeProbe.seed(root: root)
        case "full-volume-commit":
            guard let byteCount = fullVolumeByteCount(arguments) else {
                fputs("usage: AkashicCrashProbe full-volume-commit <root> <payload-bytes>\n", stderr)
                Darwin.exit(64)
            }
            await FullVolumeProbe.commit(root: root, payloadByteCount: byteCount)
        case "full-volume-stage-publish":
            guard let byteCount = fullVolumeByteCount(arguments) else {
                fputs(
                    "usage: AkashicCrashProbe full-volume-stage-publish <root> <payload-bytes>\n",
                    stderr
                )
                Darwin.exit(64)
            }
            try await FullVolumeProbe.stageThenPublish(
                root: root,
                payloadByteCount: byteCount
            )
        case "full-volume-inspect":
            guard let byteCount = fullVolumeByteCount(arguments) else {
                fputs("usage: AkashicCrashProbe full-volume-inspect <root> <payload-bytes>\n", stderr)
                Darwin.exit(64)
            }
            await FullVolumeProbe.inspect(root: root, payloadByteCount: byteCount)
        case "full-volume-durable":
            guard let byteCount = fullVolumeByteCount(arguments) else {
                fputs("usage: AkashicCrashProbe full-volume-durable <root> <payload-bytes>\n", stderr)
                Darwin.exit(64)
            }
            FullVolumeProbe.durableReplace(root: root, payloadByteCount: byteCount)
        default:
            fputs("unknown mode\n", stderr)
            Darwin.exit(64)
        }
    }

    private static func runGenerationContentionParticipant(
        root: URL,
        compatibilityFingerprint: String,
        delayMilliseconds: UInt32
    ) throws {
        let handle = try StoreGenerationDirectory.open(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        ) { point in
            if point == .afterGenerationDirectoryCreated, delayMilliseconds > 0 {
                usleep(delayMilliseconds * 1_000)
            }
        }
        print(handle.identifier.rawValue.uuidString.lowercased())
    }

    private static func runCrash(
        root: URL,
        point: FileBlobStoreSwitchPoint
    ) async throws {
        let digest = BlobDigest.sha256(of: crashPayload)
        let partition = try testPartition()
        let store = try await FileBlobStore.open(
            root: root,
            faultInjector: { observed in
                if observed == point { Darwin._exit(crashExitCode) }
            }
        )
        switch point {
        case .afterBlobDataWritten,
            .afterBlobFileSynced,
            .afterBlobRenamed,
            .afterBlobDirectorySynced,
            .afterBlobFilePublished:
            _ = try await store.stage(
                data: crashPayload,
                digest: digest,
                partition: partition
            )
        case .beforeManifestPublished,
            .afterManifestDataWritten,
            .afterManifestFileSynced,
            .afterManifestRenamed,
            .afterManifestDirectorySynced,
            .afterManifestPublished:
            let stage = try await store.stage(
                data: crashPayload,
                digest: digest,
                partition: partition
            )
            _ = try await store.publish(stage)
        }
    }

    private static func runRandomCrash(
        root: URL,
        payloadByteCount: Int,
        prewriteDelayMicroseconds: UInt32
    ) async throws {
        let payload = deterministicPayload(byteCount: payloadByteCount)
        let digest = BlobDigest.sha256(of: payload)
        let partition = try testPartition()
        let store = try await FileBlobStore.open(root: root)
        FileHandle.standardOutput.write(Data("ready\n".utf8))
        guard !FileHandle.standardInput.readData(ofLength: 1).isEmpty else {
            Darwin.exit(65)
        }
        if prewriteDelayMicroseconds > 0 { usleep(prewriteDelayMicroseconds) }
        let stage = try await store.stage(
            data: payload,
            digest: digest,
            partition: partition
        )
        _ = try await store.publish(stage)
        FileHandle.standardOutput.write(Data("committed\n".utf8))
        while true { _ = Darwin.pause() }
    }

    private static func inspect(root: URL, payload: Data) async throws {
        let digest = BlobDigest.sha256(of: payload)
        let partition = try testPartition()
        let store = try await FileBlobStore.open(root: root)
        let disposition: String
        do {
            let restored = try await store.read(
                digest: digest,
                partition: partition
            )
            disposition = restored == payload ? "hit" : "corrupt"
        } catch AkashicError.notFound {
            disposition = "miss"
        }

        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let blobCount = ((try? FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []).count
        let temporaryCount = recursiveChildren(root: root).filter {
            $0.lastPathComponent.hasPrefix(".durable-tmp-")
                || $0.lastPathComponent.hasPrefix(".tmp-")
        }.count
        let result: [String: Any] = [
            "schemaVersion": 1,
            "disposition": disposition,
            "blobCount": blobCount,
            "temporaryCount": temporaryCount,
            "manifestExists": FileManager.default.fileExists(
                atPath: root.appendingPathComponent("manifest.json").path
            ),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private static func deterministicPayload(byteCount: Int) -> Data {
        Data(repeating: 0xa5, count: byteCount)
    }

    private static func testPartition() throws -> CachePartitionID {
        try CachePartitionID.derive(
            domain: "akashic-process-crash-matrix",
            material: Data([0x01])
        )
    }

    private static func recursiveChildren(root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    private static func fullVolumeByteCount(_ arguments: [String]) -> Int? {
        guard arguments.count == 4,
            let value = Int(arguments[3]),
            value > 0,
            value <= 64 * 1024 * 1024
        else { return nil }
        return value
    }
}
