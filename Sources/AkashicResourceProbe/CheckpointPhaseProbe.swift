import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum CheckpointPhaseProbeError: Error {
    case invalidArguments
    case invalidManifest
}

private struct CheckpointPhaseEvent: Codable {
    let point: String
    let offsetNanoseconds: UInt64
}

private struct CheckpointPhaseInterval: Codable {
    let from: String
    let to: String
    let nanoseconds: UInt64
}

private struct CheckpointMirrorManifest: Codable {
    let schemaVersion: UInt16
    let generation: UInt64
    let entries: [String: CheckpointMirrorEntry]
}

private struct CheckpointMirrorEntry: Codable {
    let physicalID: PhysicalBlobID
    let partition: CachePartitionID
    let digest: BlobDigest
    let byteCount: Int
    let lastAccess: Date
}

private struct CheckpointPhaseReport: Codable {
    let schemaVersion: Int
    let commitCount: Int
    let blobBytes: Int
    let measuredCommitOrdinal: Int
    let commitNanoseconds: UInt64
    let manifestGeneration: UInt64
    let manifestRecordCount: Int
    let manifestBytes: Int
    let manifestEncodeBaselineNanoseconds: [UInt64]
    let durableReplaceBaselineNanoseconds: [UInt64]
    let events: [CheckpointPhaseEvent]
    let intervals: [CheckpointPhaseInterval]
    let claims: CheckpointPhaseClaims
}

private struct CheckpointPhaseClaims: Codable {
    let formalPerformance: Bool
    let physicalDevice: Bool
    let physicalIOBytes: Bool
}

private final class CheckpointPhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var origin: UInt64 = 0
    private var events: [CheckpointPhaseEvent] = []

    func begin() -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        origin = now
        events.removeAll(keepingCapacity: true)
        enabled = true
        lock.unlock()
        return now
    }

    func record(_ point: FileBlobStoreSwitchPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        events.append(
            CheckpointPhaseEvent(
                point: point.rawValue,
                offsetNanoseconds: now &- origin
            )
        )
    }

    func finish(commitEnd: UInt64) -> (events: [CheckpointPhaseEvent], intervals: [CheckpointPhaseInterval]) {
        lock.lock()
        enabled = false
        let origin = self.origin
        let captured = events
        lock.unlock()

        var points: [(String, UInt64)] = [("commitStart", 0)]
        points.append(contentsOf: captured.map { ($0.point, $0.offsetNanoseconds) })
        points.append(("commitEnd", commitEnd &- origin))
        let intervals = zip(points, points.dropFirst()).map { lhs, rhs in
            CheckpointPhaseInterval(
                from: lhs.0,
                to: rhs.0,
                nanoseconds: rhs.1 &- lhs.1
            )
        }
        return (captured, intervals)
    }
}

enum CheckpointPhaseProbe {
    static func run(arguments: [String]) async throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw CheckpointPhaseProbeError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootValue = values["--root"],
            let commitCountValue = values["--commit-count"],
            let blobBytesValue = values["--blob-bytes"],
            let commitCount = Int(commitCountValue), commitCount >= 2,
            let blobBytes = Int(blobBytesValue), blobBytes >= 8
        else {
            throw CheckpointPhaseProbeError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let logicalBytes = commitCount.multipliedReportingOverflow(by: blobBytes)
        guard !logicalBytes.overflow else { throw CheckpointPhaseProbeError.invalidArguments }
        let softLimit = logicalBytes.partialValue.multipliedReportingOverflow(by: 4)
        guard !softLimit.overflow else { throw CheckpointPhaseProbeError.invalidArguments }

        let recorder = CheckpointPhaseRecorder()
        let partition = try CachePartitionID.derive(
            domain: "akashic-resource-checkpoint-phase-v1",
            material: Data("domain-neutral".utf8)
        )
        let store = try await FileBlobStore.open(
            root: root,
            limits: FileBlobStoreLimits(
                softTotalBytes: max(blobBytes, softLimit.partialValue),
                maximumBlobBytes: blobBytes
            ),
            faultInjector: { point in recorder.record(point) }
        )

        var finalStart: UInt64 = 0
        var finalEnd: UInt64 = 0
        for commitIndex in 0 ..< commitCount {
            let data = payload(index: commitIndex, byteCount: blobBytes)
            let digest = BlobDigest.sha256(of: data)
            if commitIndex == commitCount - 1 {
                finalStart = recorder.begin()
            }
            _ = try await store.commit(
                data: data,
                digest: digest,
                partition: partition
            )
            if commitIndex == commitCount - 1 {
                finalEnd = DispatchTime.now().uptimeNanoseconds
            }
        }

        let captured = recorder.finish(commitEnd: finalEnd)
        let manifest = try manifestState(root: root)
        let manifestEncodeBaselines = try await manifestEncodeBaselines(
            store: store,
            repetitions: 5
        )
        let durableBaselines = try durableReplaceBaselines(
            root: root,
            byteCount: manifest.bytes,
            repetitions: 5
        )
        let report = CheckpointPhaseReport(
            schemaVersion: 1,
            commitCount: commitCount,
            blobBytes: blobBytes,
            measuredCommitOrdinal: commitCount,
            commitNanoseconds: finalEnd &- finalStart,
            manifestGeneration: manifest.generation,
            manifestRecordCount: manifest.recordCount,
            manifestBytes: manifest.bytes,
            manifestEncodeBaselineNanoseconds: manifestEncodeBaselines,
            durableReplaceBaselineNanoseconds: durableBaselines,
            events: captured.events,
            intervals: captured.intervals,
            claims: CheckpointPhaseClaims(
                formalPerformance: false,
                physicalDevice: false,
                physicalIOBytes: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func manifestEncodeBaselines(
        store: FileBlobStore,
        repetitions: Int
    ) async throws -> [UInt64] {
        var samples: [UInt64] = []
        samples.reserveCapacity(repetitions)
        var expectedBytes: Int?
        for _ in 0 ..< repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            let encoded = try await store.resourceProbeEncodedManifestSnapshot()
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
            if let expectedBytes {
                guard encoded.count == expectedBytes else {
                    throw CheckpointPhaseProbeError.invalidManifest
                }
            } else {
                expectedBytes = encoded.count
            }
        }
        return samples
    }

    private static func durableReplaceBaselines(
        root: URL,
        byteCount: Int,
        repetitions: Int
    ) throws -> [UInt64] {
        let destination = root.appendingPathComponent(
            "t102-durable-baseline.bin",
            isDirectory: false
        )
        let data = Data(repeating: 0x5A, count: byteCount)
        var samples: [UInt64] = []
        samples.reserveCapacity(repetitions)
        for _ in 0 ..< repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            try DurableFileWriter.writeReplacing(data, to: destination)
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
        }
        try? FileManager.default.removeItem(at: destination)
        return samples
    }

    private static func payload(index: Int, byteCount: Int) -> Data {
        var result = Data(repeating: 0xA5, count: byteCount)
        var value = UInt64(index).littleEndian
        withUnsafeBytes(of: &value) { bytes in
            result.replaceSubrange(0 ..< 8, with: bytes)
        }
        return result
    }

    private static func manifestState(root: URL) throws -> (
        generation: UInt64,
        recordCount: Int,
        bytes: Int
    ) {
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
            let generation = dictionary["generation"] as? NSNumber
        else {
            throw CheckpointPhaseProbeError.invalidManifest
        }
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        let recordCount = names.reduce(into: 0) { count, name in
            if name.hasPrefix(".manifest-entry-") && name.hasSuffix(".json") {
                count += 1
            }
        }
        return (generation.uint64Value, recordCount, data.count)
    }
}
