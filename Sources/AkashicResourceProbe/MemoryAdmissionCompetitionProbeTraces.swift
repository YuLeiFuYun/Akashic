import AkashicMemory
import Foundation

extension MemoryAdmissionCompetitionProbe {
    static func budgetFragmentationTrace(smallFirst: Bool) -> [AdmissionCompetitionRequest] {
        var requests: [AdmissionCompetitionRequest] = []
        let holders = (0..<16).map { index in
            AdmissionCompetitionRequest(
                key: 2_700_000 + index,
                cost: 16,
                role: .holder
            )
        }
        let target = AdmissionCompetitionRequest(
            key: 2_800_000,
            cost: 256,
            role: .burst
        )
        func appendTwoTouches(_ request: AdmissionCompetitionRequest) {
            requests.append(request)
            requests.append(request)
        }
        if smallFirst {
            for holder in holders { appendTwoTouches(holder) }
            appendTwoTouches(target)
        } else {
            appendTwoTouches(target)
            for holder in holders { appendTwoTouches(holder) }
        }
        appendSparsePressure(into: &requests, startingKey: 2_900_000)
        requests.append(target)
        return requests
    }

    /// Attacks speculative second-hit byte budgets with order rather than size infeasibility.
    /// The 64-byte target fits b64/b128/b256. Eight 16-byte decoys can exactly occupy b128 before
    /// the target's second hit, but have no third reuse. Reversing the order tests whether the same
    /// multiset of requests receives different future-value retention solely because provisional
    /// budget was already occupied by indistinguishable two-touch decoys.
    static func budgetOccupancyTrace(decoysFirst: Bool) -> [AdmissionCompetitionRequest] {
        var requests: [AdmissionCompetitionRequest] = []
        let decoys = (0..<8).map { index in
            AdmissionCompetitionRequest(
                key: 2_810_000 + index,
                cost: 16,
                role: .holder
            )
        }
        let target = AdmissionCompetitionRequest(
            key: 2_820_000,
            cost: 64,
            role: .burst
        )
        func appendTwoTouches(_ request: AdmissionCompetitionRequest) {
            requests.append(request)
            requests.append(request)
        }
        if decoysFirst {
            for decoy in decoys { appendTwoTouches(decoy) }
            appendTwoTouches(target)
        } else {
            appendTwoTouches(target)
            for decoy in decoys { appendTwoTouches(decoy) }
        }
        appendSparsePressure(into: &requests, startingKey: 2_830_000)
        requests.append(target)
        return requests
    }

    static func appendSparsePressure(
        into requests: inout [AdmissionCompetitionRequest],
        startingKey: Int
    ) {
        var pressureKey = startingKey
        for round in 0..<4 {
            for key in 0..<64 {
                requests.append(.init(key: coreBase + key, cost: 4, role: .core))
            }
            if round % 2 == 0 {
                for key in 0..<64 {
                    requests.append(.init(key: warmBase + key, cost: 4, role: .warm))
                }
            }
            for _ in 0..<64 {
                requests.append(.init(key: pressureKey, cost: 4, role: .stream))
                pressureKey += 1
            }
        }
    }

    static func parseAnchorSecondTouchWorkload(
        _ workload: String
    ) -> (cohortSize: Int, quietHits: Int, anchorCount: Int, scanObjects: Int)? {
        let prefix = "anchor-second-touch-c"
        guard workload.hasPrefix(prefix) else { return nil }
        let suffix = String(workload.dropFirst(prefix.count))
        let quietParts = suffix.components(separatedBy: "-q")
        guard quietParts.count == 2,
              let cohortSize = Int(quietParts[0])
        else { return nil }
        let anchorParts = quietParts[1].components(separatedBy: "-a")
        guard anchorParts.count == 2,
              let quietHits = Int(anchorParts[0])
        else { return nil }
        let scanParts = anchorParts[1].components(separatedBy: "-n")
        guard scanParts.count == 2,
              let anchorCount = Int(scanParts[0]),
              let scanObjects = Int(scanParts[1]),
              cohortSize > 0,
              scanObjects > 0,
              scanObjects % cohortSize == 0,
              quietHits > 0,
              anchorCount > 0,
              anchorCount <= 64
        else { return nil }
        return (cohortSize, quietHits, anchorCount, scanObjects)
    }

    static func anchorSecondTouchTrace(
        cohortSize: Int,
        quietEstablishedHits: Int,
        anchorCount: Int,
        scanObjectsPerRound: Int
    ) -> [AdmissionCompetitionRequest] {
        var result: [AdmissionCompetitionRequest] = []
        var nextStreamKey = streamBase
        var nextAnchorOffset = 0
        for _ in 0..<32 {
            var remaining = scanObjectsPerRound
            while remaining > 0 {
                let batch = min(cohortSize, remaining)
                for _ in 0..<batch {
                    let request = AdmissionCompetitionRequest(
                        key: nextStreamKey,
                        cost: 4,
                        role: .stream
                    )
                    result.append(request)
                    result.append(request)
                    nextStreamKey += 1
                }
                remaining -= batch
                for _ in 0..<quietEstablishedHits {
                    result.append(
                        .init(
                            key: coreBase + (nextAnchorOffset % anchorCount),
                            cost: 4,
                            role: .anchor
                        )
                    )
                    nextAnchorOffset += 1
                }
            }
            // Observe the full core only after the scan/anchor interleave has had a chance to
            // evict it. This measurement sweep also restores/refreshes the core for the next round.
            for key in 0..<64 {
                result.append(.init(key: coreBase + key, cost: 4, role: .core))
            }
        }
        return result
    }

    static func parseInterleavedSecondTouchWorkload(
        _ workload: String
    ) -> (cohortSize: Int, quietHits: Int)? {
        let prefix = "interleaved-second-touch-c"
        guard workload.hasPrefix(prefix) else { return nil }
        let suffix = String(workload.dropFirst(prefix.count))
        let parts = suffix.components(separatedBy: "-q")
        guard parts.count == 2,
              let cohortSize = Int(parts[0]),
              let quietHits = Int(parts[1]),
              cohortSize > 0,
              64 % cohortSize == 0,
              quietHits > 0
        else { return nil }
        return (cohortSize, quietHits)
    }

    static func interleavedSecondTouchTrace(
        cohortSize: Int,
        quietEstablishedHits: Int
    ) -> [AdmissionCompetitionRequest] {
        var result: [AdmissionCompetitionRequest] = []
        var nextStreamKey = streamBase
        var nextCoreOffset = 0
        for _ in 0..<32 {
            var remaining = 64
            while remaining > 0 {
                let batch = min(cohortSize, remaining)
                for _ in 0..<batch {
                    let request = AdmissionCompetitionRequest(
                        key: nextStreamKey,
                        cost: 4,
                        role: .stream
                    )
                    result.append(request)
                    result.append(request)
                    nextStreamKey += 1
                }
                remaining -= batch
                for _ in 0..<quietEstablishedHits {
                    result.append(
                        .init(
                            key: coreBase + (nextCoreOffset % 64),
                            cost: 4,
                            role: .core
                        )
                    )
                    nextCoreOffset += 1
                }
            }
        }
        return result
    }

    static func seedRequests() -> [AdmissionCompetitionRequest] {
        var result: [AdmissionCompetitionRequest] = []
        for key in 0..<128 {
            result.append(.init(key: fillerBase + key, cost: 4, role: .stream))
        }
        for key in 0..<64 {
            result.append(.init(key: warmBase + key, cost: 4, role: .warm))
        }
        for key in 0..<64 {
            result.append(.init(key: coreBase + key, cost: 4, role: .core))
        }
        precondition(result.reduce(0) { $0 + $1.cost } == costLimit)
        return result
    }

    static func scanCompetitionTrace(touchesAfterInsert: Int) -> [AdmissionCompetitionRequest] {
        precondition(touchesAfterInsert == 0 || touchesAfterInsert == 1)
        var result: [AdmissionCompetitionRequest] = []
        var nextScanKey = streamBase
        for round in 0..<64 {
            if round % 4 == 0 {
                for key in 0..<64 {
                    result.append(.init(key: coreBase + key, cost: 4, role: .core))
                }
            }
            if round % 2 == 0 {
                for key in 0..<64 {
                    result.append(.init(key: warmBase + key, cost: 4, role: .warm))
                }
            }
            for _ in 0..<64 {
                let request = AdmissionCompetitionRequest(
                    key: nextScanKey,
                    cost: 4,
                    role: .stream
                )
                result.append(request)
                if touchesAfterInsert == 1 { result.append(request) }
                nextScanKey += 1
            }
        }
        return result
    }

    /// Steady-state competitive second-touch trace keyed by exact unique-new-scan byte distance.
    /// The first 64 rounds are policy warm-up and excluded from hit accounting. The byte clock only
    /// advances for first-time stream insertions represented by this trace; a second-request miss
    /// may still reinsert into the cache and cause real eviction pressure, but that reinsertion does
    /// not redefine the requested reuse-distance axis.
    static func secondTouchByteGapTrace(
        interveningNewScanBytes: Int
    ) -> [AdmissionCompetitionRequest] {
        precondition(
            [0, 4, 8, 16, 32, 64, 128, 256, 512, 1_024, 2_048, 4_096]
                .contains(interveningNewScanBytes)
        )
        precondition(interveningNewScanBytes.isMultiple(of: 4))
        let warmupRounds = 64
        let measurementRounds = 64
        let totalRounds = warmupRounds + measurementRounds
        var result: [AdmissionCompetitionRequest] = []
        var scheduledSecondTouchesByScanByteClock: [Int: [Int]] = [:]
        var uniqueScanByteClock = 0
        var nextScanKey = streamBase

        for round in 0..<totalRounds {
            let measure = round >= warmupRounds
            if round % 4 == 0 {
                for key in 0..<64 {
                    result.append(.init(key: coreBase + key, cost: 4, role: .core, measure: measure))
                }
            }
            if round % 2 == 0 {
                for key in 0..<64 {
                    result.append(.init(key: warmBase + key, cost: 4, role: .warm, measure: measure))
                }
            }

            for _ in 0..<64 {
                let key = nextScanKey
                nextScanKey += 1
                result.append(.init(key: key, cost: 4, role: .stream, measure: measure))
                uniqueScanByteClock += 4
                if interveningNewScanBytes == 0 {
                    result.append(.init(key: key, cost: 4, role: .stream, measure: measure))
                } else {
                    scheduledSecondTouchesByScanByteClock[
                        uniqueScanByteClock + interveningNewScanBytes,
                        default: []
                    ].append(key)
                }
                if let dueKeys = scheduledSecondTouchesByScanByteClock.removeValue(
                    forKey: uniqueScanByteClock
                ) {
                    for dueKey in dueKeys {
                        result.append(.init(key: dueKey, cost: 4, role: .stream, measure: measure))
                    }
                }
            }
        }
        return result
    }

    static func collisionControl(width: Int) -> AdmissionCompetitionCollision {
        let target = 9_000_000 + width
        var sketch = AdmissionCompetitionSketch(width: width)
        var colliders: [Int] = []
        var cursor = 9_100_000
        for row in 0..<AdmissionCompetitionSketch.rows {
            let wanted = sketch.position(target, row: row)
            while sketch.position(cursor, row: row) != wanted || cursor == target { cursor += 1 }
            colliders.append(cursor)
            cursor += 1
        }
        for key in colliders {
            for _ in 0..<64 { sketch.increment(key) }
        }
        let estimate = sketch.estimate(target)
        return AdmissionCompetitionCollision(
            width: width,
            target: target,
            colliders: colliders,
            exactTargetCount: 0,
            sketchTargetEstimate: estimate,
            falseHotCreated: estimate > 0
        )
    }
}
