import AkashicDisk
import Dispatch
import Foundation

enum BypassSizeIndexProbeError: Error {
    case timeout(String)
    case invariant(String)
}

struct BypassSizeIndexCaseResult: Codable {
    let name: String
    let pendingDepth: Int
    let indexSearches: Int
    let classesExamined: Int
    let maximumClassesExaminedPerSearch: Int
    let staleTokensDiscarded: Int
    let successfulBypasses: Int
    let secondaryTokenSlots: Int
    let secondaryTokenBound: Int
    let relevantStarts: [String]
    let passed: Bool
}

private struct BypassSizeIndexReport: Codable {
    struct Claims: Codable {
        let productionDefaultChanged: Bool
        let formalLockLatency: Bool
        let filesystemIO: Bool
        let physicalDevice: Bool
    }

    let schemaVersion: Int
    let classCount: Int
    let expectedEligibleClassesAt16Bytes: Int
    let maximumPendingReads: Int
    let cases: [BypassSizeIndexCaseResult]
    let allCasesPass: Bool
    let worstObservedClassesPerSearch: Int
    let claims: Claims
}

enum ReadSchedulerBoundedBypassSizeIndexProbe {
    static let expectedClassesAt16Bytes = 5

    static func run() async throws {
        var cases: [BypassSizeIndexCaseResult] = [
            try await immediateGuaranteedFit(),
            try await continuousThreeOvertakeBound(),
            try await conservativeBoundaryMiss(),
            try await cancelledHeadResetsCredit(),
            try await oversizeHeadBound(),
            try await staleFrontSingleStepBound(),
            try await strictFIFOControl(),
        ]
        for depth in [16, 128, 512, 1_024] {
            let later = depth - 1
            for position in [0, later / 4, later / 2, later - 1] {
                cases.append(try await indexedSearchCase(depth: depth, fitPosition: position))
            }
            cases.append(try await indexedSearchCase(depth: depth, fitPosition: nil))
        }

        let all = cases.allSatisfy(\.passed)
        let report = BypassSizeIndexReport(
            schemaVersion: 1,
            classCount: Int.bitWidth,
            expectedEligibleClassesAt16Bytes: expectedClassesAt16Bytes,
            maximumPendingReads: 1_024,
            cases: cases,
            allCasesPass: all,
            worstObservedClassesPerSearch: cases.map(\.maximumClassesExaminedPerSearch).max() ?? 0,
            claims: .init(
                productionDefaultChanged: false,
                formalLockLatency: false,
                filesystemIO: false,
                physicalDevice: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw BypassSizeIndexProbeError.invariant("case-failure") }
    }

    static func harness(pendingLimit: Int = 1_024) -> BypassScanHarness {
        BypassScanHarness(
            bypasses: 3,
            pendingLimit: pendingLimit,
            lookupMode: .conservativeSizeIndex
        )
    }

    static func indexedSearchCase(
        depth: Int,
        fitPosition: Int?
    ) async throws -> BypassSizeIndexCaseResult {
        let h = harness()
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks = (0..<4).map { h.submit(bytes: 16, label: "m-a\($0)", gate: activeGate) }
        try await waitStarts(4, h, "m-active-\(depth)")
        let head = h.submit(bytes: 32, label: "m-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "m-head-\(depth)")
        let laterCount = depth - 1
        var gates: [DispatchSemaphore] = []
        for index in 0..<laterCount {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            let bytes = fitPosition == index ? 1 : 32
            tasks.append(h.submit(bytes: bytes, label: "m-p\(index)", gate: gate))
            try await waitPending(index + 2, h, "m-pending-\(depth)-\(index)")
        }
        let before = h.scheduler.resourceSnapshot()
        activeGate.signal()
        try await waitIndexSearches(before.bypassIndexSearches + 1, h, "m-search-\(depth)")
        let after = h.scheduler.resourceSnapshot()
        let successExpected = fitPosition == nil ? 0 : 1
        let result = makeResult(
            name: fitPosition.map { "depth-\(depth)-fit-at-\($0)" } ?? "depth-\(depth)-no-fit",
            pendingDepth: depth,
            before: before,
            after: after,
            relevantStarts: Array(h.state.snapshotStarts().dropFirst(4)),
            passed: after.bypassIndexSearches - before.bypassIndexSearches == 1
                && after.bypassIndexClassesExamined - before.bypassIndexClassesExamined
                    == expectedClassesAt16Bytes
                && after.bypassIndexStaleTokensDiscarded == before.bypassIndexStaleTokensDiscarded
                && after.successfulBypasses - before.successfulBypasses == successExpected
                && after.pendingBypassIndexTokenSlots <= after.maximumPendingBypassIndexTokenSlots
        )
        for task in tasks.dropFirst(4) { task.cancel() }
        for gate in gates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return result
    }

    static func makeResult(
        name: String,
        pendingDepth: Int,
        before: FileBlobStoreReadSchedulerResourceSnapshot,
        after: FileBlobStoreReadSchedulerResourceSnapshot,
        relevantStarts: [String],
        passed: Bool
    ) -> BypassSizeIndexCaseResult {
        BypassSizeIndexCaseResult(
            name: name,
            pendingDepth: pendingDepth,
            indexSearches: after.bypassIndexSearches - before.bypassIndexSearches,
            classesExamined: after.bypassIndexClassesExamined - before.bypassIndexClassesExamined,
            maximumClassesExaminedPerSearch: after.maximumBypassIndexClassesPerSearch,
            staleTokensDiscarded: after.bypassIndexStaleTokensDiscarded
                - before.bypassIndexStaleTokensDiscarded,
            successfulBypasses: after.successfulBypasses - before.successfulBypasses,
            secondaryTokenSlots: after.pendingBypassIndexTokenSlots,
            secondaryTokenBound: after.maximumPendingBypassIndexTokenSlots,
            relevantStarts: relevantStarts,
            passed: passed
        )
    }

    static func waitStarts(_ count: Int, _ h: BypassScanHarness, _ context: String) async throws {
        for _ in 0..<4_000 {
            if h.state.snapshotStarts().count >= count { return }
            await Task.yield()
        }
        throw BypassSizeIndexProbeError.timeout(context)
    }

    static func waitStarted(_ label: String, _ h: BypassScanHarness, _ context: String) async throws {
        for _ in 0..<4_000 {
            if h.state.snapshotStarts().contains(label) { return }
            await Task.yield()
        }
        throw BypassSizeIndexProbeError.timeout(context)
    }

    static func waitPending(_ count: Int, _ h: BypassScanHarness, _ context: String) async throws {
        for _ in 0..<4_000 {
            if h.scheduler.resourceSnapshot().pendingCount == count { return }
            await Task.yield()
        }
        throw BypassSizeIndexProbeError.timeout(context)
    }

    static func waitPendingAtLeast(
        _ count: Int, _ h: BypassScanHarness, _ context: String
    ) async throws {
        for _ in 0..<4_000 {
            if h.scheduler.resourceSnapshot().pendingCount >= count { return }
            await Task.yield()
        }
        throw BypassSizeIndexProbeError.timeout(context)
    }

    static func waitActiveCount(
        _ count: Int, _ h: BypassScanHarness, _ context: String
    ) async throws {
        for _ in 0..<4_000 {
            if h.scheduler.resourceSnapshot().activeCount == count { return }
            await Task.yield()
        }
        throw BypassSizeIndexProbeError.timeout(context)
    }

    static func waitIndexSearches(
        _ count: Int, _ h: BypassScanHarness, _ context: String
    ) async throws {
        for _ in 0..<4_000 {
            if h.scheduler.resourceSnapshot().bypassIndexSearches >= count { return }
            await Task.yield()
        }
        throw BypassSizeIndexProbeError.timeout(context)
    }

    static func settle() async throws {
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 250_000)
        }
    }

    static func finish(_ tasks: [Task<String, Never>]) async {
        for task in tasks { _ = await task.value }
    }
}
