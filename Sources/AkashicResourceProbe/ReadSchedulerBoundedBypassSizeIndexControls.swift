import AkashicDisk
import Dispatch
import Foundation

extension ReadSchedulerBoundedBypassSizeIndexProbe {
    static func immediateGuaranteedFit() async throws -> BypassSizeIndexCaseResult {
        let h = harness(pendingLimit: 32)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        var tasks = (0..<3).map { h.submit(bytes: 16, label: "i-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "i-active")
        let head = h.submit(bytes: 32, label: "i-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "i-head")
        let before = h.scheduler.resourceSnapshot()
        let small = h.submit(bytes: 1, label: "i-small", gate: smallGate)
        tasks.append(small)
        try await waitStarted("i-small", h, "i-small")
        let after = h.scheduler.resourceSnapshot()
        let relevant = Array(h.state.snapshotStarts().dropFirst(3))
        let result = makeResult(
            name: "immediate-guaranteed-fit",
            pendingDepth: 2,
            before: before,
            after: after,
            relevantStarts: relevant,
            passed: relevant == ["i-small"]
                && after.bypassIndexSearches - before.bypassIndexSearches == 1
                && after.bypassIndexClassesExamined - before.bypassIndexClassesExamined
                    == expectedClassesAt16Bytes
                && after.successfulBypasses - before.successfulBypasses == 1
        )
        head.cancel()
        smallGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        headGate.signal()
        await finish(tasks)
        return result
    }

    static func continuousThreeOvertakeBound() async throws -> BypassSizeIndexCaseResult {
        let h = harness(pendingLimit: 32)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
        var tasks = (0..<3).map { h.submit(bytes: 16, label: "c-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "c-active")
        let head = h.submit(bytes: 32, label: "c-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "c-head")
        let baseline = h.scheduler.resourceSnapshot()
        for index in 0..<3 {
            let task = h.submit(bytes: 1, label: "c-s\(index)", gate: smallGates[index])
            tasks.append(task)
            try await waitStarted("c-s\(index)", h, "c-s\(index)")
            smallGates[index].signal()
            try await waitActiveCount(3, h, "c-active-after-\(index)")
        }
        let fourth = h.submit(bytes: 1, label: "c-s3", gate: smallGates[3])
        tasks.append(fourth)
        try await waitPendingAtLeast(2, h, "c-s3-pending")
        try await settle()
        let beforeHead = h.scheduler.resourceSnapshot()
        let beforeStarts = h.state.snapshotStarts()
        activeGate.signal()
        try await waitStarted("c-head", h, "c-head-start")
        let after = h.scheduler.resourceSnapshot()
        let relevant = Array(h.state.snapshotStarts().dropFirst(3))
        let result = makeResult(
            name: "continuous-three-overtake-bound",
            pendingDepth: beforeHead.pendingCount,
            before: baseline,
            after: after,
            relevantStarts: relevant,
            passed: Array(beforeStarts.dropFirst(3)) == ["c-s0", "c-s1", "c-s2"]
                && !beforeStarts.contains("c-s3")
                && relevant.prefix(4) == ["c-s0", "c-s1", "c-s2", "c-head"]
                && beforeHead.successfulBypasses == 3
        )
        headGate.signal()
        smallGates[3].signal()
        activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return result
    }

    static func conservativeBoundaryMiss() async throws -> BypassSizeIndexCaseResult {
        let h = harness(pendingLimit: 16)
        let activeGates = (0..<3).map { _ in DispatchSemaphore(value: 0) }
        let headGate = DispatchSemaphore(value: 0)
        let candidateGate = DispatchSemaphore(value: 0)
        var tasks = [
            h.submit(bytes: 15, label: "b-a15", gate: activeGates[0]),
            h.submit(bytes: 16, label: "b-a16-0", gate: activeGates[1]),
            h.submit(bytes: 16, label: "b-a16-1", gate: activeGates[2]),
        ]
        try await waitStarts(3, h, "b-active")
        let head = h.submit(bytes: 32, label: "b-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "b-head")
        let before = h.scheduler.resourceSnapshot()
        let candidate = h.submit(bytes: 17, label: "b-exact17", gate: candidateGate)
        tasks.append(candidate)
        try await waitPending(2, h, "b-candidate")
        try await settle()
        let missed = h.scheduler.resourceSnapshot()
        let startsBeforeRelease = h.state.snapshotStarts()
        activeGates[0].signal()
        try await waitStarted("b-head", h, "b-head-start")
        headGate.signal()
        try await waitStarted("b-exact17", h, "b-candidate-start")
        let after = h.scheduler.resourceSnapshot()
        let relevant = Array(h.state.snapshotStarts().dropFirst(3))
        let result = makeResult(
            name: "conservative-exact-fit-boundary-miss",
            pendingDepth: 2,
            before: before,
            after: missed,
            relevantStarts: relevant,
            passed: !startsBeforeRelease.contains("b-exact17")
                && missed.successfulBypasses == before.successfulBypasses
                && missed.bypassIndexSearches - before.bypassIndexSearches == 1
                && relevant.prefix(2) == ["b-head", "b-exact17"]
                && after.activeBytes <= 64
        )
        candidateGate.signal()
        activeGates[1].signal(); activeGates[2].signal()
        await finish(tasks)
        return result
    }

    static func cancelledHeadResetsCredit() async throws -> BypassSizeIndexCaseResult {
        let h = harness(pendingLimit: 32)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
        var tasks = (0..<3).map { h.submit(bytes: 16, label: "x-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "x-active")
        let head = h.submit(bytes: 32, label: "x-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "x-head")
        for index in 0..<3 {
            let task = h.submit(bytes: 1, label: "x-s\(index)", gate: smallGates[index])
            tasks.append(task)
            try await waitStarted("x-s\(index)", h, "x-s\(index)")
            smallGates[index].signal()
            try await waitActiveCount(3, h, "x-active-after-\(index)")
        }
        let fourth = h.submit(bytes: 1, label: "x-s3", gate: smallGates[3])
        tasks.append(fourth)
        try await waitPendingAtLeast(2, h, "x-s3-pending")
        let before = h.scheduler.resourceSnapshot()
        head.cancel()
        try await waitStarted("x-s3", h, "x-s3-start")
        let after = h.scheduler.resourceSnapshot()
        let relevant = Array(h.state.snapshotStarts().dropFirst(3))
        let result = makeResult(
            name: "cancelled-head-resets-credit",
            pendingDepth: before.pendingCount,
            before: before,
            after: after,
            relevantStarts: relevant,
            passed: before.successfulBypasses == 3
                && relevant == ["x-s0", "x-s1", "x-s2", "x-s3"]
                && after.successfulBypasses == 3
        )
        smallGates[3].signal()
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return result
    }

    static func oversizeHeadBound() async throws -> BypassSizeIndexCaseResult {
        let h = harness(pendingLimit: 32)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<4).map { _ in DispatchSemaphore(value: 0) }
        var tasks = (0..<3).map { h.submit(bytes: 16, label: "o-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "o-active")
        let head = h.submit(bytes: 128, label: "o-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "o-head")
        for index in 0..<3 {
            let task = h.submit(bytes: 1, label: "o-s\(index)", gate: smallGates[index])
            tasks.append(task)
            try await waitStarted("o-s\(index)", h, "o-s\(index)")
            smallGates[index].signal()
            try await waitActiveCount(3, h, "o-active-after-\(index)")
        }
        let fourth = h.submit(bytes: 1, label: "o-s3", gate: smallGates[3])
        tasks.append(fourth)
        try await waitPendingAtLeast(2, h, "o-s3-pending")
        try await settle()
        let before = h.scheduler.resourceSnapshot()
        let startsBefore = h.state.snapshotStarts()
        activeGate.signal(); activeGate.signal()
        try await waitActiveCount(1, h, "o-one-active")
        try await settle()
        let beforeExclusive = h.state.snapshotStarts()
        activeGate.signal()
        try await waitStarted("o-head", h, "o-head-start")
        let after = h.scheduler.resourceSnapshot()
        let relevant = Array(h.state.snapshotStarts().dropFirst(3))
        let result = makeResult(
            name: "oversize-head-exclusive-after-three",
            pendingDepth: before.pendingCount,
            before: before,
            after: after,
            relevantStarts: relevant,
            passed: Array(startsBefore.dropFirst(3)) == ["o-s0", "o-s1", "o-s2"]
                && beforeExclusive == startsBefore
                && relevant.prefix(4) == ["o-s0", "o-s1", "o-s2", "o-head"]
        )
        headGate.signal()
        smallGates[3].signal()
        await finish(tasks)
        return result
    }

    static func staleFrontSingleStepBound() async throws -> BypassSizeIndexCaseResult {
        let h = harness(pendingLimit: 128)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let liveGate = DispatchSemaphore(value: 0)
        var tasks = (0..<4).map { h.submit(bytes: 16, label: "s-a\($0)", gate: activeGate) }
        try await waitStarts(4, h, "s-active")
        let head = h.submit(bytes: 32, label: "s-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "s-head")
        var staleTasks: [Task<String, Never>] = []
        var staleGates: [DispatchSemaphore] = []
        for index in 0..<64 {
            let gate = DispatchSemaphore(value: 0)
            staleGates.append(gate)
            let task = h.submit(bytes: 1, label: "s-stale\(index)", gate: gate)
            staleTasks.append(task)
            tasks.append(task)
            try await waitPending(index + 2, h, "s-pending-\(index)")
        }
        let live = h.submit(bytes: 1, label: "s-live", gate: liveGate)
        tasks.append(live)
        try await waitPending(66, h, "s-live-pending")
        for task in staleTasks { task.cancel() }
        try await waitPending(2, h, "s-stale-cancelled")
        let before = h.scheduler.resourceSnapshot()
        activeGate.signal()
        try await waitIndexSearches(before.bypassIndexSearches + 1, h, "s-search")
        try await settle()
        let after = h.scheduler.resourceSnapshot()
        let result = makeResult(
            name: "stale-front-single-step-bound",
            pendingDepth: 66,
            before: before,
            after: after,
            relevantStarts: Array(h.state.snapshotStarts().dropFirst(4)),
            passed: after.bypassIndexSearches - before.bypassIndexSearches == 1
                && after.bypassIndexClassesExamined - before.bypassIndexClassesExamined
                    == expectedClassesAt16Bytes
                && after.bypassIndexStaleTokensDiscarded - before.bypassIndexStaleTokensDiscarded == 1
                && after.successfulBypasses == before.successfulBypasses
                && !h.state.snapshotStarts().contains("s-live")
        )
        head.cancel(); live.cancel()
        for gate in staleGates { gate.signal() }
        liveGate.signal(); headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return result
    }

    static func strictFIFOControl() async throws -> BypassSizeIndexCaseResult {
        let h = BypassScanHarness(
            bypasses: 0,
            pendingLimit: 128,
            lookupMode: .conservativeSizeIndex
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        var tasks = (0..<4).map { h.submit(bytes: 16, label: "f-a\($0)", gate: activeGate) }
        try await waitStarts(4, h, "f-active")
        let head = h.submit(bytes: 32, label: "f-head", gate: headGate)
        tasks.append(head)
        try await waitPending(1, h, "f-head")
        let before = h.scheduler.resourceSnapshot()
        var gates: [DispatchSemaphore] = []
        for index in 0..<64 {
            let gate = DispatchSemaphore(value: 0)
            gates.append(gate)
            tasks.append(h.submit(bytes: 1, label: "f-p\(index)", gate: gate))
            try await waitPending(index + 2, h, "f-pending-\(index)")
        }
        activeGate.signal()
        try await settle()
        let snapshot = h.scheduler.resourceSnapshot()
        let result = makeResult(
            name: "strict-fifo-zero-index-work",
            pendingDepth: snapshot.pendingCount,
            before: before,
            after: snapshot,
            relevantStarts: Array(h.state.snapshotStarts().dropFirst(4)),
            passed: snapshot.bypassIndexSearches == 0
                && snapshot.bypassIndexClassesExamined == 0
                && snapshot.pendingBypassIndexTokenSlots == 0
                && snapshot.successfulBypasses == 0
        )
        for task in tasks.dropFirst(4) { task.cancel() }
        for gate in gates { gate.signal() }
        headGate.signal()
        activeGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(tasks)
        return result
    }

}
