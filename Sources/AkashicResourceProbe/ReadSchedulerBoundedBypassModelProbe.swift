import Foundation

private enum BypassModelError: Error {
    case invariant(String)
}

private struct BypassModelJob: Equatable {
    let id: String
    let bytes: Int
}

private struct BypassModelSnapshot: Codable {
    let active: [String]
    let pending: [String]
    let inFlightBytes: Int
    let blockedHead: String?
    let remainingBypasses: Int
}

private struct BypassModelCase: Codable {
    let name: String
    let laterStartsBeforeHead: Int
    let headStarted: Bool
    let snapshots: [BypassModelSnapshot]
    let passed: Bool
}

private struct BypassModelReport: Codable {
    struct Claims: Codable {
        let productionSchedulerChanged: Bool
        let actualExecutorIntegrated: Bool
        let formalLatency: Bool
    }

    let schemaVersion: Int
    let maximumWorkers: Int
    let maximumBytes: Int
    let maximumBypassesPerBlockedHead: Int
    let cases: [BypassModelCase]
    let allCasesPass: Bool
    let claims: Claims
}

private struct BoundedBypassSchedulerModel {
    let maximumWorkers: Int
    let maximumBytes: Int
    let maximumPending: Int
    let maximumBypassesPerBlockedHead: Int

    private(set) var active: [BypassModelJob] = []
    private(set) var pending: [BypassModelJob] = []
    private(set) var startOrder: [String] = []
    private var blockedHeadID: String?
    private var remainingBypasses = 0

    var inFlightBytes: Int { active.reduce(0) { $0 + $1.bytes } }

    mutating func seedActive(_ jobs: [BypassModelJob]) throws {
        guard active.isEmpty, pending.isEmpty,
            jobs.count <= maximumWorkers,
            jobs.reduce(0, { $0 + $1.bytes }) <= maximumBytes
        else { throw BypassModelError.invariant("seed") }
        active = jobs
        startOrder.append(contentsOf: jobs.map(\.id))
    }

    mutating func enqueue(_ job: BypassModelJob) throws {
        guard job.bytes > 0,
            job.bytes <= maximumBytes,
            pending.count < maximumPending
        else { throw BypassModelError.invariant("enqueue") }
        pending.append(job)
        try schedule()
    }

    mutating func complete(_ id: String) throws {
        guard let index = active.firstIndex(where: { $0.id == id }) else {
            throw BypassModelError.invariant("complete-\(id)")
        }
        active.remove(at: index)
        try schedule()
    }

    mutating func cancelPending(_ id: String) throws {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            throw BypassModelError.invariant("cancel-\(id)")
        }
        let wasBlockedHead = blockedHeadID == id
        pending.remove(at: index)
        if wasBlockedHead {
            blockedHeadID = nil
            remainingBypasses = 0
        }
        try schedule()
    }

    func snapshot() -> BypassModelSnapshot {
        BypassModelSnapshot(
            active: active.map(\.id),
            pending: pending.map(\.id),
            inFlightBytes: inFlightBytes,
            blockedHead: blockedHeadID,
            remainingBypasses: remainingBypasses
        )
    }

    private mutating func schedule() throws {
        while active.count < maximumWorkers, !pending.isEmpty {
            let head = pending[0]
            if canStart(head) {
                pending.removeFirst()
                active.append(head)
                startOrder.append(head.id)
                blockedHeadID = nil
                remainingBypasses = 0
                continue
            }

            if blockedHeadID != head.id {
                blockedHeadID = head.id
                remainingBypasses = maximumBypassesPerBlockedHead
            }
            guard remainingBypasses > 0,
                let bypassIndex = pending.indices.dropFirst().first(where: { canStart(pending[$0]) })
            else { break }
            let bypass = pending.remove(at: bypassIndex)
            active.append(bypass)
            startOrder.append(bypass.id)
            remainingBypasses -= 1
        }
        guard active.count <= maximumWorkers,
            inFlightBytes <= maximumBytes,
            pending.count <= maximumPending
        else { throw BypassModelError.invariant("bounds") }
    }

    private func canStart(_ job: BypassModelJob) -> Bool {
        active.count < maximumWorkers && inFlightBytes <= maximumBytes - job.bytes
    }
}

enum ReadSchedulerBoundedBypassModelProbe {
    static func run() throws {
        let cases = try [
            freeWorkerCase(),
            maxHeadContinuousSmallCase(),
            fittingHeadCase(),
            cancelledHeadCase(),
            pendingCapCase(),
        ]
        guard cases.allSatisfy(\.passed) else {
            throw BypassModelError.invariant("case-failure")
        }
        let report = BypassModelReport(
            schemaVersion: 1,
            maximumWorkers: 4,
            maximumBytes: 64,
            maximumBypassesPerBlockedHead: 3,
            cases: cases,
            allCasesPass: true,
            claims: .init(
                productionSchedulerChanged: false,
                actualExecutorIntegrated: false,
                formalLatency: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func model() -> BoundedBypassSchedulerModel {
        BoundedBypassSchedulerModel(
            maximumWorkers: 4,
            maximumBytes: 64,
            maximumPending: 64,
            maximumBypassesPerBlockedHead: 3
        )
    }

    private static func freeWorkerCase() throws -> BypassModelCase {
        var model = model()
        try model.seedActive([
            .init(id: "m0", bytes: 16),
            .init(id: "m1", bytes: 16),
            .init(id: "m2", bytes: 16),
        ])
        try model.enqueue(.init(id: "head", bytes: 32))
        try model.enqueue(.init(id: "small", bytes: 1))
        var snapshots = [model.snapshot()]
        let smallBypassed = model.active.contains(where: { $0.id == "small" })
            && model.pending.first?.id == "head"
        try model.complete("small")
        snapshots.append(model.snapshot())
        let stillBlockedAfterSmall = model.startOrder.firstIndex(of: "head") == nil
        try model.complete("m0")
        snapshots.append(model.snapshot())
        let beforeHead = model.startOrder.firstIndex(of: "head")
        let smallIndex = model.startOrder.firstIndex(of: "small")
        let passed = smallBypassed
            && stillBlockedAfterSmall
            && beforeHead != nil
            && smallIndex != nil
            && smallIndex! < beforeHead!
        return .init(
            name: "free-worker-byte-HOL",
            laterStartsBeforeHead: 1,
            headStarted: beforeHead != nil,
            snapshots: snapshots,
            passed: passed
        )
    }

    private static func maxHeadContinuousSmallCase() throws -> BypassModelCase {
        var model = model()
        try model.seedActive([
            .init(id: "a0", bytes: 1),
            .init(id: "a1", bytes: 1),
            .init(id: "a2", bytes: 1),
        ])
        try model.enqueue(.init(id: "head", bytes: 64))
        for index in 0..<32 {
            try model.enqueue(.init(id: "s\(index)", bytes: 1))
        }
        var snapshots = [model.snapshot()]
        // Complete original actives first; each free worker may admit another small only while
        // blocked-head credit remains. After three bypasses total, later smalls must stop overtaking.
        try model.complete("a0")
        snapshots.append(model.snapshot())
        try model.complete("a1")
        snapshots.append(model.snapshot())
        try model.complete("a2")
        snapshots.append(model.snapshot())

        let headIndexBeforeBypassCompletion = model.startOrder.firstIndex(of: "head")
        let laterBeforeHead = model.startOrder.filter { $0.hasPrefix("s") }.count
        // Drain the at-most-three bypass jobs. No new small may consume their freed slots after credit0.
        for id in model.active.map(\.id).filter({ $0.hasPrefix("s") }) {
            try model.complete(id)
            snapshots.append(model.snapshot())
        }
        let headIndex = model.startOrder.firstIndex(of: "head")
        let passed = headIndexBeforeBypassCompletion == nil
            && laterBeforeHead == 3
            && headIndex != nil
            && model.startOrder.prefix(headIndex!).filter({ $0.hasPrefix("s") }).count == 3
        return .init(
            name: "continuous-small-stream",
            laterStartsBeforeHead: 3,
            headStarted: headIndex != nil,
            snapshots: snapshots,
            passed: passed
        )
    }

    private static func fittingHeadCase() throws -> BypassModelCase {
        var model = model()
        try model.seedActive([
            .init(id: "a0", bytes: 16),
            .init(id: "a1", bytes: 16),
            .init(id: "a2", bytes: 16),
        ])
        try model.enqueue(.init(id: "head", bytes: 16))
        try model.enqueue(.init(id: "small", bytes: 1))
        let snapshot = model.snapshot()
        let headIndex = model.startOrder.firstIndex(of: "head")
        let smallIndex = model.startOrder.firstIndex(of: "small")
        let passed = headIndex != nil && smallIndex == nil && snapshot.blockedHead == nil
        return .init(
            name: "fitting-head-control",
            laterStartsBeforeHead: 0,
            headStarted: true,
            snapshots: [snapshot],
            passed: passed
        )
    }

    private static func cancelledHeadCase() throws -> BypassModelCase {
        var model = model()
        try model.seedActive([
            .init(id: "a0", bytes: 16),
            .init(id: "a1", bytes: 16),
            .init(id: "a2", bytes: 16),
        ])
        try model.enqueue(.init(id: "head", bytes: 32))
        try model.enqueue(.init(id: "small", bytes: 1))
        let before = model.snapshot()
        try model.cancelPending("head")
        let after = model.snapshot()
        let passed = before.blockedHead == "head"
            && !after.pending.contains("head")
            && after.blockedHead == nil
            && model.startOrder.contains("small")
        return .init(
            name: "head-cancel",
            laterStartsBeforeHead: 1,
            headStarted: false,
            snapshots: [before, after],
            passed: passed
        )
    }

    private static func pendingCapCase() throws -> BypassModelCase {
        var model = BoundedBypassSchedulerModel(
            maximumWorkers: 1,
            maximumBytes: 64,
            maximumPending: 4,
            maximumBypassesPerBlockedHead: 0
        )
        try model.seedActive([.init(id: "active", bytes: 64)])
        for index in 0..<4 {
            try model.enqueue(.init(id: "p\(index)", bytes: 1))
        }
        var rejected = false
        do {
            try model.enqueue(.init(id: "overflow", bytes: 1))
        } catch {
            rejected = true
        }
        let snapshot = model.snapshot()
        return .init(
            name: "pending-cap",
            laterStartsBeforeHead: 0,
            headStarted: false,
            snapshots: [snapshot],
            passed: rejected && snapshot.pending.count == 4
        )
    }
}
