import AkashicDisk
import Dispatch
import Foundation

private enum ExactBypassIndexProbeError: Error {
    case timeout(String)
    case invariant(String)
}

private struct ExactBypassSearchRow: Codable {
    let pendingDepth: Int
    let pendingStorageSlots: Int
    let fitPosition: Int?
    let successfulBypass: Bool
    let exactIndexSearches: Int
    let nodesExamined: Int
    let maximumNodesPerSearch: Int
    let scalarSlots: Int
    let maximumScalarSlots: Int
    let passed: Bool
}

private struct ExactBypassCancellationRow: Codable {
    let cancelledRequests: Int
    let pendingBefore: Int
    let pendingAfter: Int
    let exactSearchDelta: Int
    let pointUpdateDelta: Int
    let nodeWriteDelta: Int
    let scalarSlotsAfter: Int
    let passed: Bool
}

private struct ExactBypassCompactionRow: Codable {
    let pendingLimit: Int
    let storageBeforeCompactionTrigger: Int
    let scalarSlotsBeforeCompactionTrigger: Int
    let rebuildDelta: Int
    let rebuildNodeWriteDelta: Int
    let pendingAfterCompaction: Int
    let storageAfterCompaction: Int
    let scalarSlotsAfterCompaction: Int
    let passed: Bool
}

private struct ExactBypassIndexReport: Codable {
    let schemaVersion: Int
    let searchRows: [ExactBypassSearchRow]
    let cancellation: ExactBypassCancellationRow
    let compaction: ExactBypassCompactionRow
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum ReadSchedulerExactBypassIndexProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.isEmpty else { throw ExactBypassIndexProbeError.invariant("arguments") }
        var searchRows: [ExactBypassSearchRow] = []
        for depth in [16, 128, 512, 1_024] {
            let later = depth - 1
            searchRows.append(try await searchCase(depth: depth, fitPosition: 0))
            searchRows.append(try await searchCase(depth: depth, fitPosition: later / 2))
            searchRows.append(try await searchCase(depth: depth, fitPosition: later - 1))
            searchRows.append(try await searchCase(depth: depth, fitPosition: nil))
        }
        let cancellation = try await cancellationMaintenanceCase()
        let compaction = try await compactionRebuildCase()
        let checks: [String: Bool] = [
            "all-search-cases-pass": searchRows.allSatisfy(\.passed),
            "all-1024-depth-searches-stay-under-48-node-budget": searchRows
                .filter { $0.pendingDepth == 1_024 }
                .allSatisfy { $0.nodesExamined <= 48 },
            "1024-depth-tree-payload-is-at-most-4096-int-slots": searchRows
                .filter { $0.pendingDepth == 1_024 }
                .allSatisfy { $0.scalarSlots <= 4_096 },
            "cancellation-maintenance-case-passes": cancellation.passed,
            "compaction-rebuild-case-passes": compaction.passed,
        ]
        let observations: [String: Bool] = [
            "exact-query-node-work-remains-sublinear-at-1024-pending": searchRows
                .filter { $0.pendingDepth == 1_024 }
                .allSatisfy { $0.nodesExamined < $0.pendingDepth },
            "eager-exactness-adds-point-maintenance-to-primary-cancellation":
                cancellation.pointUpdateDelta == cancellation.cancelledRequests
                    && cancellation.nodeWriteDelta > cancellation.cancelledRequests,
            "compaction-reclaims-exact-index-tree-payload":
                compaction.scalarSlotsAfterCompaction
                    < compaction.scalarSlotsBeforeCompactionTrigger,
        ]
        let report = ExactBypassIndexReport(
            schemaVersion: 1,
            searchRows: searchRows,
            cancellation: cancellation,
            compaction: compaction,
            checks: checks,
            observations: observations,
            claims: [
                "productionDefaultChanged": false,
                "formalLatency": false,
                "filesystemIO": false,
                "physicalDevice": false,
                "exactQueuePositionAwareLookupMechanism": true,
                "cancellationMaintenanceMechanism": true,
                "compactionRebuildMechanism": true,
                "productionPolicyRecommendation": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw ExactBypassIndexProbeError.invariant("case-failure")
        }
    }

    private static func searchCase(
        depth: Int,
        fitPosition: Int?
    ) async throws -> ExactBypassSearchRow {
        let h = BypassScanHarness(
            bypasses: 3,
            pendingLimit: 1_024,
            lookupMode: .exactSlotMinIndex
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks = (0..<4).map { h.submit(bytes: 16, label: "e-a\(depth)-\($0)", gate: activeGate) }
        try await ReadSchedulerBoundedBypassSizeIndexProbe.waitStarts(
            4, h, "exact-search-active-\(depth)"
        )
        let head = h.submit(bytes: 32, label: "e-head-\(depth)", gate: headGate)
        tasks.append(head)
        try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(
            1, h, "exact-search-head-\(depth)"
        )

        let laterCount = depth - 1
        var laterGates: [DispatchSemaphore] = []
        for index in 0..<laterCount {
            let gate = DispatchSemaphore(value: 0)
            laterGates.append(gate)
            let bytes = fitPosition == index ? 1 : 32
            tasks.append(h.submit(bytes: bytes, label: "e-p\(depth)-\(index)", gate: gate))
            try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(
                index + 2, h, "exact-search-pending-\(depth)-\(index)"
            )
        }

        let before = h.scheduler.resourceSnapshot()
        activeGate.signal()
        try await waitExactSearches(
            before.bypassExactIndexSearches + 1,
            h,
            "exact-search-run-\(depth)"
        )
        let after = h.scheduler.resourceSnapshot()
        let searches = after.bypassExactIndexSearches - before.bypassExactIndexSearches
        let nodes = after.bypassExactIndexNodesExamined - before.bypassExactIndexNodesExamined
        let successful = after.successfulBypasses > before.successfulBypasses
        let expectedSuccess = fitPosition != nil
        let passed = searches == 1
            && successful == expectedSuccess
            && nodes > 0
            && nodes <= 48
            && after.pendingBypassExactIndexScalarSlots
                <= 2 * nextPowerOfTwo(after.pendingStorageSlots)

        for task in tasks.dropFirst(4) { task.cancel() }
        for gate in laterGates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await ReadSchedulerBoundedBypassSizeIndexProbe.finish(tasks)

        return .init(
            pendingDepth: depth,
            pendingStorageSlots: after.pendingStorageSlots,
            fitPosition: fitPosition,
            successfulBypass: successful,
            exactIndexSearches: searches,
            nodesExamined: nodes,
            maximumNodesPerSearch: after.maximumBypassExactIndexNodesPerSearch,
            scalarSlots: after.pendingBypassExactIndexScalarSlots,
            maximumScalarSlots: after.maximumPendingBypassExactIndexScalarSlots,
            passed: passed
        )
    }

    private static func cancellationMaintenanceCase() async throws -> ExactBypassCancellationRow {
        let h = BypassScanHarness(
            bypasses: 3,
            pendingLimit: 1_024,
            lookupMode: .exactSlotMinIndex
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let active = (0..<4).map { h.submit(bytes: 16, label: "ec-a\($0)", gate: activeGate) }
        try await ReadSchedulerBoundedBypassSizeIndexProbe.waitStarts(4, h, "exact-cancel-active")
        let head = h.submit(bytes: 32, label: "ec-head", gate: headGate)
        try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(1, h, "exact-cancel-head")

        let count = 512
        var tasks: [Task<String, Never>] = []
        var gates: [DispatchSemaphore] = []
        for index in 0..<count {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            // Strictly increasing exact sizes make removal of the current smallest indexed request
            // propagate minimum changes through many ancestors, stressing eager maintenance.
            tasks.append(h.submit(bytes: index + 1, label: "ec-p\(index)", gate: gate))
            try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(
                index + 2, h, "exact-cancel-pending-\(index)"
            )
        }
        let before = h.scheduler.resourceSnapshot()
        for task in tasks { task.cancel() }
        try await waitPendingCount(1, h, "exact-cancel-drain")
        let after = h.scheduler.resourceSnapshot()
        let pointUpdates = after.bypassExactIndexPointUpdates - before.bypassExactIndexPointUpdates
        let nodeWrites = after.bypassExactIndexNodeWrites - before.bypassExactIndexNodeWrites
        let searches = after.bypassExactIndexSearches - before.bypassExactIndexSearches

        head.cancel(); headGate.signal()
        for gate in gates { gate.signal() }
        activeGate.signal(); activeGate.signal(); activeGate.signal(); activeGate.signal()
        await ReadSchedulerBoundedBypassSizeIndexProbe.finish(active + [head] + tasks)
        return .init(
            cancelledRequests: count,
            pendingBefore: before.pendingCount,
            pendingAfter: after.pendingCount,
            exactSearchDelta: searches,
            pointUpdateDelta: pointUpdates,
            nodeWriteDelta: nodeWrites,
            scalarSlotsAfter: after.pendingBypassExactIndexScalarSlots,
            passed: before.pendingCount == count + 1
                && after.pendingCount == 1
                && searches == 0
                && pointUpdates == count
                && nodeWrites > count
                && after.pendingBypassExactIndexScalarSlots <= 2_048
        )
    }

    private static func compactionRebuildCase() async throws -> ExactBypassCompactionRow {
        let pendingLimit = 64
        let h = BypassScanHarness(
            bypasses: 3,
            pendingLimit: pendingLimit,
            lookupMode: .exactSlotMinIndex
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let active = (0..<4).map { h.submit(bytes: 16, label: "er-a\($0)", gate: activeGate) }
        try await ReadSchedulerBoundedBypassSizeIndexProbe.waitStarts(4, h, "exact-rebuild-active")
        let head = h.submit(bytes: 32, label: "er-head", gate: headGate)
        try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(1, h, "exact-rebuild-head")

        var firstWave: [Task<String, Never>] = []
        var firstGates: [DispatchSemaphore] = []
        for index in 0..<(pendingLimit - 1) {
            let gate = DispatchSemaphore(value: 0)
            firstGates.append(gate)
            firstWave.append(h.submit(bytes: 32, label: "er-f\(index)", gate: gate))
            try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(
                index + 2, h, "exact-rebuild-first-\(index)"
            )
        }
        for task in firstWave { task.cancel() }
        try await waitPendingCount(1, h, "exact-rebuild-first-cancel")
        let before = h.scheduler.resourceSnapshot()

        var secondWave: [Task<String, Never>] = []
        var secondGates: [DispatchSemaphore] = []
        for index in 0..<(pendingLimit - 1) {
            let gate = DispatchSemaphore(value: 0)
            secondGates.append(gate)
            secondWave.append(h.submit(bytes: 32, label: "er-s\(index)", gate: gate))
            try await ReadSchedulerBoundedBypassSizeIndexProbe.waitPending(
                index + 2, h, "exact-rebuild-second-\(index)"
            )
        }
        let after = h.scheduler.resourceSnapshot()

        head.cancel()
        for task in secondWave { task.cancel() }
        headGate.signal()
        for gate in firstGates { gate.signal() }
        for gate in secondGates { gate.signal() }
        activeGate.signal(); activeGate.signal(); activeGate.signal(); activeGate.signal()
        await ReadSchedulerBoundedBypassSizeIndexProbe.finish(
            active + [head] + firstWave + secondWave
        )

        let rebuildDelta = after.bypassExactIndexRebuilds - before.bypassExactIndexRebuilds
        let rebuildWrites = after.bypassExactIndexRebuildNodeWrites
            - before.bypassExactIndexRebuildNodeWrites
        return .init(
            pendingLimit: pendingLimit,
            storageBeforeCompactionTrigger: before.pendingStorageSlots,
            scalarSlotsBeforeCompactionTrigger: before.pendingBypassExactIndexScalarSlots,
            rebuildDelta: rebuildDelta,
            rebuildNodeWriteDelta: rebuildWrites,
            pendingAfterCompaction: after.pendingCount,
            storageAfterCompaction: after.pendingStorageSlots,
            scalarSlotsAfterCompaction: after.pendingBypassExactIndexScalarSlots,
            passed: before.pendingCount == 1
                && before.pendingStorageSlots > pendingLimit
                && rebuildDelta == 1
                && rebuildWrites > 0
                && after.pendingCount == pendingLimit
                && after.pendingStorageSlots == pendingLimit
                && after.pendingBypassExactIndexScalarSlots == pendingLimit * 2
                && after.pendingBypassExactIndexScalarSlots
                    < before.pendingBypassExactIndexScalarSlots
        )
    }

    private static func waitExactSearches(
        _ count: Int,
        _ h: BypassScanHarness,
        _ context: String
    ) async throws {
        for _ in 0..<8_000 {
            if h.scheduler.resourceSnapshot().bypassExactIndexSearches >= count { return }
            await Task.yield()
        }
        throw ExactBypassIndexProbeError.timeout(context)
    }

    private static func waitPendingCount(
        _ count: Int,
        _ h: BypassScanHarness,
        _ context: String
    ) async throws {
        for _ in 0..<8_000 {
            if h.scheduler.resourceSnapshot().pendingCount == count { return }
            await Task.yield()
        }
        throw ExactBypassIndexProbeError.timeout(context)
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result *= 2 }
        return result
    }
}
