import AkashicMemory
import Foundation

private struct CollisionWindowEntry {
    let value: Int
    let cost: Int
}

final class CollisionAdmissionPolicy {
    private let hashMode: CollisionHashMode
    private let estimator: CollisionEstimator
    private let main = MemoryCache<CollisionKey, Int>(costLimit: 90)
    private let windowLimit = 10
    private let contestHorizon = 8
    private var sketch = CollisionSketch()
    private var ghost: CollisionGhost?
    private var exact: [Int: Int] = [:]
    private var window: [CollisionKey: CollisionWindowEntry] = [:]
    private var windowOrder: [CollisionKey] = []
    private var windowCost = 0
    private var contestsForClock = 0
    private(set) var falseAdmits = 0
    private(set) var falseRejects = 0
    private(set) var admissionContests = 0
    private(set) var agingPasses = 0
    private(set) var residentMismatches = 0
    private(set) var maximumVictimCount = 0
    private(set) var maximumVictimCost = 0
    private(set) var coherentExactComparisons = 0
    private(set) var sketchFallbackComparisons = 0
    private(set) var fallbackMissingCandidateComparisons = 0
    private(set) var fallbackMissingVictimComparisons = 0
    private(set) var maximumMissingVictimCount = 0

    init(hashMode: CollisionHashMode, estimator: CollisionEstimator) {
        self.hashMode = hashMode
        self.estimator = estimator
        if case .exactGhost(let capacity) = estimator {
            ghost = CollisionGhost(capacity: capacity)
        }
    }

    var maximumCounter: Int { sketch.maximumCounter }
    var counterPayloadBytes: Int { sketch.counterPayloadBytes }
    var maximumGhostEntries: Int { ghost?.maximumEntryCount ?? 0 }
    var ghostShallowPayloadBytes: Int { ghost?.shallowPayloadBytesAtMaximum ?? 0 }

    func primeHotSet() {
        for id in 0..<9 {
            let key = makeKey(id)
            main.insert(id, for: key, cost: 10)
            observe(key)
        }
        let tenth = makeKey(9)
        window[tenth] = CollisionWindowEntry(value: 9, cost: 10)
        windowOrder = [tenth]
        windowCost = 10
        observe(tenth)
        for _ in 0..<2 {
            for id in 0..<10 {
                let key = makeKey(id)
                observe(key)
                _ = value(for: key)
            }
        }
        assertBounds()
    }

    func request(_ request: CollisionRequest) -> Bool {
        let key = makeKey(request.id)
        observe(key)
        if value(for: key) != nil { return true }
        if request.cost <= windowLimit {
            insertIntoWindow(key: key, value: request.id, cost: request.cost)
        } else {
            considerMain(key: key, value: request.id, cost: request.cost)
        }
        assertBounds()
        return false
    }

    private func makeKey(_ id: Int) -> CollisionKey {
        CollisionKey(id: id, mode: hashMode)
    }

    private func observe(_ key: CollisionKey) {
        exact[key.id, default: 0] += 1
        sketch.increment(collisionFingerprint(key))
        ghost?.observe(key)
    }

    private func age() {
        exact = exact.reduce(into: [:]) { output, item in
            let value = item.value / 2
            if value > 0 { output[item.key] = value }
        }
        sketch.halve()
        ghost?.halve()
        agingPasses += 1
    }

    private func value(for key: CollisionKey) -> Int? {
        if let value = main.value(for: key) {
            if value != key.id { residentMismatches += 1 }
            return value
        }
        if let entry = window[key] {
            if entry.value != key.id { residentMismatches += 1 }
            return entry.value
        }
        return nil
    }

    private func insertIntoWindow(key: CollisionKey, value: Int, cost: Int) {
        if let old = window.removeValue(forKey: key) {
            windowCost -= old.cost
            windowOrder.removeAll { $0 == key }
        }
        while windowCost > windowLimit - cost, let oldest = windowOrder.first {
            windowOrder.removeFirst()
            guard let evicted = window.removeValue(forKey: oldest) else { continue }
            windowCost -= evicted.cost
            considerMain(key: oldest, value: evicted.value, cost: evicted.cost)
        }
        window[key] = CollisionWindowEntry(value: value, cost: cost)
        windowOrder.append(key)
        windowCost += cost
    }

    private func considerMain(key: CollisionKey, value: Int, cost: Int) {
        guard cost <= 90 else { return }
        let victims = main.resourceProbeEvictionForecast(incomingCost: cost)
        maximumVictimCount = max(maximumVictimCount, victims.count)
        maximumVictimCost = max(maximumVictimCost, victims.reduce(0) { $0 + $1.cost })
        guard !victims.isEmpty else {
            main.insert(value, for: key, cost: cost)
            return
        }
        if contestsForClock > 0, contestsForClock % contestHorizon == 0 { age() }
        contestsForClock += 1
        admissionContests += 1

        let exactCandidate = exact[key.id, default: 0]
        let exactVictims = victims.reduce(0) { $0 + exact[$1.key.id, default: 0] }
        let estimates = coherentPolicyEstimates(candidate: key, victims: victims)
        let candidateEstimate = estimates.candidate
        let victimEstimate = estimates.victims
        let exactDecision = exactCandidate > exactVictims
        let policyDecision = candidateEstimate > victimEstimate
        if policyDecision && !exactDecision { falseAdmits += 1 }
        if !policyDecision && exactDecision { falseRejects += 1 }
        if policyDecision { main.insert(value, for: key, cost: cost) }
    }

    private func coherentPolicyEstimates(
        candidate: CollisionKey,
        victims: [MemoryCacheEvictionVictim<CollisionKey>]
    ) -> (candidate: Int, victims: Int) {
        if estimator == .oracleExactVictims {
            return (
                sketch.estimate(collisionFingerprint(candidate)),
                victims.reduce(0) { $0 + exact[$1.key.id, default: 0] }
            )
        }
        if let ghost {
            let candidateExact = ghost.estimate(candidate)
            var victimExact = 0
            var missingVictims = 0
            for victim in victims {
                if let value = ghost.estimate(victim.key) {
                    victimExact += value
                } else {
                    missingVictims += 1
                }
            }
            if let candidateExact, missingVictims == 0 {
                coherentExactComparisons += 1
                return (candidateExact, victimExact)
            }
            sketchFallbackComparisons += 1
            if candidateExact == nil { fallbackMissingCandidateComparisons += 1 }
            if missingVictims > 0 {
                fallbackMissingVictimComparisons += 1
                maximumMissingVictimCount = max(maximumMissingVictimCount, missingVictims)
            }
        }
        return (
            sketch.estimate(collisionFingerprint(candidate)),
            victims.reduce(0) { $0 + sketch.estimate(collisionFingerprint($1.key)) }
        )
    }

    private func assertBounds() {
        precondition(main.currentCost <= 90)
        precondition(windowCost <= 10)
        precondition(main.currentCost + windowCost <= 100)
    }
}
