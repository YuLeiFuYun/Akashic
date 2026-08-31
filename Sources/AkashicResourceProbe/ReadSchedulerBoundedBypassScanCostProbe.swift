import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

private enum BypassScanProbeError: Error {
    case timeout(String)
    case invariant(String)
}

final class BypassScanState: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: DispatchSemaphore] = [:]
    private var starts: [String] = []

    func register(_ label: String, gate: DispatchSemaphore) {
        lock.lock()
        gates[label] = gate
        lock.unlock()
    }

    func snapshotStarts() -> [String] {
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
        guard let gate else { throw BypassScanProbeError.invariant("missing-gate-\(label)") }
        gate.wait()
        let count = expectedBytes ?? maximumBytes
        return BoundedFileReadResult(
            data: Data(repeating: 0x51, count: count),
            modificationDate: Date(timeIntervalSince1970: 0)
        )
    }
}

struct BypassScanHarness: Sendable {
    let scheduler: FileBlobStoreReadIO
    let state: BypassScanState

    init(
        bypasses: Int,
        pendingLimit: Int = 1_024,
        lookupMode: FileBlobStoreReadBypassLookupMode = .linear
    ) {
        let state = BypassScanState()
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
        let data = Data(repeating: 0x51, count: bytes)
        let digest = BlobDigest.sha256(of: data)
        let url = URL(fileURLWithPath: "/akashic-bypass-scan/\(label)")
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

private struct BypassScanCaseResult: Codable {
    let name: String
    let pendingDepth: Int
    let expectedExamined: Int
    let bypassSearches: Int
    let bypassSlotsExamined: Int
    let maximumSlotsExaminedPerSearch: Int
    let successfulBypasses: Int
    let failedBypassSearches: Int
    let passed: Bool
}

private struct BypassScanReport: Codable {
    struct Claims: Codable {
        let productionDefaultChanged: Bool
        let formalLockLatency: Bool
        let filesystemIO: Bool
    }

    let schemaVersion: Int
    let cases: [BypassScanCaseResult]
    let allCasesPass: Bool
    let maximumPendingReads: Int
    let worstObservedSlotsPerSearch: Int
    let claims: Claims
}

enum ReadSchedulerBoundedBypassScanCostProbe {
    static func run() async throws {
        var cases: [BypassScanCaseResult] = []
        for depth in [16, 128, 512, 1_024] {
            let later = depth - 1
            cases.append(try await singleSearchCase(depth: depth, fitPosition: 0))
            cases.append(try await singleSearchCase(depth: depth, fitPosition: later / 4))
            cases.append(try await singleSearchCase(depth: depth, fitPosition: later / 2))
            cases.append(try await singleSearchCase(depth: depth, fitPosition: later - 1))
            cases.append(try await singleSearchCase(depth: depth, fitPosition: nil))
        }
        cases.append(try await cancellationTombstoneCase())
        cases.append(try await exhaustedCreditCase())
        cases.append(try await strictFIFOControl())

        let all = cases.allSatisfy(\.passed)
        let report = BypassScanReport(
            schemaVersion: 1,
            cases: cases,
            allCasesPass: all,
            maximumPendingReads: 1_024,
            worstObservedSlotsPerSearch: cases.map(\.maximumSlotsExaminedPerSearch).max() ?? 0,
            claims: .init(
                productionDefaultChanged: false,
                formalLockLatency: false,
                filesystemIO: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw BypassScanProbeError.invariant("case-failure") }
    }

    private static func singleSearchCase(
        depth: Int,
        fitPosition: Int?
    ) async throws -> BypassScanCaseResult {
        let harness = BypassScanHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks: [Task<String, Never>] = []
        for index in 0..<4 {
            tasks.append(harness.submit(bytes: 16, label: "a\(index)", gate: activeGate))
        }
        try await waitStarts(4, harness: harness, context: "active-\(depth)")

        let head = harness.submit(bytes: 32, label: "head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, harness: harness, context: "head-pending-\(depth)")

        let laterCount = depth - 1
        var laterGates: [DispatchSemaphore] = []
        for index in 0..<laterCount {
            let gate = DispatchSemaphore(value: 0)
            laterGates.append(gate)
            let bytes = fitPosition == index ? 1 : 32
            tasks.append(harness.submit(bytes: bytes, label: "p\(index)", gate: gate))
            try await waitPending(index + 2, harness: harness, context: "pending-\(depth)-\(index)")
        }

        let before = harness.scheduler.resourceSnapshot()
        activeGate.signal()
        try await waitSearches(before.bypassSearches + 1, harness: harness, context: "search-\(depth)")
        let after = harness.scheduler.resourceSnapshot()
        let expected = fitPosition.map { $0 + 1 } ?? laterCount
        let searchDelta = after.bypassSearches - before.bypassSearches
        let examinedDelta = after.bypassSlotsExamined - before.bypassSlotsExamined
        let successfulDelta = after.successfulBypasses - before.successfulBypasses
        let failedDelta = after.failedBypassSearches - before.failedBypassSearches
        let passed = searchDelta == 1
            && examinedDelta == expected
            && after.maximumSlotsExaminedPerSearch >= expected
            && successfulDelta == (fitPosition == nil ? 0 : 1)
            && failedDelta == (fitPosition == nil ? 1 : 0)

        for task in tasks.dropFirst(4) { task.cancel() }
        for gate in laterGates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)

        return BypassScanCaseResult(
            name: fitPosition.map { "fit-at-\($0)" } ?? "no-fit",
            pendingDepth: depth,
            expectedExamined: expected,
            bypassSearches: searchDelta,
            bypassSlotsExamined: examinedDelta,
            maximumSlotsExaminedPerSearch: after.maximumSlotsExaminedPerSearch,
            successfulBypasses: successfulDelta,
            failedBypassSearches: failedDelta,
            passed: passed
        )
    }

    private static func cancellationTombstoneCase() async throws -> BypassScanCaseResult {
        let depth = 128
        let harness = BypassScanHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks: [Task<String, Never>] = []
        for index in 0..<4 {
            tasks.append(harness.submit(bytes: 16, label: "t-a\(index)", gate: activeGate))
        }
        try await waitStarts(4, harness: harness, context: "t-active")
        let head = harness.submit(bytes: 32, label: "t-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, harness: harness, context: "t-head")

        var later: [Task<String, Never>] = []
        var gates: [DispatchSemaphore] = []
        for index in 0..<(depth - 1) {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            let task = harness.submit(
                bytes: index == depth - 2 ? 1 : 32,
                label: "t-p\(index)",
                gate: gate
            )
            later.append(task)
            tasks.append(task)
            try await waitPending(index + 2, harness: harness, context: "t-pending-\(index)")
        }
        for index in stride(from: 3, to: depth - 2, by: 4) { later[index].cancel() }
        try await waitPendingAtMost(depth - 2, harness: harness, context: "t-cancel")

        let before = harness.scheduler.resourceSnapshot()
        activeGate.signal()
        try await waitSearches(before.bypassSearches + 1, harness: harness, context: "t-search")
        let after = harness.scheduler.resourceSnapshot()
        let expected = depth - 1
        let passed = after.bypassSearches - before.bypassSearches == 1
            && after.bypassSlotsExamined - before.bypassSlotsExamined == expected
            && after.successfulBypasses - before.successfulBypasses == 1

        for task in tasks.dropFirst(4) { task.cancel() }
        for gate in gates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return BypassScanCaseResult(
            name: "cancellation-tombstones-tail-fit",
            pendingDepth: depth,
            expectedExamined: expected,
            bypassSearches: after.bypassSearches - before.bypassSearches,
            bypassSlotsExamined: after.bypassSlotsExamined - before.bypassSlotsExamined,
            maximumSlotsExaminedPerSearch: after.maximumSlotsExaminedPerSearch,
            successfulBypasses: after.successfulBypasses - before.successfulBypasses,
            failedBypassSearches: after.failedBypassSearches - before.failedBypassSearches,
            passed: passed
        )
    }

    private static func exhaustedCreditCase() async throws -> BypassScanCaseResult {
        let harness = BypassScanHarness(bypasses: 3)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks: [Task<String, Never>] = []
        for index in 0..<3 {
            tasks.append(harness.submit(bytes: 1, label: "e-a\(index)", gate: activeGate))
        }
        try await waitStarts(3, harness: harness, context: "e-active")
        let head = harness.submit(bytes: 64, label: "e-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, harness: harness, context: "e-head")

        var gates: [DispatchSemaphore] = []
        for index in 0..<3 {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            let task = harness.submit(bytes: 1, label: "e-s\(index)", gate: gate)
            tasks.append(task)
            try await waitUntilStarted("e-s\(index)", harness: harness, context: "e-start-\(index)")
            gate.signal()
        }
        try await waitSuccessfulBypasses(3, harness: harness, context: "e-credit")
        let before = harness.scheduler.resourceSnapshot()

        for index in 0..<128 {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            tasks.append(harness.submit(bytes: 1, label: "e-tail\(index)", gate: gate))
            try await waitPendingAtLeast(index + 2, harness: harness, context: "e-tail-\(index)")
        }
        try await settle()
        let after = harness.scheduler.resourceSnapshot()
        let passed = after.bypassSearches == before.bypassSearches
            && after.bypassSlotsExamined == before.bypassSlotsExamined
            && after.successfulBypasses == before.successfulBypasses

        for task in tasks.dropFirst(3) { task.cancel() }
        for gate in gates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return BypassScanCaseResult(
            name: "credit-zero-no-further-scans",
            pendingDepth: after.pendingCount,
            expectedExamined: 0,
            bypassSearches: after.bypassSearches - before.bypassSearches,
            bypassSlotsExamined: after.bypassSlotsExamined - before.bypassSlotsExamined,
            maximumSlotsExaminedPerSearch: after.maximumSlotsExaminedPerSearch,
            successfulBypasses: after.successfulBypasses - before.successfulBypasses,
            failedBypassSearches: after.failedBypassSearches - before.failedBypassSearches,
            passed: passed
        )
    }

    private static func strictFIFOControl() async throws -> BypassScanCaseResult {
        let harness = BypassScanHarness(bypasses: 0)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks: [Task<String, Never>] = []
        for index in 0..<4 {
            tasks.append(harness.submit(bytes: 16, label: "f-a\(index)", gate: activeGate))
        }
        try await waitStarts(4, harness: harness, context: "f-active")
        let head = harness.submit(bytes: 32, label: "f-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, harness: harness, context: "f-head")
        var gates: [DispatchSemaphore] = []
        for index in 0..<127 {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            tasks.append(harness.submit(bytes: 1, label: "f-p\(index)", gate: gate))
            try await waitPending(index + 2, harness: harness, context: "f-pending-\(index)")
        }
        activeGate.signal()
        try await settle()
        let snapshot = harness.scheduler.resourceSnapshot()
        let passed = snapshot.bypassSearches == 0
            && snapshot.bypassSlotsExamined == 0
            && snapshot.successfulBypasses == 0
            && snapshot.failedBypassSearches == 0

        for task in tasks.dropFirst(4) { task.cancel() }
        for gate in gates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return BypassScanCaseResult(
            name: "strict-fifo-zero-search-work",
            pendingDepth: 128,
            expectedExamined: 0,
            bypassSearches: snapshot.bypassSearches,
            bypassSlotsExamined: snapshot.bypassSlotsExamined,
            maximumSlotsExaminedPerSearch: snapshot.maximumSlotsExaminedPerSearch,
            successfulBypasses: snapshot.successfulBypasses,
            failedBypassSearches: snapshot.failedBypassSearches,
            passed: passed
        )
    }

    private static func waitStarts(
        _ count: Int,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.state.snapshotStarts().count >= count { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func waitUntilStarted(
        _ label: String,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.state.snapshotStarts().contains(label) { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func waitPending(
        _ count: Int,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.scheduler.resourceSnapshot().pendingCount == count { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func waitPendingAtLeast(
        _ count: Int,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.scheduler.resourceSnapshot().pendingCount >= count { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func waitPendingAtMost(
        _ count: Int,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.scheduler.resourceSnapshot().pendingCount <= count { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func waitSearches(
        _ count: Int,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.scheduler.resourceSnapshot().bypassSearches >= count { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func waitSuccessfulBypasses(
        _ count: Int,
        harness: BypassScanHarness,
        context: String
    ) async throws {
        for _ in 0..<2_000 {
            if harness.scheduler.resourceSnapshot().successfulBypasses >= count { return }
            await Task.yield()
        }
        throw BypassScanProbeError.timeout(context)
    }

    private static func settle() async throws {
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 250_000)
        }
    }

    private static func finish(_ tasks: [Task<String, Never>]) async {
        for task in tasks { _ = await task.value }
    }
}
