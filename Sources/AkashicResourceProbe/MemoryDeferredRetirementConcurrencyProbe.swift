import AkashicMemory
import Dispatch
import Foundation

private final class DeferredRetirementTracker: @unchecked Sendable {
    struct Snapshot: Codable {
        let entered: Int
        let exited: Int
        let currentBlocked: Int
        let maximumConcurrentBlocked: Int
    }

    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = 0
    private var exited = 0
    private var currentBlocked = 0
    private var maximumConcurrentBlocked = 0

    func retire() {
        lock.lock()
        entered += 1
        currentBlocked += 1
        maximumConcurrentBlocked = max(maximumConcurrentBlocked, currentBlocked)
        lock.unlock()

        gate.wait()

        lock.lock()
        currentBlocked -= 1
        exited += 1
        lock.unlock()
    }

    func release(_ count: Int) {
        for _ in 0..<count { gate.signal() }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(
            entered: entered,
            exited: exited,
            currentBlocked: currentBlocked,
            maximumConcurrentBlocked: maximumConcurrentBlocked
        )
    }
}

private final class DeferredRetirementAttemptTracker: @unchecked Sendable {
    struct Snapshot: Codable {
        let replaced: Int
        let backpressured: Int
        let ineligible: Int
    }

    private let lock = NSLock()
    private var replacedKeys: [Int] = []
    private var backpressuredKeysStorage: [Int] = []
    private var ineligibleKeys: [Int] = []

    func record(key: Int, disposition: MemoryCacheDeferredRetirementDisposition) {
        lock.lock(); defer { lock.unlock() }
        switch disposition {
        case .replaced: replacedKeys.append(key)
        case .backpressured: backpressuredKeysStorage.append(key)
        case .ineligible: ineligibleKeys.append(key)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(
            replaced: replacedKeys.count,
            backpressured: backpressuredKeysStorage.count,
            ineligible: ineligibleKeys.count
        )
    }

    func backpressuredKeys() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return backpressuredKeysStorage
    }
}

private final class DeferredRetirementValue: @unchecked Sendable {
    private let tracker: DeferredRetirementTracker?

    init(tracker: DeferredRetirementTracker?) { self.tracker = tracker }
    deinit { tracker?.retire() }
}

private struct DeferredRetirementConcurrencyCase: Codable {
    let name: String
    let requestedReplacements: Int
    let maximumConcurrentRetirements: Int?
    let beforeRelease: DeferredRetirementTracker.Snapshot
    let afterRelease: DeferredRetirementTracker.Snapshot
    let firstWaveBeforeRelease: DeferredRetirementAttemptTracker.Snapshot
    let firstWaveAfterRelease: DeferredRetirementAttemptTracker.Snapshot
    let retryAttempts: DeferredRetirementAttemptTracker.Snapshot
    let finalCacheCount: Int
    let finalCacheCost: Int
}

private struct DeferredRetirementConcurrencyReport: Codable {
    let schemaVersion: Int
    let unboundedControl: DeferredRetirementConcurrencyCase
    let boundedCandidate: DeferredRetirementConcurrencyCase
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}

enum MemoryDeferredRetirementConcurrencyProbe {
    private static let replacements = 24

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }
        let unbounded = runUnboundedControl()
        let bounded = runBoundedCandidate()

        let report = DeferredRetirementConcurrencyReport(
            schemaVersion: 2,
            unboundedControl: unbounded,
            boundedCandidate: bounded,
            checks: [
                "logical-cache-bound-preserved":
                    unbounded.finalCacheCount == 1
                        && unbounded.finalCacheCost == 1
                        && bounded.finalCacheCount == 1
                        && bounded.finalCacheCost == 1,
                "unbounded-control-completes-all-first-wave-replacements":
                    unbounded.firstWaveAfterRelease.replaced == replacements
                        && unbounded.firstWaveAfterRelease.backpressured == 0
                        && unbounded.firstWaveAfterRelease.ineligible == 0,
                "bounded-first-wave-admits-exactly-one-retirement":
                    bounded.firstWaveAfterRelease.replaced == 1
                        && bounded.firstWaveAfterRelease.backpressured == replacements - 1
                        && bounded.firstWaveAfterRelease.ineligible == 0,
                "bounded-retries-repay-all-backpressure":
                    bounded.retryAttempts.replaced == replacements - 1
                        && bounded.retryAttempts.backpressured == 0
                        && bounded.retryAttempts.ineligible == 0,
                "bounded-retirement-never-exceeds-one-blocked-generation":
                    bounded.beforeRelease.maximumConcurrentBlocked == 1
                        && bounded.afterRelease.maximumConcurrentBlocked == 1
                        && bounded.afterRelease.currentBlocked == 0,
            ],
            observations: [
                "unbounded-deferred-retirement-overlaps-across-callers":
                    unbounded.beforeRelease.maximumConcurrentBlocked > 1,
                "logical-cost-bound-does-not-bound-unbounded-retired-lifetime":
                    unbounded.beforeRelease.currentBlocked > 1
                        && unbounded.finalCacheCost == 1,
                "one-slot-reservation-converts-retirement-debt-to-explicit-backpressure":
                    bounded.beforeRelease.currentBlocked == 1
                        && bounded.firstWaveBeforeRelease.backpressured == replacements - 1,
                "bounded-backpressure-is-retryable-after-retirement-drains":
                    bounded.retryAttempts.replaced == replacements - 1,
            ],
            claims: [
                "formalPerformance": false,
                "physicalRSSBytes": false,
                "productionPolicyRecommendation": false,
                "retirementConcurrencyMechanism": true,
                "unboundedControlRetirementDebtBounded": false,
                "boundedCandidateRetirementGenerationCountBounded": true,
                "boundedCandidateRetiredByteCountBounded": false,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard report.checks.values.allSatisfy({ $0 }),
            report.observations.values.allSatisfy({ $0 })
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runUnboundedControl() -> DeferredRetirementConcurrencyCase {
        let retirement = DeferredRetirementTracker()
        let attempts = DeferredRetirementAttemptTracker()
        let cache = MemoryCache<Int, DeferredRetirementValue>(costLimit: 1)
        cache.insert(DeferredRetirementValue(tracker: retirement), for: 0, cost: 1)

        let queue = DispatchQueue(label: "akashic.retirement.unbounded", attributes: .concurrent)
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for key in 1...replacements {
            group.enter()
            queue.async {
                start.wait()
                let summary = cache.resourceProbeInsertFullCostUsingDeferredRetirement(
                    DeferredRetirementValue(tracker: retirement),
                    for: key,
                    cost: 1
                )
                attempts.record(key: key, disposition: summary == nil ? .ineligible : .replaced)
                group.leave()
            }
        }
        for _ in 0..<replacements { start.signal() }

        for _ in 0..<400 {
            if retirement.snapshot().currentBlocked >= 3 { break }
            Thread.sleep(forTimeInterval: 0.0025)
        }
        let beforeRelease = retirement.snapshot()
        let attemptsBeforeRelease = attempts.snapshot()
        retirement.release(replacements * 4)
        _ = group.wait(timeout: .now() + 5)
        let afterRelease = retirement.snapshot()
        let attemptsAfterRelease = attempts.snapshot()

        let row = DeferredRetirementConcurrencyCase(
            name: "unbounded-control",
            requestedReplacements: replacements,
            maximumConcurrentRetirements: nil,
            beforeRelease: beforeRelease,
            afterRelease: afterRelease,
            firstWaveBeforeRelease: attemptsBeforeRelease,
            firstWaveAfterRelease: attemptsAfterRelease,
            retryAttempts: .init(replaced: 0, backpressured: 0, ineligible: 0),
            finalCacheCount: cache.count,
            finalCacheCost: cache.currentCost
        )
        // The final resident also carries a blocking deinit witness. Leave permits available for
        // cache teardown after this function returns.
        retirement.release(replacements * 4)
        return row
    }

    private static func runBoundedCandidate() -> DeferredRetirementConcurrencyCase {
        let retirement = DeferredRetirementTracker()
        let firstWave = DeferredRetirementAttemptTracker()
        let retries = DeferredRetirementAttemptTracker()
        let cache = MemoryCache<Int, DeferredRetirementValue>(costLimit: 1)
        // Only the seed value blocks on retirement. Incoming values are intentionally nonblocking so
        // a rejected caller cannot fabricate retirement debt merely by destroying its own argument.
        cache.insert(DeferredRetirementValue(tracker: retirement), for: 0, cost: 1)

        let queue = DispatchQueue(label: "akashic.retirement.bounded", attributes: .concurrent)
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for key in 1...replacements {
            group.enter()
            queue.async {
                start.wait()
                let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
                    DeferredRetirementValue(tracker: nil),
                    for: key,
                    cost: 1,
                    maximumConcurrentRetirements: 1
                )
                firstWave.record(key: key, disposition: attempt.disposition)
                group.leave()
            }
        }
        for _ in 0..<replacements { start.signal() }

        for _ in 0..<400 {
            let retirementState = retirement.snapshot()
            let attemptState = firstWave.snapshot()
            if retirementState.currentBlocked == 1
                && attemptState.backpressured == replacements - 1
            {
                break
            }
            Thread.sleep(forTimeInterval: 0.0025)
        }
        let beforeRelease = retirement.snapshot()
        let attemptsBeforeRelease = firstWave.snapshot()
        retirement.release(1)
        _ = group.wait(timeout: .now() + 5)
        let afterRelease = retirement.snapshot()
        let attemptsAfterRelease = firstWave.snapshot()

        for key in firstWave.backpressuredKeys() {
            let attempt = cache.resourceProbeTryInsertFullCostUsingDeferredRetirement(
                DeferredRetirementValue(tracker: nil),
                for: key,
                cost: 1,
                maximumConcurrentRetirements: 1
            )
            retries.record(key: key, disposition: attempt.disposition)
        }

        return DeferredRetirementConcurrencyCase(
            name: "one-slot-bounded-candidate",
            requestedReplacements: replacements,
            maximumConcurrentRetirements: 1,
            beforeRelease: beforeRelease,
            afterRelease: afterRelease,
            firstWaveBeforeRelease: attemptsBeforeRelease,
            firstWaveAfterRelease: attemptsAfterRelease,
            retryAttempts: retries.snapshot(),
            finalCacheCount: cache.count,
            finalCacheCost: cache.currentCost
        )
    }
}
