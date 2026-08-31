import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum BoundedBypassActualError: Error {
    case timeout(String)
    case invariant(String)
}

private final class BoundedBypassActualState: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String] = []
    private var gates: [String: DispatchSemaphore] = [:]

    func register(_ label: String, gate: DispatchSemaphore) {
        lock.lock()
        gates[label] = gate
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func read(url: URL, maximumBytes: Int, expectedBytes: Int?) throws -> BoundedFileReadResult {
        let label = url.lastPathComponent
        lock.lock()
        let gate = gates[label]
        starts.append(label)
        lock.unlock()
        guard let gate else { throw BoundedBypassActualError.invariant("unregistered-\(label)") }
        gate.wait()
        let count = expectedBytes ?? maximumBytes
        return BoundedFileReadResult(
            data: Data(repeating: 0x5a, count: count),
            modificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct BoundedBypassHarness: Sendable {
    let scheduler: FileBlobStoreReadIO
    let state: BoundedBypassActualState

    init(
        bypasses: Int,
        pendingLimit: Int = 32,
        lookupMode: FileBlobStoreReadBypassLookupMode = .linear
    ) {
        let state = BoundedBypassActualState()
        self.state = state
        scheduler = FileBlobStoreReadIO(
            maximumConcurrentReads: 4,
            maximumInFlightBytes: 64,
            maximumPendingReads: pendingLimit,
            maximumBypassesPerBlockedHead: bypasses,
            bypassLookupMode: lookupMode,
            operations: FileBlobStoreReadOperations(read: { url, maximumBytes, expectedBytes in
                try state.read(url: url, maximumBytes: maximumBytes, expectedBytes: expectedBytes)
            })
        )
    }

    func submit(bytes: Int, label: String, gate: DispatchSemaphore) -> Task<String, Never> {
        state.register(label, gate: gate)
        let data = Data(repeating: 0x5a, count: bytes)
        let digest = BlobDigest.sha256(of: data)
        let url = URL(fileURLWithPath: "/akashic-bypass-actual/\(label)")
        return Task {
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

private struct BoundedBypassActualCase: Codable {
    let name: String
    let relevantStarts: [String]
    let passed: Bool
}

private struct BoundedBypassActualReport: Codable {
    struct Claims: Codable {
        let productionDefaultChanged: Bool
        let formalLatency: Bool
        let filesystemIO: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let maximumWorkers: Int
    let maximumInFlightBytes: Int
    let candidateBypasses: Int
    let cases: [BoundedBypassActualCase]
    let allCasesPass: Bool
    let claims: Claims
}

enum ReadSchedulerBoundedBypassActualProbe {
    static func run() async throws {
        let cases = [
            try await strictDefaultControl(),
            try await freeWorkerBypass(),
            try await continuousSmallBound(),
            try await fittingHeadControl(),
            try await cancelledBlockedHeadResetsCredit(),
            try await oversizeHeadBound(),
        ]
        let all = cases.allSatisfy(\.passed)
        let report = BoundedBypassActualReport(
            schemaVersion: 1,
            maximumWorkers: 4,
            maximumInFlightBytes: 64,
            candidateBypasses: 3,
            cases: cases,
            allCasesPass: all,
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
        guard all else { throw BoundedBypassActualError.invariant("case-failure") }
    }

    private static func strictDefaultControl() async throws -> BoundedBypassActualCase {
        let harness = BoundedBypassHarness(bypasses: 0)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { harness.submit(bytes: 16, label: "d-a\($0)", gate: activeGate) }
        try await waitStarts(3, harness: harness, context: "default-active")
        let head = harness.submit(bytes: 32, label: "d-head", gate: headGate)
        try await waitPendingAtLeast(1, harness: harness, context: "default-head-pending")
        let small = harness.submit(bytes: 1, label: "d-small", gate: smallGate)
        try await waitPendingAtLeast(2, harness: harness, context: "default-small-pending")
        try await settle()
        let before = harness.state.snapshot()
        activeGate.signal()
        try await waitStarts(4, harness: harness, context: "default-head")
        let afterOne = harness.state.snapshot()
        activeGate.signal()
        try await waitStarts(5, harness: harness, context: "default-small")
        let final = harness.state.snapshot()
        headGate.signal()
        smallGate.signal()
        activeGate.signal()
        await finish(active + [head, small])
        let relevant = Array(final.dropFirst(3))
        return .init(
            name: "default-zero-strict-fifo",
            relevantStarts: relevant,
            passed: before.count == 3
                && afterOne.last == "d-head"
                && relevant == ["d-head", "d-small"]
        )
    }

    private static func freeWorkerBypass() async throws -> BoundedBypassActualCase {
        let harness = BoundedBypassHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { harness.submit(bytes: 16, label: "b-a\($0)", gate: activeGate) }
        try await waitStarts(3, harness: harness, context: "bypass-active")
        let head = harness.submit(bytes: 32, label: "b-head", gate: headGate)
        try await waitPendingAtLeast(1, harness: harness, context: "bypass-head-pending")
        let small = harness.submit(bytes: 1, label: "b-small", gate: smallGate)
        try await waitUntilContains("b-small", harness: harness, context: "bypass-small")
        let beforeRelease = harness.state.snapshot()
        smallGate.signal()
        try await settle()
        activeGate.signal()
        try await waitStarts(5, harness: harness, context: "bypass-head")
        let final = harness.state.snapshot()
        headGate.signal()
        activeGate.signal()
        activeGate.signal()
        await finish(active + [head, small])
        let relevant = Array(final.dropFirst(3))
        return .init(
            name: "free-worker-byte-bypass",
            relevantStarts: relevant,
            passed: beforeRelease.last == "b-small"
                && relevant == ["b-small", "b-head"]
        )
    }

    private static func continuousSmallBound() async throws -> BoundedBypassActualCase {
        let harness = BoundedBypassHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<6).map { _ in DispatchSemaphore(value: 0) }
        let active = (0..<3).map { harness.submit(bytes: 1, label: "c-a\($0)", gate: activeGate) }
        try await waitStarts(3, harness: harness, context: "continuous-active")
        let head = harness.submit(bytes: 64, label: "c-head", gate: headGate)
        try await waitPendingAtLeast(1, harness: harness, context: "continuous-head-pending")
        var smalls: [Task<String, Never>] = []
        let small0 = harness.submit(bytes: 1, label: "c-s0", gate: smallGates[0])
        smalls.append(small0)
        try await waitUntilContains("c-s0", harness: harness, context: "continuous-s0")
        let small1 = harness.submit(bytes: 1, label: "c-s1", gate: smallGates[1])
        smalls.append(small1)
        try await waitPendingAtLeast(2, harness: harness, context: "continuous-s1-pending")
        smallGates[0].signal()
        try await waitUntilContains("c-s1", harness: harness, context: "continuous-s1")
        let small2 = harness.submit(bytes: 1, label: "c-s2", gate: smallGates[2])
        smalls.append(small2)
        try await waitPendingAtLeast(2, harness: harness, context: "continuous-s2-pending")
        smallGates[1].signal()
        try await waitUntilContains("c-s2", harness: harness, context: "continuous-s2")
        for index in 3..<6 {
            smalls.append(harness.submit(bytes: 1, label: "c-s\(index)", gate: smallGates[index]))
            try await waitPendingAtLeast(index - 1, harness: harness, context: "continuous-s\(index)-pending")
        }
        smallGates[2].signal()
        try await settle()
        let afterCredits = harness.state.snapshot()
        activeGate.signal()
        activeGate.signal()
        try await settle()
        let beforeLastActive = harness.state.snapshot()
        activeGate.signal()
        try await waitUntilContains("c-head", harness: harness, context: "continuous-head")
        let headStarted = harness.state.snapshot()
        headGate.signal()
        for gate in smallGates.dropFirst(3) { gate.signal() }
        await finish(active + [head] + smalls)
        let relevant = Array(headStarted.dropFirst(3))
        return .init(
            name: "continuous-small-three-overtake-bound",
            relevantStarts: relevant,
            passed: afterCredits.count == 6
                && Array(afterCredits.suffix(3)) == ["c-s0", "c-s1", "c-s2"]
                && beforeLastActive.count == 6
                && relevant == ["c-s0", "c-s1", "c-s2", "c-head"]
        )
    }

    private static func fittingHeadControl() async throws -> BoundedBypassActualCase {
        let harness = BoundedBypassHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { harness.submit(bytes: 16, label: "f-a\($0)", gate: activeGate) }
        try await waitStarts(3, harness: harness, context: "fitting-active")
        let head = harness.submit(bytes: 16, label: "f-head", gate: headGate)
        try await waitStarts(4, harness: harness, context: "fitting-head")
        let small = harness.submit(bytes: 1, label: "f-small", gate: smallGate)
        try await settle()
        let before = harness.state.snapshot()
        headGate.signal()
        try await waitStarts(5, harness: harness, context: "fitting-small")
        smallGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(active + [head, small])
        let relevant = Array(before.dropFirst(3))
        return .init(
            name: "fitting-head-never-bypassed",
            relevantStarts: relevant,
            passed: before.count == 4 && relevant == ["f-head"]
        )
    }

    private static func cancelledBlockedHeadResetsCredit() async throws -> BoundedBypassActualCase {
        let harness = BoundedBypassHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
        let active = (0..<3).map { harness.submit(bytes: 1, label: "x-a\($0)", gate: activeGate) }
        try await waitStarts(3, harness: harness, context: "cancel-active")
        let head = harness.submit(bytes: 64, label: "x-head", gate: headGate)
        try await waitPendingAtLeast(1, harness: harness, context: "cancel-head-pending")
        var smalls: [Task<String, Never>] = []
        let small0 = harness.submit(bytes: 1, label: "x-s0", gate: smallGates[0])
        smalls.append(small0)
        try await waitUntilContains("x-s0", harness: harness, context: "cancel-s0")
        let small1 = harness.submit(bytes: 1, label: "x-s1", gate: smallGates[1])
        smalls.append(small1)
        try await waitPendingAtLeast(2, harness: harness, context: "cancel-s1-pending")
        smallGates[0].signal()
        try await waitUntilContains("x-s1", harness: harness, context: "cancel-s1")
        let small2 = harness.submit(bytes: 1, label: "x-s2", gate: smallGates[2])
        smalls.append(small2)
        try await waitPendingAtLeast(2, harness: harness, context: "cancel-s2-pending")
        smallGates[1].signal()
        try await waitUntilContains("x-s2", harness: harness, context: "cancel-s2")
        let small3 = harness.submit(bytes: 1, label: "x-s3", gate: smallGates[3])
        smalls.append(small3)
        try await waitPendingAtLeast(2, harness: harness, context: "cancel-s3-pending")
        smallGates[2].signal()
        try await settle()
        let beforeCancel = harness.state.snapshot()
        head.cancel()
        try await waitUntilContains("x-s3", harness: harness, context: "cancel-reset")
        let afterCancel = harness.state.snapshot()
        smallGates[3].signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(active + [head] + smalls)
        headGate.signal()
        return .init(
            name: "cancelled-head-resets-credit",
            relevantStarts: Array(afterCancel.dropFirst(3)),
            passed: beforeCancel.count == 6
                && !beforeCancel.contains("x-s3")
                && afterCancel.contains("x-s3")
        )
    }

    private static func oversizeHeadBound() async throws -> BoundedBypassActualCase {
        let harness = BoundedBypassHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
        let active = (0..<3).map { harness.submit(bytes: 1, label: "o-a\($0)", gate: activeGate) }
        try await waitStarts(3, harness: harness, context: "oversize-active")
        let head = harness.submit(bytes: 128, label: "o-head", gate: headGate)
        try await waitPendingAtLeast(1, harness: harness, context: "oversize-head-pending")
        var smalls: [Task<String, Never>] = []
        let small0 = harness.submit(bytes: 1, label: "o-s0", gate: smallGates[0])
        smalls.append(small0)
        try await waitUntilContains("o-s0", harness: harness, context: "oversize-s0")
        let small1 = harness.submit(bytes: 1, label: "o-s1", gate: smallGates[1])
        smalls.append(small1)
        try await waitPendingAtLeast(2, harness: harness, context: "oversize-s1-pending")
        smallGates[0].signal()
        try await waitUntilContains("o-s1", harness: harness, context: "oversize-s1")
        let small2 = harness.submit(bytes: 1, label: "o-s2", gate: smallGates[2])
        smalls.append(small2)
        try await waitPendingAtLeast(2, harness: harness, context: "oversize-s2-pending")
        smallGates[1].signal()
        try await waitUntilContains("o-s2", harness: harness, context: "oversize-s2")
        let small3 = harness.submit(bytes: 1, label: "o-s3", gate: smallGates[3])
        smalls.append(small3)
        try await waitPendingAtLeast(2, harness: harness, context: "oversize-s3-pending")
        smallGates[2].signal()
        try await settle()
        let afterCredits = harness.state.snapshot()
        activeGate.signal(); activeGate.signal()
        try await settle()
        let beforeExclusive = harness.state.snapshot()
        activeGate.signal()
        try await waitUntilContains("o-head", harness: harness, context: "oversize-head")
        let afterHead = harness.state.snapshot()
        headGate.signal()
        smallGates[3].signal()
        await finish(active + [head] + smalls)
        return .init(
            name: "oversize-head-exclusive-after-three-bypasses",
            relevantStarts: Array(afterHead.dropFirst(3)),
            passed: afterCredits.count == 6
                && !afterCredits.contains("o-s3")
                && beforeExclusive.count == 6
                && afterHead.last == "o-head"
        )
    }

    private static func waitPendingAtLeast(
        _ count: Int,
        harness: BoundedBypassHarness,
        context: String
    ) async throws {
        for _ in 0..<500 {
            if harness.scheduler.resourceSnapshot().pendingCount >= count { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw BoundedBypassActualError.timeout(context)
    }

    private static func waitStarts(
        _ count: Int,
        harness: BoundedBypassHarness,
        context: String
    ) async throws {
        for _ in 0..<500 {
            if harness.state.snapshot().count >= count { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw BoundedBypassActualError.timeout(context)
    }

    private static func waitUntilContains(
        _ label: String,
        harness: BoundedBypassHarness,
        context: String
    ) async throws {
        for _ in 0..<500 {
            if harness.state.snapshot().contains(label) { return }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw BoundedBypassActualError.timeout(context)
    }

    private static func settle() async throws {
        for _ in 0..<10 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func finish(_ tasks: [Task<String, Never>]) async {
        for task in tasks { _ = await task.value }
    }
}
