import AkashicCore
import AkashicDisk
import Darwin
import Dispatch
import Foundation

private enum BypassServiceProbeError: Error {
    case timeout(String)
    case invariant(String)
}

private struct BypassServiceTiming: Sendable {
    var enqueue: UInt64 = 0
    var start: UInt64 = 0
    var finish: UInt64 = 0
}

private final class BypassServiceState: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [String: useconds_t] = [:]
    private var timings: [String: BypassServiceTiming] = [:]
    private var activeCount = 0
    private var activeBytes = 0
    private var peakCount = 0
    private var peakBytes = 0

    func register(_ label: String, delay: useconds_t) {
        lock.lock()
        delays[label] = delay
        timings[label] = BypassServiceTiming()
        lock.unlock()
    }

    func markEnqueue(_ label: String) {
        lock.lock()
        timings[label]?.enqueue = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    func hasStarted(_ label: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (timings[label]?.start ?? 0) != 0
    }

    func timing(_ label: String) -> BypassServiceTiming? {
        lock.lock()
        defer { lock.unlock() }
        return timings[label]
    }

    func peaks() -> (count: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (peakCount, peakBytes)
    }

    func read(url: URL, maximumBytes: Int, expectedBytes: Int?) throws -> BoundedFileReadResult {
        let label = url.lastPathComponent
        let bytes = max(1, expectedBytes ?? maximumBytes)
        let delay: useconds_t
        lock.lock()
        guard let registeredDelay = delays[label] else {
            lock.unlock()
            throw BypassServiceProbeError.invariant("missing-delay-\(label)")
        }
        delay = registeredDelay
        timings[label]?.start = DispatchTime.now().uptimeNanoseconds
        activeCount += 1
        activeBytes += bytes
        peakCount = max(peakCount, activeCount)
        peakBytes = max(peakBytes, activeBytes)
        lock.unlock()

        if delay > 0 { usleep(delay) }

        lock.lock()
        timings[label]?.finish = DispatchTime.now().uptimeNanoseconds
        activeCount -= 1
        activeBytes -= bytes
        lock.unlock()
        return BoundedFileReadResult(
            data: Data(repeating: 0x6b, count: expectedBytes ?? maximumBytes),
            modificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct BypassServiceHarness: Sendable {
    let scheduler: FileBlobStoreReadIO
    let state: BypassServiceState

    init(indexed: Bool) {
        let state = BypassServiceState()
        self.state = state
        scheduler = FileBlobStoreReadIO(
            maximumConcurrentReads: 4,
            maximumInFlightBytes: 64,
            maximumPendingReads: 128,
            maximumBypassesPerBlockedHead: indexed ? 3 : 0,
            bypassLookupMode: .conservativeSizeIndex,
            operations: FileBlobStoreReadOperations(read: { url, maximumBytes, expectedBytes in
                try state.read(url: url, maximumBytes: maximumBytes, expectedBytes: expectedBytes)
            })
        )
    }

    func submit(bytes: Int, label: String, delay: useconds_t) -> Task<String, Never> {
        state.register(label, delay: delay)
        let data = Data(repeating: 0x6b, count: bytes)
        let digest = BlobDigest.sha256(of: data)
        let url = URL(fileURLWithPath: "/akashic-bypass-service/\(label)")
        return Task {
            state.markEnqueue(label)
            do {
                _ = try await scheduler.readVerified(
                    from: url,
                    maximumBytes: bytes,
                    expectedBytes: bytes,
                    digest: digest
                )
                return "ok"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "error"
            }
        }
    }
}

private struct BypassServiceWorkload {
    let id: String
    let activeBytes: [Int]
    let activeMicros: [useconds_t]
    let headBytes: Int
    let headMicros: useconds_t
    let laterBytes: [Int]
    let laterMicros: useconds_t
    let headInitiallyFits: Bool
}

private struct BypassServiceRepetition {
    let headWait: UInt64
    let smallStartWaits: [UInt64]
    let smallTotalWaits: [UInt64]
    let laterIOStartsBeforeHead: Int
    let schedulerBypassesAtHeadStart: Int
    let peakActiveCount: Int
    let peakActiveBytes: Int
}

private struct BypassServiceResult: Codable {
    let workload: String
    let policy: String
    let repetitions: Int
    let laterRequestsPerRepetition: Int
    let headWaitP50Nanoseconds: UInt64
    let headWaitP95Nanoseconds: UInt64
    let headWaitP99Nanoseconds: UInt64
    let smallStartWaitP50Nanoseconds: UInt64
    let smallStartWaitP95Nanoseconds: UInt64
    let smallStartWaitP99Nanoseconds: UInt64
    let smallTotalWaitP95Nanoseconds: UInt64
    let maximumLaterIOStartsBeforeHead: Int
    let maximumSchedulerBypassesAtHeadStart: Int
    let maximumPeakActiveCount: Int
    let maximumPeakActiveBytes: Int
    let passedResourceBounds: Bool
}

private struct BypassServiceReport: Codable {
    struct Claims: Codable {
        let productionDefaultChanged: Bool
        let formalLatency: Bool
        let filesystemIO: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let candidateBypasses: Int
    let repetitions: Int
    let results: [BypassServiceResult]
    let allResourceBoundsPass: Bool
    let claims: Claims
}

enum ReadSchedulerBoundedBypassServiceProbe {
    private static let repetitions = 4

    static func run() async throws {
        let workloads = makeWorkloads()
        var results: [BypassServiceResult] = []
        for workload in workloads {
            results.append(try await run(workload, indexed: false))
            results.append(try await run(workload, indexed: true))
        }
        let allBounds = results.allSatisfy(\.passedResourceBounds)
        let report = BypassServiceReport(
            schemaVersion: 1,
            candidateBypasses: 3,
            repetitions: repetitions,
            results: results,
            allResourceBoundsPass: allBounds,
            claims: .init(
                productionDefaultChanged: false,
                formalLatency: false,
                filesystemIO: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allBounds else { throw BypassServiceProbeError.invariant("resource-bound") }
    }

    private static func run(
        _ workload: BypassServiceWorkload,
        indexed: Bool
    ) async throws -> BypassServiceResult {
        var rows: [BypassServiceRepetition] = []
        for repetition in 0..<repetitions {
            rows.append(try await runOnce(workload, indexed: indexed, repetition: repetition))
        }
        let headWaits = rows.map(\.headWait)
        let startWaits = rows.flatMap(\.smallStartWaits)
        let totalWaits = rows.flatMap(\.smallTotalWaits)
        let maxPeakBytes = rows.map(\.peakActiveBytes).max() ?? 0
        let normalByteBound = workload.headBytes <= 64 ? maxPeakBytes <= 64 : true
        let oversizeExclusive = workload.headBytes <= 64 || rows.allSatisfy { row in
            row.peakActiveCount <= 4 && row.peakActiveBytes <= max(64, workload.headBytes)
        }
        let resourcePass = rows.allSatisfy { $0.peakActiveCount <= 4 }
            && normalByteBound
            && oversizeExclusive
        return BypassServiceResult(
            workload: workload.id,
            policy: indexed ? "indexed-bypass-3" : "strict-fifo-0",
            repetitions: repetitions,
            laterRequestsPerRepetition: workload.laterBytes.count,
            headWaitP50Nanoseconds: percentile(headWaits, 50),
            headWaitP95Nanoseconds: percentile(headWaits, 95),
            headWaitP99Nanoseconds: percentile(headWaits, 99),
            smallStartWaitP50Nanoseconds: percentile(startWaits, 50),
            smallStartWaitP95Nanoseconds: percentile(startWaits, 95),
            smallStartWaitP99Nanoseconds: percentile(startWaits, 99),
            smallTotalWaitP95Nanoseconds: percentile(totalWaits, 95),
            maximumLaterIOStartsBeforeHead: rows.map(\.laterIOStartsBeforeHead).max() ?? 0,
            maximumSchedulerBypassesAtHeadStart: rows.map(\.schedulerBypassesAtHeadStart).max() ?? 0,
            maximumPeakActiveCount: rows.map(\.peakActiveCount).max() ?? 0,
            maximumPeakActiveBytes: maxPeakBytes,
            passedResourceBounds: resourcePass
        )
    }

    private static func runOnce(
        _ workload: BypassServiceWorkload,
        indexed: Bool,
        repetition: Int
    ) async throws -> BypassServiceRepetition {
        let h = BypassServiceHarness(indexed: indexed)
        let prefix = "\(workload.id)-\(indexed ? "i" : "f")-\(repetition)"
        var tasks: [Task<String, Never>] = []
        for index in workload.activeBytes.indices {
            let label = "\(prefix)-a\(index)"
            tasks.append(
                h.submit(
                    bytes: workload.activeBytes[index],
                    label: label,
                    delay: workload.activeMicros[index]
                )
            )
            try await waitStarted(label, h, "active-\(workload.id)-\(index)")
        }

        let headLabel = "\(prefix)-head"
        let headTask = h.submit(bytes: workload.headBytes, label: headLabel, delay: workload.headMicros)
        tasks.append(headTask)
        if workload.headInitiallyFits {
            try await waitStarted(headLabel, h, "head-start-\(workload.id)")
        } else {
            try await waitPendingAtLeast(1, h, "head-pending-\(workload.id)")
        }

        var laterLabels: [String] = []
        for index in workload.laterBytes.indices {
            let label = "\(prefix)-s\(index)"
            laterLabels.append(label)
            let pendingBefore = h.scheduler.resourceSnapshot().pendingCount
            tasks.append(
                h.submit(
                    bytes: workload.laterBytes[index],
                    label: label,
                    delay: workload.laterMicros
                )
            )
            try await waitAccepted(
                label,
                pendingTarget: pendingBefore + 1,
                harness: h,
                context: "later-\(workload.id)-\(index)"
            )
        }

        try await waitStarted(headLabel, h, "head-observed-\(workload.id)")
        let schedulerBypassesAtHeadStart = h.scheduler.resourceSnapshot().successfulBypasses
        for task in tasks {
            guard await task.value == "ok" else {
                throw BypassServiceProbeError.invariant("task-result-\(workload.id)")
            }
        }
        guard let head = h.state.timing(headLabel), head.start >= head.enqueue else {
            throw BypassServiceProbeError.invariant("head-timing-\(workload.id)")
        }
        var startWaits: [UInt64] = []
        var totalWaits: [UInt64] = []
        var laterBeforeHead = 0
        for label in laterLabels {
            guard let sample = h.state.timing(label),
                sample.start >= sample.enqueue,
                sample.finish >= sample.enqueue
            else { throw BypassServiceProbeError.invariant("later-timing-\(workload.id)") }
            startWaits.append(sample.start - sample.enqueue)
            totalWaits.append(sample.finish - sample.enqueue)
            if sample.start < head.start { laterBeforeHead += 1 }
        }
        let peaks = h.state.peaks()
        return BypassServiceRepetition(
            headWait: head.start - head.enqueue,
            smallStartWaits: startWaits,
            smallTotalWaits: totalWaits,
            laterIOStartsBeforeHead: laterBeforeHead,
            schedulerBypassesAtHeadStart: schedulerBypassesAtHeadStart,
            peakActiveCount: peaks.count,
            peakActiveBytes: peaks.bytes
        )
    }

    private static func makeWorkloads() -> [BypassServiceWorkload] {
        let stream = Array(repeating: 1, count: 12)
        return [
            .init(id: "head32-burst3-fast-small-slow-head", activeBytes: [16, 16, 16], activeMicros: [100_000, 250_000, 250_000], headBytes: 32, headMicros: 120_000, laterBytes: [1, 1, 1], laterMicros: 5_000, headInitiallyFits: false),
            .init(id: "head32-stream12-fast-small-slow-head", activeBytes: [16, 16, 16], activeMicros: [100_000, 250_000, 250_000], headBytes: 32, headMicros: 120_000, laterBytes: stream, laterMicros: 5_000, headInitiallyFits: false),
            .init(id: "head32-stream12-slow-small-fast-head", activeBytes: [16, 16, 16], activeMicros: [100_000, 250_000, 250_000], headBytes: 32, headMicros: 10_000, laterBytes: stream, laterMicros: 180_000, headInitiallyFits: false),
            .init(id: "head64-stream12-fast-small-slow-head", activeBytes: [1, 1, 1], activeMicros: [100_000, 150_000, 200_000], headBytes: 64, headMicros: 120_000, laterBytes: stream, laterMicros: 5_000, headInitiallyFits: false),
            .init(id: "head64-stream12-slow-small-fast-head", activeBytes: [1, 1, 1], activeMicros: [100_000, 150_000, 200_000], headBytes: 64, headMicros: 10_000, laterBytes: stream, laterMicros: 300_000, headInitiallyFits: false),
            .init(id: "oversize128-stream12-fast-small-slow-head", activeBytes: [1, 1, 1], activeMicros: [100_000, 150_000, 200_000], headBytes: 128, headMicros: 120_000, laterBytes: stream, laterMicros: 5_000, headInitiallyFits: false),
            .init(id: "oversize128-stream12-slow-small-fast-head", activeBytes: [1, 1, 1], activeMicros: [100_000, 150_000, 200_000], headBytes: 128, headMicros: 10_000, laterBytes: stream, laterMicros: 300_000, headInitiallyFits: false),
            .init(id: "equal16-control", activeBytes: [16, 16, 16], activeMicros: [250_000, 250_000, 250_000], headBytes: 16, headMicros: 30_000, laterBytes: Array(repeating: 16, count: 6), laterMicros: 10_000, headInitiallyFits: true),
            .init(id: "mixed-fast", activeBytes: [8, 24, 16], activeMicros: [100_000, 200_000, 250_000], headBytes: 24, headMicros: 80_000, laterBytes: [8, 32, 4, 16, 1, 24], laterMicros: 5_000, headInitiallyFits: false),
        ]
    }

    private static func percentile(_ values: [UInt64], _ percent: Int) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let numerator = (sorted.count - 1) * percent
        let index = (numerator + 99) / 100
        return sorted[min(index, sorted.count - 1)]
    }

    private static func waitStarted(
        _ label: String,
        _ h: BypassServiceHarness,
        _ context: String
    ) async throws {
        for _ in 0..<20_000 {
            if h.state.hasStarted(label) { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000)
        }
        throw BypassServiceProbeError.timeout(context)
    }

    private static func waitPendingAtLeast(
        _ count: Int,
        _ h: BypassServiceHarness,
        _ context: String
    ) async throws {
        for _ in 0..<20_000 {
            if h.scheduler.resourceSnapshot().pendingCount >= count { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000)
        }
        throw BypassServiceProbeError.timeout(context)
    }

    private static func waitAccepted(
        _ label: String,
        pendingTarget: Int,
        harness h: BypassServiceHarness,
        context: String
    ) async throws {
        for _ in 0..<20_000 {
            if h.state.hasStarted(label)
                || h.scheduler.resourceSnapshot().pendingCount >= pendingTarget
            { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 100_000)
        }
        throw BypassServiceProbeError.timeout(context)
    }
}
