import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum ReadSchedulerHOLProbeError: Error {
    case timeout(String)
    case invariant(String)
}

private final class ReadSchedulerStartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ value: String) {
        lock.lock()
        events.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private struct ReadSchedulerHOLCase: Codable {
    let name: String
    let relevantStartOrder: [String]
    let strandedCapacityObserved: Bool
    let controlPassed: Bool
}

private struct ReadSchedulerHOLReport: Codable {
    struct Claims: Codable {
        let productionSchedulerChanged: Bool
        let formalLatency: Bool
        let filesystemIO: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let maximumWorkers: Int
    let maximumInFlightBytes: Int
    let cases: [ReadSchedulerHOLCase]
    let allCasesPass: Bool
    let claims: Claims
}

private final class ReadSchedulerOperationState: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: ReadSchedulerStartRecorder
    private var gates: [String: DispatchSemaphore] = [:]

    init(recorder: ReadSchedulerStartRecorder) {
        self.recorder = recorder
    }

    func register(label: String, gate: DispatchSemaphore) {
        lock.lock()
        gates[label] = gate
        lock.unlock()
    }

    func read(
        url: URL,
        maximumBytes: Int,
        expectedBytes: Int?
    ) throws -> BoundedFileReadResult {
        let label = url.lastPathComponent
        lock.lock()
        let gate = gates[label]
        lock.unlock()
        guard let gate else { throw ReadSchedulerHOLProbeError.invariant("unregistered-\(label)") }
        recorder.append(label)
        gate.wait()
        let byteCount = expectedBytes ?? maximumBytes
        let data = Data(repeating: 0x5a, count: byteCount)
        return BoundedFileReadResult(
            data: data,
            modificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct ReadSchedulerHarness: Sendable {
    let executor: FileBlobStoreReadIO
    let state: ReadSchedulerOperationState

    init(
        recorder: ReadSchedulerStartRecorder,
        maximumWorkers: Int,
        maximumInFlightBytes: Int,
        maximumPendingReads: Int
    ) {
        let state = ReadSchedulerOperationState(recorder: recorder)
        self.state = state
        executor = FileBlobStoreReadIO(
            maximumConcurrentReads: maximumWorkers,
            maximumInFlightBytes: maximumInFlightBytes,
            maximumPendingReads: maximumPendingReads,
            operations: FileBlobStoreReadOperations(read: { url, maximumBytes, expectedBytes in
                try state.read(
                    url: url,
                    maximumBytes: maximumBytes,
                    expectedBytes: expectedBytes
                )
            })
        )
    }

    func submit(
        bytes: Int,
        label: String,
        gate: DispatchSemaphore
    ) -> Task<Void, Never> {
        state.register(label: label, gate: gate)
        let data = Data(repeating: 0x5a, count: bytes)
        let digest = BlobDigest.sha256(of: data)
        let url = URL(fileURLWithPath: "/akashic-read-scheduler/\(label)")
        return Task {
            do {
                _ = try await executor.readVerified(
                    from: url,
                    maximumBytes: bytes,
                    expectedBytes: bytes,
                    digest: digest
                )
            } catch {
                // Cancellation is expected in the cancelled-head control. Other failures surface
                // indirectly because the required start-order invariants will not become true.
            }
        }
    }
}

enum ReadSchedulerHOLProbe {
    static func run() async throws {
        let cases = [
            try await freeWorkerByteHOL(),
            try await maxHeadCliff(),
            try await fittingHeadControl(),
            try await cancelledHeadUnblocks(),
        ]
        guard cases.allSatisfy({ $0.controlPassed }) else {
            throw ReadSchedulerHOLProbeError.invariant("case-failure")
        }
        let report = ReadSchedulerHOLReport(
            schemaVersion: 1,
            maximumWorkers: 4,
            maximumInFlightBytes: 64,
            cases: cases,
            allCasesPass: true,
            claims: .init(
                productionSchedulerChanged: false,
                formalLatency: false,
                filesystemIO: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func freeWorkerByteHOL() async throws -> ReadSchedulerHOLCase {
        let recorder = ReadSchedulerStartRecorder()
        let harness = ReadSchedulerHarness(
            recorder: recorder,
            maximumWorkers: 4,
            maximumInFlightBytes: 64,
            maximumPendingReads: 16
        )
        let mediumGate = DispatchSemaphore(value: 0)
        let largeGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let mediums = (0..<3).map { index in
            harness.submit(
                bytes: 16,
                label: "m\(index)",
                gate: mediumGate
            )
        }
        try await waitForStartCount(3, recorder: recorder, context: "free-worker-medium")
        let large = harness.submit(
            bytes: 32,
            label: "large",
            gate: largeGate
        )
        let small = harness.submit(
            bytes: 1,
            label: "small",
            gate: smallGate
        )
        try await allowPendingEnqueue()
        let beforeRelease = recorder.snapshot()

        mediumGate.signal()
        try await waitForStartCount(4, recorder: recorder, context: "free-worker-large")
        let afterFirstRelease = recorder.snapshot()
        mediumGate.signal()
        try await waitForStartCount(5, recorder: recorder, context: "free-worker-small")
        let finalStarts = recorder.snapshot()

        largeGate.signal()
        smallGate.signal()
        mediumGate.signal()
        await finish(mediums + [large, small])

        let relevant = Array(finalStarts.dropFirst(3))
        let passed = beforeRelease.count == 3
            && afterFirstRelease.count == 4
            && afterFirstRelease.last == "large"
            && relevant == ["large", "small"]
        return ReadSchedulerHOLCase(
            name: "free-worker-byte-HOL",
            relevantStartOrder: relevant,
            strandedCapacityObserved: beforeRelease.count == 3,
            controlPassed: passed
        )
    }

    private static func maxHeadCliff() async throws -> ReadSchedulerHOLCase {
        let recorder = ReadSchedulerStartRecorder()
        let harness = ReadSchedulerHarness(
            recorder: recorder,
            maximumWorkers: 4,
            maximumInFlightBytes: 64,
            maximumPendingReads: 16
        )
        let activeGate = DispatchSemaphore(value: 0)
        let maxGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { index in
            harness.submit(
                bytes: 1,
                label: "a\(index)",
                gate: activeGate
            )
        }
        try await waitForStartCount(3, recorder: recorder, context: "max-head-active")
        let maxHead = harness.submit(
            bytes: 64,
            label: "max",
            gate: maxGate
        )
        let small = harness.submit(
            bytes: 1,
            label: "small",
            gate: smallGate
        )
        try await allowPendingEnqueue()

        activeGate.signal()
        try await settle()
        let afterOne = recorder.snapshot()
        activeGate.signal()
        try await settle()
        let afterTwo = recorder.snapshot()
        activeGate.signal()
        try await waitForStartCount(4, recorder: recorder, context: "max-head-start")
        let afterThree = recorder.snapshot()
        maxGate.signal()
        try await waitForStartCount(5, recorder: recorder, context: "max-head-small")
        let finalStarts = recorder.snapshot()

        smallGate.signal()
        await finish(active + [maxHead, small])

        let relevant = Array(finalStarts.dropFirst(3))
        let passed = afterOne.count == 3
            && afterTwo.count == 3
            && afterThree.last == "max"
            && relevant == ["max", "small"]
        return ReadSchedulerHOLCase(
            name: "max-head-cliff",
            relevantStartOrder: relevant,
            strandedCapacityObserved: afterTwo.count == 3,
            controlPassed: passed
        )
    }

    private static func fittingHeadControl() async throws -> ReadSchedulerHOLCase {
        let recorder = ReadSchedulerStartRecorder()
        let harness = ReadSchedulerHarness(
            recorder: recorder,
            maximumWorkers: 4,
            maximumInFlightBytes: 64,
            maximumPendingReads: 16
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { index in
            harness.submit(
                bytes: 16,
                label: "a\(index)",
                gate: activeGate
            )
        }
        try await waitForStartCount(3, recorder: recorder, context: "fitting-active")
        let head = harness.submit(
            bytes: 16,
            label: "head",
            gate: headGate
        )
        try await waitForStartCount(4, recorder: recorder, context: "fitting-head")
        let small = harness.submit(
            bytes: 1,
            label: "small",
            gate: smallGate
        )
        try await allowPendingEnqueue()
        let beforeRelease = recorder.snapshot()
        activeGate.signal()
        try await waitForStartCount(5, recorder: recorder, context: "fitting-small")
        let finalStarts = recorder.snapshot()

        headGate.signal()
        smallGate.signal()
        activeGate.signal()
        activeGate.signal()
        await finish(active + [head, small])

        let relevant = Array(finalStarts.dropFirst(3))
        let passed = beforeRelease.count == 4
            && beforeRelease.last == "head"
            && relevant == ["head", "small"]
        return ReadSchedulerHOLCase(
            name: "fitting-head-control",
            relevantStartOrder: relevant,
            strandedCapacityObserved: false,
            controlPassed: passed
        )
    }

    private static func cancelledHeadUnblocks() async throws -> ReadSchedulerHOLCase {
        let recorder = ReadSchedulerStartRecorder()
        let harness = ReadSchedulerHarness(
            recorder: recorder,
            maximumWorkers: 4,
            maximumInFlightBytes: 64,
            maximumPendingReads: 16
        )
        let activeGate = DispatchSemaphore(value: 0)
        let largeGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { index in
            harness.submit(
                bytes: 16,
                label: "a\(index)",
                gate: activeGate
            )
        }
        try await waitForStartCount(3, recorder: recorder, context: "cancel-active")
        let large = harness.submit(
            bytes: 32,
            label: "large",
            gate: largeGate
        )
        let small = harness.submit(
            bytes: 1,
            label: "small",
            gate: smallGate
        )
        try await allowPendingEnqueue()
        large.cancel()
        try await waitForStartCount(4, recorder: recorder, context: "cancel-small")
        let starts = recorder.snapshot()

        smallGate.signal()
        activeGate.signal()
        activeGate.signal()
        activeGate.signal()
        largeGate.signal()
        await finish(active + [large, small])

        let relevant = Array(starts.dropFirst(3))
        let passed = relevant == ["small"] && !starts.contains("large")
        return ReadSchedulerHOLCase(
            name: "cancelled-head-unblocks",
            relevantStartOrder: relevant,
            strandedCapacityObserved: false,
            controlPassed: passed
        )
    }

    private static func finish(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { await task.value }
    }

    private static func waitForStartCount(
        _ expected: Int,
        recorder: ReadSchedulerStartRecorder,
        context: String
    ) async throws {
        for _ in 0..<500 {
            if recorder.snapshot().count >= expected { return }
            await pause(milliseconds: 1)
        }
        throw ReadSchedulerHOLProbeError.timeout(context)
    }

    private static func allowPendingEnqueue() async throws {
        for _ in 0..<20 { await Task.yield() }
        await pause(milliseconds: 5)
    }

    private static func settle() async throws {
        for _ in 0..<10 { await Task.yield() }
        await pause(milliseconds: 2)
    }

    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}
