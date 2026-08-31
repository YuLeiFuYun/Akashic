import AkashicMemory
import Foundation

extension MemoryAdmissionCompetitionProbe {
    static func run(
        policy: AdmissionCompetitionPolicy,
        workload: String,
        requests: [AdmissionCompetitionRequest]
    ) -> AdmissionCompetitionPolicyResult {
        var total = AdmissionCompetitionMetric()
        var byRole: [String: AdmissionCompetitionMetric] = [:]
        for request in requests {
            let hit = policy.request(request)
            guard request.measure else { continue }
            total.record(hit: hit, cost: request.cost)
            var metric = byRole[request.role.rawValue, default: AdmissionCompetitionMetric()]
            metric.record(hit: hit, cost: request.cost)
            byRole[request.role.rawValue] = metric
        }
        return AdmissionCompetitionPolicyResult(
            policy: policy.name,
            workload: workload,
            total: total,
            byRole: byRole,
            maximumResidentCost: policy.maximumResidentCost,
            finalResidentCost: policy.currentCost,
            metadataBytes: policy.metadataBytes,
            agingPasses: policy.agingPasses,
            maximumCounter: policy.maximumCounter,
            maximumVictimCount: policy.maximumVictimCount,
            maximumVictimCost: policy.maximumVictimCost,
            maximumProtectedSecondHitBytes: policy.maximumProtectedSecondHitBytes,
            provisionalRevocations: policy.provisionalRevocations,
            provisionalConfirmations: policy.provisionalConfirmations,
            fullVisitedEpochResets: policy.fullVisitedEpochResets,
            densityDeniedPromotions: policy.densityDeniedPromotions
        )
    }

    static func comparisonsAgainstBaseline(
        _ results: [AdmissionCompetitionPolicyResult]
    ) -> [AdmissionCompetitionPair] {
        let grouped = Dictionary(grouping: results, by: \.workload)
        return grouped.keys.sorted().flatMap { workload -> [AdmissionCompetitionPair] in
            let rows = grouped[workload]!
            let baseline = rows.first { $0.policy == "baseline-sieve" }!
            return rows.filter { $0.policy != "baseline-sieve" }.map { row in
                AdmissionCompetitionPair(
                    workload: workload,
                    policy: row.policy,
                    baselineCoreByteHitRatio: optionalRoleMetric(baseline, .core)?.byteHitRatio,
                    policyCoreByteHitRatio: optionalRoleMetric(row, .core)?.byteHitRatio,
                    baselineWarmByteHitRatio: optionalRoleMetric(baseline, .warm)?.byteHitRatio,
                    policyWarmByteHitRatio: optionalRoleMetric(row, .warm)?.byteHitRatio,
                    baselineStreamByteHitRatio: optionalRoleMetric(baseline, .stream)?.byteHitRatio,
                    policyStreamByteHitRatio: optionalRoleMetric(row, .stream)?.byteHitRatio,
                    baselineBurstByteHitRatio: optionalRoleMetric(baseline, .burst)?.byteHitRatio,
                    policyBurstByteHitRatio: optionalRoleMetric(row, .burst)?.byteHitRatio,
                    baselinePhaseBByteHitRatio: optionalRoleMetric(baseline, .phaseB)?.byteHitRatio,
                    policyPhaseBByteHitRatio: optionalRoleMetric(row, .phaseB)?.byteHitRatio,
                    totalByteHitRatioDelta: row.total.byteHitRatio - baseline.total.byteHitRatio
                )
            }
        }
    }

    static func roleMetric(
        _ result: AdmissionCompetitionPolicyResult,
        _ role: AdmissionCompetitionRole
    ) -> AdmissionCompetitionMetric {
        result.byRole[role.rawValue] ?? AdmissionCompetitionMetric()
    }

    static func optionalRoleMetric(
        _ result: AdmissionCompetitionPolicyResult,
        _ role: AdmissionCompetitionRole
    ) -> AdmissionCompetitionMetric? {
        result.byRole[role.rawValue]
    }

    static func makeTrace(
        _ workload: String
    ) -> (seed: [AdmissionCompetitionRequest], requests: [AdmissionCompetitionRequest]) {
        let seed = seedRequests()
        switch workload {
        case "second-touch-stream":
            return (seed, scanCompetitionTrace(touchesAfterInsert: 1))
        case "one-touch-stream-control":
            return (seed, scanCompetitionTrace(touchesAfterInsert: 0))
        case "second-touch-gap-0b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 0))
        case "second-touch-gap-4b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 4))
        case "second-touch-gap-8b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 8))
        case "second-touch-gap-16b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 16))
        case "second-touch-gap-32b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 32))
        case "second-touch-gap-64b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 64))
        case "second-touch-gap-128b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 128))
        case "second-touch-gap-256b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 256))
        case "second-touch-gap-512b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 512))
        case "second-touch-gap-1024b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 1_024))
        case "second-touch-gap-2048b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 2_048))
        case "second-touch-gap-4096b":
            return (seed, secondTouchByteGapTrace(interveningNewScanBytes: 4_096))
        case "two-touch-burst":
            var requests: [AdmissionCompetitionRequest] = []
            for index in 0..<256 {
                let request = AdmissionCompetitionRequest(
                    key: burstBase + index,
                    cost: 4,
                    role: .burst
                )
                requests.append(request)
                requests.append(request)
            }
            return (seed, requests)
        case "sparse-third-touch":
            return (seed, sparseThirdTrace(targetCosts: [256]))
        case "same-prefix-dead-s4":
            return (seed, samePrefixSecondHitTrace(targetCost: 4, hasFutureThirdHit: false))
        case "same-prefix-third-s4":
            return (seed, samePrefixSecondHitTrace(targetCost: 4, hasFutureThirdHit: true))
        case "same-prefix-dead-s16":
            return (seed, samePrefixSecondHitTrace(targetCost: 16, hasFutureThirdHit: false))
        case "same-prefix-third-s16":
            return (seed, samePrefixSecondHitTrace(targetCost: 16, hasFutureThirdHit: true))
        case "same-prefix-dead-s64":
            return (seed, samePrefixSecondHitTrace(targetCost: 64, hasFutureThirdHit: false))
        case "same-prefix-third-s64":
            return (seed, samePrefixSecondHitTrace(targetCost: 64, hasFutureThirdHit: true))
        case "physical-lease-branch-target-s64-n114":
            return (seed, physicalLeaseBranchTrace(revealTarget: true))
        case "physical-lease-branch-collateral-s64-n114":
            return (seed, physicalLeaseBranchTrace(revealTarget: false))
        case "sparse-third-size-32":
            return (seed, sparseThirdTrace(targetCosts: [32]))
        case "sparse-third-size-64":
            return (seed, sparseThirdTrace(targetCosts: [64]))
        case "sparse-third-size-128":
            return (seed, sparseThirdTrace(targetCosts: [128]))
        case "sparse-third-size-256":
            return (seed, sparseThirdTrace(targetCosts: [256]))
        case "sparse-third-size-512":
            return (seed, sparseThirdTrace(targetCosts: [512]))
        case "multi-sparse-third-c3-s128":
            return (seed, sparseThirdTrace(targetCosts: Array(repeating: 128, count: 3)))
        case "multi-sparse-third-c5-s64":
            return (seed, sparseThirdTrace(targetCosts: Array(repeating: 64, count: 5)))
        case "multi-sparse-third-c2-s256":
            return (seed, sparseThirdTrace(targetCosts: Array(repeating: 256, count: 2)))
        case "budget-fragment-small-first":
            return (seed, budgetFragmentationTrace(smallFirst: true))
        case "budget-fragment-large-first":
            return (seed, budgetFragmentationTrace(smallFirst: false))
        case "budget-occupancy-target64-decoys-first":
            return (seed, budgetOccupancyTrace(decoysFirst: true))
        case "budget-occupancy-target64-target-first":
            return (seed, budgetOccupancyTrace(decoysFirst: false))
        case "phase-shift":
            var requests: [AdmissionCompetitionRequest] = []
            for _ in 0..<64 {
                for key in 0..<16 {
                    requests.append(.init(key: 3_000_000 + key, cost: 16, role: .phaseA))
                }
            }
            for _ in 0..<64 {
                for key in 0..<16 {
                    requests.append(.init(key: 3_100_000 + key, cost: 16, role: .phaseB))
                }
            }
            return (seed, requests)
        case "cost-skew":
            var requests: [AdmissionCompetitionRequest] = []
            for round in 0..<64 {
                for key in 0..<64 {
                    requests.append(.init(key: coreBase + key, cost: 4, role: .small))
                }
                let giant = AdmissionCompetitionRequest(
                    key: 4_000_000 + round,
                    cost: 256,
                    role: .giant
                )
                requests.append(giant)
                requests.append(giant)
            }
            return (seed, requests)
        default:
            if let parameters = parseIndistinguishablePrefixWorkload(workload) {
                return (
                    seed,
                    indistinguishablePrefixTrace(
                        candidateCount: parameters.candidateCount,
                        targetIndex: parameters.targetIndex
                    )
                )
            }
            if let parameters = parseInterleavedSecondTouchWorkload(workload) {
                return (
                    seed,
                    interleavedSecondTouchTrace(
                        cohortSize: parameters.cohortSize,
                        quietEstablishedHits: parameters.quietHits
                    )
                )
            }
            if let parameters = parseAnchorSecondTouchWorkload(workload) {
                return (
                    seed,
                    anchorSecondTouchTrace(
                        cohortSize: parameters.cohortSize,
                        quietEstablishedHits: parameters.quietHits,
                        anchorCount: parameters.anchorCount,
                        scanObjectsPerRound: parameters.scanObjects
                    )
                )
            }
            preconditionFailure("unknown workload")
        }
    }

    static func parseIndistinguishablePrefixWorkload(
        _ workload: String
    ) -> (candidateCount: Int, targetIndex: Int)? {
        let prefix = "indist-prefix-c"
        guard workload.hasPrefix(prefix) else { return nil }
        let suffix = String(workload.dropFirst(prefix.count))
        let sizeParts = suffix.components(separatedBy: "-s16-target")
        guard sizeParts.count == 2,
              let candidateCount = Int(sizeParts[0]),
              [5, 9, 17, 33].contains(candidateCount),
              let targetIndex = Int(sizeParts[1]),
              (0..<candidateCount).contains(targetIndex)
        else { return nil }
        return (candidateCount, targetIndex)
    }

    /// Nine equal-cost candidates are observationally identical through their second request.
    /// Every target variant then receives the exact same pressure trace. Only the final request
    /// chooses which candidate turns out to have future reuse. Policies cannot use the target
    /// index because it is not revealed until that final request.
    static func indistinguishablePrefixTrace(
        candidateCount: Int,
        targetIndex: Int
    ) -> [AdmissionCompetitionRequest] {
        precondition([5, 9, 17, 33].contains(candidateCount))
        precondition((0..<candidateCount).contains(targetIndex))
        let candidates = (0..<candidateCount).map { index in
            AdmissionCompetitionRequest(
                key: 2_840_000 + index,
                cost: 16,
                role: .holder
            )
        }
        var requests: [AdmissionCompetitionRequest] = []
        for candidate in candidates {
            requests.append(candidate)
            requests.append(candidate)
        }
        appendSparsePressure(into: &requests, startingKey: 2_850_000)
        let target = candidates[targetIndex]
        requests.append(.init(key: target.key, cost: target.cost, role: .burst))
        return requests
    }

    /// Paired indistinguishability control. The `dead` and `third` variants have byte-for-byte
    /// identical request prefixes through both touches of the target and the complete pressure
    /// sequence. Only after that shared prefix may the `third` variant reveal one more request.
    /// No online second-hit rule can distinguish the pair at the decision point.
    static func samePrefixSecondHitTrace(
        targetCost: Int,
        hasFutureThirdHit: Bool
    ) -> [AdmissionCompetitionRequest] {
        precondition([4, 16, 64].contains(targetCost))
        let target = AdmissionCompetitionRequest(
            key: 2_490_000 + targetCost,
            cost: targetCost,
            role: .holder
        )
        var requests = [target, target]
        appendSparsePressure(into: &requests, startingKey: 2_495_000 + targetCost * 1_000)
        if hasFutureThirdHit {
            requests.append(.init(key: target.key, cost: target.cost, role: .burst))
        }
        return requests
    }

    /// Same-prefix post-hand lease ambiguity control for a 64-byte provisional target.
    /// Under the standard seed, the target's second chance is first consumed at 452 bytes of
    /// 4-byte cold pressure. A p456 lease therefore expires one miss later, after the hand has
    /// passed the target. Both variants share the exact prefix through 114 pressure insertions.
    /// Only the final request reveals whether future value belonged to the provisional target or
    /// to the second pressure object that physical expiry can preserve by freeing 64 bytes.
    static func physicalLeaseBranchTrace(revealTarget: Bool) -> [AdmissionCompetitionRequest] {
        let target = AdmissionCompetitionRequest(
            key: 2_485_064,
            cost: 64,
            role: .holder
        )
        let pressureBase = 2_486_000
        var requests = [target, target]
        for offset in 0..<114 {
            requests.append(
                .init(key: pressureBase + offset, cost: 4, role: .stream)
            )
        }
        if revealTarget {
            requests.append(.init(key: target.key, cost: target.cost, role: .burst))
        } else {
            requests.append(.init(key: pressureBase + 1, cost: 4, role: .burst))
        }
        return requests
    }

    static func sparseThirdTrace(targetCosts: [Int]) -> [AdmissionCompetitionRequest] {
        precondition(!targetCosts.isEmpty)
        precondition(targetCosts.allSatisfy { $0 > 0 && $0 <= costLimit })
        var requests: [AdmissionCompetitionRequest] = []
        let targets = targetCosts.enumerated().map { index, cost in
            AdmissionCompetitionRequest(
                key: 2_500_000 + index,
                cost: cost,
                role: .burst
            )
        }
        for target in targets {
            requests.append(target)
            requests.append(target)
        }
        appendSparsePressure(into: &requests, startingKey: 2_600_000)
        requests.append(contentsOf: targets)
        return requests
    }
}
