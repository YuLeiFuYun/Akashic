import AkashicCore
import AkashicDisk
import Dispatch
import Foundation

enum ReadSchedulerStructuralReservationProbe {
    static func run() async throws {
        let zero = try await zeroMarginBlocksBypass()
        let one = try await oneByteMarginBypassesAndPreservesHeadStart()
        let skip = try await oversizedCandidateSkippedForSmallerFollower()
        let cumulative = try await threePinnedBypassesPreserveHeadStart()
        let oversized = try await oversizedHeadHasZeroStructuralAllowance()
        let currentCapacity = try await currentCapacityOversizeControl()
        let linearThree = try await nonPowerOfTwoLinearControl()
        let indexedThree = try await conservativeIndexGranularityControl()
        let exactIndexedThree = try await exactIndexUsesNonPowerOfTwoMargin()
        let cancelledHead = try await cancelledHeadResetsStructuralState()
        let failedBypass = try await failedBypassReleasesActiveAccounting()
        let twoWorkers = try await twoWorkerBoundPreservesHeadStart()
        let cases = [
            zero, one, skip, cumulative, oversized, currentCapacity, linearThree, indexedThree,
            exactIndexedThree, cancelledHead, failedBypass, twoWorkers,
        ]
        let all = cases.allSatisfy(\.passed)
        let report = StructuralReservationReport(
            schemaVersion: 1,
            cases: cases,
            allCasesPass: all,
            observations: [
                "structural-mode-refuses-current-capacity-oversize-bypass": oversized.passed && currentCapacity.passed,
                "conservative-size-index-can-leave-safe-non-power-of-two-margin-unused": linearThree.passed && indexedThree.passed,
                "exact-slot-index-recovers-safe-non-power-of-two-margin": exactIndexedThree.passed,
            ],
            claims: .init(
                productionDefaultChanged: false,
                formalLatency: false,
                serviceTimePrediction: false,
                filesystemIO: false,
                physicalDevice: false,
                byteAndWorkerAdmissionInvariantOnly: true
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard all else { throw StructuralReservationProbeError.invariant("case-failure") }
    }

    private static func zeroMarginBlocksBypass() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 64)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { h.submit(bytes: 16, label: "z-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "zero-active")
        let head = h.submit(bytes: 32, label: "z-head", gate: headGate)
        try await waitPending(1, h, "zero-head")
        let small = h.submit(bytes: 1, label: "z-small", gate: smallGate)
        try await waitPending(2, h, "zero-small")
        try await settle()
        let before = h.state.snapshot()
        activeGate.signal()
        try await waitContains("z-head", h, "zero-head-start")
        let after = h.state.snapshot()
        headGate.signal()
        activeGate.signal(); activeGate.signal(); smallGate.signal()
        await finish(active + [head, small])
        return .init(
            name: "zero-margin-blocks-one-byte-bypass",
            relevantStarts: Array(after.dropFirst(3)),
            passed: before.count == 3 && Array(after.dropFirst(3)).first == "z-head"
        )
    }

    private static func oneByteMarginBypassesAndPreservesHeadStart() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 64)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { h.submit(bytes: 16, label: "o-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "one-active")
        let head = h.submit(bytes: 31, label: "o-head", gate: headGate)
        try await waitPending(1, h, "one-head")
        let small = h.submit(bytes: 1, label: "o-small", gate: smallGate)
        try await waitContains("o-small", h, "one-small-bypass")
        let beforeRelease = h.state.snapshot()
        activeGate.signal()
        try await waitContains("o-head", h, "one-head-start")
        let after = h.state.snapshot()
        smallGate.signal(); headGate.signal(); activeGate.signal(); activeGate.signal()
        await finish(active + [head, small])
        return .init(
            name: "one-byte-margin-bypasses-and-head-still-starts-after-one-original-completion",
            relevantStarts: Array(after.dropFirst(3)),
            passed: beforeRelease.last == "o-small"
                && Array(after.dropFirst(3)) == ["o-small", "o-head"]
        )
    }

    private static func oversizedCandidateSkippedForSmallerFollower() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 64, lookupMode: .linear)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let bigGate = DispatchSemaphore(value: 0)
        let fitGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { h.submit(bytes: 16, label: "s-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "skip-active")
        let head = h.submit(bytes: 30, label: "s-head", gate: headGate)
        try await waitPending(1, h, "skip-head")
        let big = h.submit(bytes: 3, label: "s-big3", gate: bigGate)
        try await waitPending(2, h, "skip-big")
        let fit = h.submit(bytes: 2, label: "s-fit2", gate: fitGate)
        try await waitContains("s-fit2", h, "skip-fit")
        let beforeRelease = h.state.snapshot()
        activeGate.signal()
        try await waitContains("s-head", h, "skip-head-start")
        let after = h.state.snapshot()
        fitGate.signal(); headGate.signal(); activeGate.signal(); activeGate.signal(); bigGate.signal()
        await finish(active + [head, big, fit])
        return .init(
            name: "three-byte-candidate-skipped-for-two-byte-safe-follower",
            relevantStarts: Array(after.dropFirst(3)),
            passed: beforeRelease.last == "s-fit2"
                && !beforeRelease.contains("s-big3")
                && Array(after.dropFirst(3)).prefix(2) == ["s-fit2", "s-head"]
        )
    }

    private static func threePinnedBypassesPreserveHeadStart() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 16)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGates = (0..<3).map { _ in DispatchSemaphore(value: 0) }
        let active = h.submit(bytes: 4, label: "c-active4", gate: activeGate)
        try await waitStarts(1, h, "cumulative-active")
        let head = h.submit(bytes: 13, label: "c-head13", gate: headGate)
        try await waitPending(1, h, "cumulative-head")
        var smalls: [Task<String, Never>] = []
        for index in 0..<3 {
            smalls.append(h.submit(bytes: 1, label: "c-s\(index)", gate: smallGates[index]))
            try await waitContains("c-s\(index)", h, "cumulative-s\(index)")
        }
        let pinned = h.state.snapshot()
        activeGate.signal()
        try await waitContains("c-head13", h, "cumulative-head-start")
        let after = h.state.snapshot()
        headGate.signal(); for gate in smallGates { gate.signal() }
        await finish([active, head] + smalls)
        return .init(
            name: "three-pinned-one-byte-bypasses-preserve-head-first-start-event",
            relevantStarts: Array(after.dropFirst(1)),
            passed: Array(pinned.dropFirst(1)) == ["c-s0", "c-s1", "c-s2"]
                && Array(after.dropFirst(1)) == ["c-s0", "c-s1", "c-s2", "c-head13"]
        )
    }

    private static func oversizedHeadHasZeroStructuralAllowance() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 16)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "x-active4", gate: activeGate)
        try await waitStarts(1, h, "oversize-active")
        let head = h.submit(bytes: 17, label: "x-head17", gate: headGate)
        try await waitPending(1, h, "oversize-head")
        let small = h.submit(bytes: 1, label: "x-small1", gate: smallGate)
        try await waitPending(2, h, "oversize-small")
        try await settle()
        let before = h.state.snapshot()
        activeGate.signal()
        try await waitContains("x-head17", h, "oversize-head-start")
        let after = h.state.snapshot()
        headGate.signal(); try await waitContains("x-small1", h, "oversize-small-after-head")
        smallGate.signal(); await finish([active, head, small])
        return .init(
            name: "oversized-head-has-zero-structural-bypass-allowance",
            relevantStarts: Array(after.dropFirst(1)),
            passed: before == ["x-active4"] && Array(after.dropFirst(1)).first == "x-head17"
        )
    }

    private static func currentCapacityOversizeControl() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(
            maximumInFlightBytes: 16,
            admissionMode: .currentCapacity
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let smallGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "k-active4", gate: activeGate)
        try await waitStarts(1, h, "current-active")
        let head = h.submit(bytes: 17, label: "k-head17", gate: headGate)
        try await waitPending(1, h, "current-head")
        let small = h.submit(bytes: 1, label: "k-small1", gate: smallGate)
        try await waitContains("k-small1", h, "current-small-bypass")
        let before = h.state.snapshot()
        smallGate.signal(); activeGate.signal()
        try await waitContains("k-head17", h, "current-head-start")
        let after = h.state.snapshot()
        headGate.signal(); await finish([active, head, small])
        return .init(
            name: "current-capacity-control-bypasses-oversized-head",
            relevantStarts: Array(after.dropFirst(1)),
            passed: before.last == "k-small1" && Array(after.dropFirst(1)) == ["k-small1", "k-head17"]
        )
    }

    private static func nonPowerOfTwoLinearControl() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 16, lookupMode: .linear)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let candidateGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "l-active4", gate: activeGate)
        try await waitStarts(1, h, "linear-active")
        let head = h.submit(bytes: 13, label: "l-head13", gate: headGate)
        try await waitPending(1, h, "linear-head")
        let candidate = h.submit(bytes: 3, label: "l-safe3", gate: candidateGate)
        try await waitContains("l-safe3", h, "linear-safe3")
        let before = h.state.snapshot()
        candidateGate.signal(); activeGate.signal()
        try await waitContains("l-head13", h, "linear-head-start")
        let after = h.state.snapshot()
        headGate.signal(); await finish([active, head, candidate])
        return .init(
            name: "linear-lookup-uses-three-byte-structural-margin",
            relevantStarts: Array(after.dropFirst(1)),
            passed: before.last == "l-safe3" && Array(after.dropFirst(1)) == ["l-safe3", "l-head13"]
        )
    }

    private static func conservativeIndexGranularityControl() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(
            maximumInFlightBytes: 16,
            lookupMode: .conservativeSizeIndex
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let candidateGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "i-active4", gate: activeGate)
        try await waitStarts(1, h, "index-active")
        let head = h.submit(bytes: 13, label: "i-head13", gate: headGate)
        try await waitPending(1, h, "index-head")
        let candidate = h.submit(bytes: 3, label: "i-safe3", gate: candidateGate)
        try await waitPending(2, h, "index-candidate")
        try await settle()
        let before = h.state.snapshot()
        activeGate.signal()
        try await waitContains("i-head13", h, "index-head-start")
        let after = h.state.snapshot()
        headGate.signal(); try await waitContains("i-safe3", h, "index-candidate-after-head")
        candidateGate.signal(); await finish([active, head, candidate])
        return .init(
            name: "conservative-size-index-does-not-use-three-byte-margin-class",
            relevantStarts: Array(after.dropFirst(1)),
            passed: before == ["i-active4"]
                && Set(after.dropFirst(1)) == Set(["i-head13", "i-safe3"])
        )
    }

    private static func exactIndexUsesNonPowerOfTwoMargin() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(
            maximumInFlightBytes: 16,
            lookupMode: .exactSlotMinIndex
        )
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let candidateGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "eidx-active4", gate: activeGate)
        try await waitStarts(1, h, "exact-index-active")
        let head = h.submit(bytes: 13, label: "eidx-head13", gate: headGate)
        try await waitPending(1, h, "exact-index-head")
        let before = h.scheduler.resourceSnapshot()
        let candidate = h.submit(bytes: 3, label: "eidx-safe3", gate: candidateGate)
        try await waitContains("eidx-safe3", h, "exact-index-safe3")
        let afterBypass = h.scheduler.resourceSnapshot()
        let beforeRelease = h.state.snapshot()
        candidateGate.signal(); activeGate.signal()
        try await waitContains("eidx-head13", h, "exact-index-head-start")
        let after = h.state.snapshot()
        headGate.signal(); await finish([active, head, candidate])
        return .init(
            name: "exact-slot-index-uses-three-byte-structural-margin",
            relevantStarts: Array(after.dropFirst(1)),
            passed: beforeRelease.last == "eidx-safe3"
                && Array(after.dropFirst(1)) == ["eidx-safe3", "eidx-head13"]
                && afterBypass.bypassExactIndexSearches > before.bypassExactIndexSearches
                && afterBypass.bypassExactIndexNodesExamined
                    > before.bypassExactIndexNodesExamined
                && afterBypass.pendingBypassExactIndexScalarSlots > 0
        )
    }

    private static func cancelledHeadResetsStructuralState() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 64)
        let activeGate = DispatchSemaphore(value: 0)
        let firstHeadGate = DispatchSemaphore(value: 0)
        let firstBypassGate = DispatchSemaphore(value: 0)
        let nextHeadGate = DispatchSemaphore(value: 0)
        let nextBypassGate = DispatchSemaphore(value: 0)
        let active = (0..<3).map { h.submit(bytes: 16, label: "q-a\($0)", gate: activeGate) }
        try await waitStarts(3, h, "cancel-reset-active")
        let firstHead = h.submit(bytes: 31, label: "q-head0", gate: firstHeadGate)
        try await waitPending(1, h, "cancel-reset-head0")
        let firstBypass = h.submit(bytes: 1, label: "q-bypass0", gate: firstBypassGate)
        try await waitContains("q-bypass0", h, "cancel-reset-bypass0")
        let nextHead = h.submit(bytes: 31, label: "q-head1", gate: nextHeadGate)
        try await waitPending(2, h, "cancel-reset-head1")
        firstHead.cancel()
        firstBypassGate.signal()
        try await waitPending(1, h, "cancel-reset-next-head-remains")
        let nextBypass = h.submit(bytes: 1, label: "q-bypass1", gate: nextBypassGate)
        try await waitContains("q-bypass1", h, "cancel-reset-bypass1")
        let beforeOriginalRelease = h.state.snapshot()
        activeGate.signal()
        try await waitContains("q-head1", h, "cancel-reset-head1-start")
        let after = h.state.snapshot()
        nextBypassGate.signal(); nextHeadGate.signal(); firstHeadGate.signal()
        activeGate.signal(); activeGate.signal()
        await finish(active + [firstHead, firstBypass, nextHead, nextBypass])
        return .init(
            name: "cancelled-blocked-head-resets-credit-and-structural-state",
            relevantStarts: Array(after.dropFirst(3)),
            passed: beforeOriginalRelease.contains("q-bypass0")
                && beforeOriginalRelease.contains("q-bypass1")
                && !beforeOriginalRelease.contains("q-head1")
                && Array(after.dropFirst(3)).last == "q-head1"
        )
    }

    private static func failedBypassReleasesActiveAccounting() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 16)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let badGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "e-active4", gate: activeGate)
        try await waitStarts(1, h, "error-active")
        let head = h.submit(bytes: 13, label: "e-head13", gate: headGate)
        try await waitPending(1, h, "error-head")
        h.state.markCorrupt("e-bad1")
        let bad = h.submit(bytes: 1, label: "e-bad1", gate: badGate)
        try await waitContains("e-bad1", h, "error-bypass")
        badGate.signal()
        let badResult = await bad.value
        try await settle()
        let afterFailure = h.state.snapshot()
        activeGate.signal()
        try await waitContains("e-head13", h, "error-head-start")
        let afterHead = h.state.snapshot()
        headGate.signal(); await finish([active, head])
        return .init(
            name: "integrity-failed-bypass-releases-active-size-accounting",
            relevantStarts: Array(afterHead.dropFirst(1)),
            passed: badResult == "error"
                && !afterFailure.contains("e-head13")
                && Array(afterHead.dropFirst(1)) == ["e-bad1", "e-head13"]
        )
    }

    private static func twoWorkerBoundPreservesHeadStart() async throws -> StructuralReservationCase {
        let h = StructuralReservationHarness(maximumInFlightBytes: 16, maximumConcurrentReads: 2)
        let activeGate = DispatchSemaphore(value: 0)
        let headGate = DispatchSemaphore(value: 0)
        let bypassGate = DispatchSemaphore(value: 0)
        let active = h.submit(bytes: 4, label: "w-active4", gate: activeGate)
        try await waitStarts(1, h, "two-worker-active")
        let head = h.submit(bytes: 13, label: "w-head13", gate: headGate)
        try await waitPending(1, h, "two-worker-head")
        let bypass = h.submit(bytes: 1, label: "w-bypass1", gate: bypassGate)
        try await waitContains("w-bypass1", h, "two-worker-bypass")
        let before = h.state.snapshot()
        activeGate.signal()
        try await waitContains("w-head13", h, "two-worker-head-start")
        let after = h.state.snapshot()
        bypassGate.signal(); headGate.signal(); await finish([active, head, bypass])
        return .init(
            name: "two-worker-bound-one-pinned-bypass-preserves-head-start",
            relevantStarts: Array(after.dropFirst(1)),
            passed: before == ["w-active4", "w-bypass1"]
                && Array(after.dropFirst(1)) == ["w-bypass1", "w-head13"]
        )
    }

    private static func waitPending(
        _ count: Int,
        _ h: StructuralReservationHarness,
        _ context: String
    ) async throws {
        for _ in 0..<500 {
            if h.scheduler.resourceSnapshot().pendingCount >= count { return }
            await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw StructuralReservationProbeError.timeout(context)
    }

    private static func waitStarts(
        _ count: Int,
        _ h: StructuralReservationHarness,
        _ context: String
    ) async throws {
        for _ in 0..<500 {
            if h.state.snapshot().count >= count { return }
            await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw StructuralReservationProbeError.timeout(context)
    }

    private static func waitContains(
        _ label: String,
        _ h: StructuralReservationHarness,
        _ context: String
    ) async throws {
        for _ in 0..<500 {
            if h.state.snapshot().contains(label) { return }
            await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw StructuralReservationProbeError.timeout(context)
    }

    private static func settle() async throws {
        for _ in 0..<10 {
            await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private static func finish(_ tasks: [Task<String, Never>]) async {
        for task in tasks { _ = await task.value }
    }
}
