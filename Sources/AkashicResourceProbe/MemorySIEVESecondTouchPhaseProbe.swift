import AkashicMemory
import Foundation

private struct SIEVESecondTouchPhaseResidentShape: Sendable {
    let name: String
    let coreObjectCount: Int
    let coreObjectCost: Int
    let warmObjectCount: Int
    let warmObjectCost: Int

    var coreBytes: Int { coreObjectCount * coreObjectCost }
    var warmBytes: Int { warmObjectCount * warmObjectCost }
}

private enum SIEVESecondTouchPhaseTopology: String, Codable, CaseIterable {
    case fillerWarmCore = "filler-warm-core"
    case shuffle73 = "shuffle-73"
}

private struct SIEVESecondTouchPhaseScanShape: Sendable {
    let objectCost: Int
    let objectsPerRound: Int

    var bytesPerRound: Int { objectCost * objectsPerRound }
}

private struct SIEVESecondTouchPhaseTransition: Sendable {
    let beforeGapObjects: Int
    let afterGapObjects: Int

    var name: String { "g\(beforeGapObjects)-to-g\(afterGapObjects)" }
}

private struct SIEVESecondTouchPhaseCase: Codable {
    let residentShape: String
    let topology: String
    let scanObjectCost: Int
    let scanObjectsPerRound: Int
    let transition: String
    let beforeGapObjects: Int
    let afterGapObjects: Int
    let beforeRounds: Int
    let afterRounds: Int

    let preSwitchCoreByteHitRatio: Double
    let preSwitchWarmByteHitRatio: Double
    let postSwitchCoreByteHitRatio: Double
    let postSwitchWarmByteHitRatio: Double
    let finalWindowCoreByteHitRatio: Double
    let finalWindowWarmByteHitRatio: Double

    let postSwitchCoreMissServiceRounds: [Int]
    let postSwitchWarmMissServiceRounds: [Int]
    let firstPostSwitchCoreMissRound: Int?
    let firstPostSwitchWarmMissRound: Int?
    let lastPostSwitchCoreMissRound: Int?
    let lastPostSwitchWarmMissRound: Int?
    let coreMissBytesAfterSwitch: Int
    let warmMissBytesAfterSwitch: Int
    let scanSecondRequestBytesAfterSwitch: Int
    let scanSecondHitBytesAfterSwitch: Int
    let scanSecondMissBytesAfterSwitch: Int
    let scanSecondByteHitRatioAfterSwitch: Double
    let finalCost: Int
    let finalCount: Int
}

private struct SIEVESecondTouchPhaseReport: Codable {
    struct Claims: Codable {
        let cachePolicyMechanismEvaluated: Bool
        let phaseAdaptationInRequestRounds: Bool
        let wallClockPerformance: Bool
        let productionPolicyRecommendation: Bool
        let diskSemantics: Bool
        let authoritySemantics: Bool
        let foveaBusinessSemantics: Bool
    }

    let schemaVersion: Int
    let costLimit: Int
    let coreReuseStride: Int
    let warmReuseStride: Int
    let beforeRounds: Int
    let afterRounds: Int
    let finalWindowRounds: Int
    let residentShapeNames: [String]
    let topologies: [String]
    let scanShapes: [[String: Int]]
    let transitions: [String]
    let cases: [SIEVESecondTouchPhaseCase]
    let allResidentCostsWithinLimit: Bool
    let allPostSwitchSecondVolumesBalanced: Bool
    let controlsRemainInExpectedSteadyState: Bool
    let claims: Claims
}

enum MemorySIEVESecondTouchPhaseProbe {
    private static let costLimit = 1_024
    private static let fillerObjectCount = 128
    private static let fillerObjectCost = 4
    private static let fillerBase = 0
    private static let warmBase = 100_000
    private static let coreBase = 200_000
    private static let scanBase = 1_000_000
    private static let coreReuseStride = 4
    private static let warmReuseStride = 2
    private static let beforeRounds = 64
    private static let afterRounds = 128
    private static let finalWindowRounds = 16

    private static let residentShapes = [
        SIEVESecondTouchPhaseResidentShape(
            name: "uniform-4",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVESecondTouchPhaseResidentShape(
            name: "medium-16",
            coreObjectCount: 16,
            coreObjectCost: 16,
            warmObjectCount: 16,
            warmObjectCost: 16
        ),
        SIEVESecondTouchPhaseResidentShape(
            name: "large-core-64",
            coreObjectCount: 4,
            coreObjectCost: 64,
            warmObjectCount: 64,
            warmObjectCost: 4
        ),
        SIEVESecondTouchPhaseResidentShape(
            name: "large-warm-64",
            coreObjectCount: 64,
            coreObjectCost: 4,
            warmObjectCount: 4,
            warmObjectCost: 64
        ),
    ]
    private static let scanShapes = [
        SIEVESecondTouchPhaseScanShape(objectCost: 4, objectsPerRound: 64),
        SIEVESecondTouchPhaseScanShape(objectCost: 64, objectsPerRound: 4),
    ]
    private static let transitions = [
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 0),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 2, afterGapObjects: 2),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 2),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 4),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 8),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 16),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 32),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 64),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 0, afterGapObjects: 128),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 1, afterGapObjects: 2),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 2, afterGapObjects: 0),
        SIEVESecondTouchPhaseTransition(beforeGapObjects: 2, afterGapObjects: 1),
    ]

    static func run() throws {
        precondition(fillerObjectCount * fillerObjectCost == 512)
        precondition(residentShapes.allSatisfy { $0.coreBytes == 256 && $0.warmBytes == 256 })
        precondition(scanShapes.allSatisfy { $0.bytesPerRound == 256 })
        precondition(beforeRounds.isMultiple(of: coreReuseStride))
        precondition(afterRounds.isMultiple(of: coreReuseStride))
        precondition(finalWindowRounds.isMultiple(of: coreReuseStride))

        var cases: [SIEVESecondTouchPhaseCase] = []
        for shape in residentShapes {
            for topology in SIEVESecondTouchPhaseTopology.allCases {
                for scanShape in scanShapes {
                    for transition in transitions {
                        cases.append(
                            runCase(
                                shape: shape,
                                topology: topology,
                                scanShape: scanShape,
                                transition: transition
                            )
                        )
                    }
                }
            }
        }
        precondition(cases.count == 192)

        let allResidentCostsWithinLimit = cases.allSatisfy { $0.finalCost <= costLimit }
        let allPostSwitchSecondVolumesBalanced = cases.allSatisfy { row in
            let afterObjects = afterRounds * row.scanObjectsPerRound
            // Delayed cohorts deliberately cross the phase boundary and the run ends without a
            // synthetic tail drain. The post-switch window therefore includes `beforeGapObjects`
            // inherited second requests and excludes the final `afterGapObjects` requests whose
            // deadlines fall beyond the run. Gap-zero requests are immediate and fit this same
            // formula.
            let expectedSecondObjects =
                afterObjects - row.afterGapObjects + row.beforeGapObjects
            let expectedPostSwitchSecondBytes = expectedSecondObjects * row.scanObjectCost
            return row.scanSecondRequestBytesAfterSwitch == expectedPostSwitchSecondBytes
                && row.scanSecondHitBytesAfterSwitch + row.scanSecondMissBytesAfterSwitch
                    == row.scanSecondRequestBytesAfterSwitch
        }
        let controlsRemainInExpectedSteadyState = cases.allSatisfy { row in
            switch row.transition {
            case "g0-to-g0":
                return row.finalWindowCoreByteHitRatio < 1 || row.finalWindowWarmByteHitRatio < 1
            case "g2-to-g2":
                return row.finalWindowCoreByteHitRatio == 1
                    && row.finalWindowWarmByteHitRatio == 1
                    && row.scanSecondByteHitRatioAfterSwitch == 0
            default:
                return true
            }
        }

        let report = SIEVESecondTouchPhaseReport(
            schemaVersion: 1,
            costLimit: costLimit,
            coreReuseStride: coreReuseStride,
            warmReuseStride: warmReuseStride,
            beforeRounds: beforeRounds,
            afterRounds: afterRounds,
            finalWindowRounds: finalWindowRounds,
            residentShapeNames: residentShapes.map(\.name),
            topologies: SIEVESecondTouchPhaseTopology.allCases.map(\.rawValue),
            scanShapes: scanShapes.map {
                [
                    "objectCost": $0.objectCost,
                    "objectsPerRound": $0.objectsPerRound,
                    "bytesPerRound": $0.bytesPerRound,
                ]
            },
            transitions: transitions.map(\.name),
            cases: cases,
            allResidentCostsWithinLimit: allResidentCostsWithinLimit,
            allPostSwitchSecondVolumesBalanced: allPostSwitchSecondVolumesBalanced,
            controlsRemainInExpectedSteadyState: controlsRemainInExpectedSteadyState,
            claims: .init(
                cachePolicyMechanismEvaluated: true,
                phaseAdaptationInRequestRounds: true,
                wallClockPerformance: false,
                productionPolicyRecommendation: false,
                diskSemantics: false,
                authoritySemantics: false,
                foveaBusinessSemantics: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allResidentCostsWithinLimit,
            allPostSwitchSecondVolumesBalanced,
            controlsRemainInExpectedSteadyState
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        shape: SIEVESecondTouchPhaseResidentShape,
        topology: SIEVESecondTouchPhaseTopology,
        scanShape: SIEVESecondTouchPhaseScanShape,
        transition: SIEVESecondTouchPhaseTransition
    ) -> SIEVESecondTouchPhaseCase {
        let cache = MemoryCache<Int, Int>(costLimit: costLimit)
        let fillerKeys = (0..<fillerObjectCount).map { fillerBase + $0 }
        let warmKeys = (0..<shape.warmObjectCount).map { warmBase + $0 }
        let coreKeys = (0..<shape.coreObjectCount).map { coreBase + $0 }
        let costs = Dictionary(
            uniqueKeysWithValues:
                fillerKeys.map { ($0, fillerObjectCost) }
                + warmKeys.map { ($0, shape.warmObjectCost) }
                + coreKeys.map { ($0, shape.coreObjectCost) }
        )
        for key in seedOrder(
            topology: topology,
            fillerKeys: fillerKeys,
            warmKeys: warmKeys,
            coreKeys: coreKeys
        ) {
            cache.insert(key, for: key, cost: costs[key]!)
        }
        precondition(cache.currentCost == costLimit)
        for key in coreKeys { precondition(cache.value(for: key) == key) }
        for key in warmKeys { precondition(cache.value(for: key) == key) }

        var nextScanKey = scanBase
        var uniqueScanObjectClock = 0
        var scheduledSecondTouches: [Int: [Int]] = [:]
        var beforeCoreRequestBytes = 0
        var beforeCoreHitBytes = 0
        var beforeWarmRequestBytes = 0
        var beforeWarmHitBytes = 0
        var afterCoreRequestBytes = 0
        var afterCoreHitBytes = 0
        var afterWarmRequestBytes = 0
        var afterWarmHitBytes = 0
        var finalCoreRequestBytes = 0
        var finalCoreHitBytes = 0
        var finalWarmRequestBytes = 0
        var finalWarmHitBytes = 0
        var postCoreMissRounds: [Int] = []
        var postWarmMissRounds: [Int] = []
        var coreMissBytesAfterSwitch = 0
        var warmMissBytesAfterSwitch = 0
        var secondRequestBytesAfterSwitch = 0
        var secondHitBytesAfterSwitch = 0
        var secondMissBytesAfterSwitch = 0

        let totalRounds = beforeRounds + afterRounds
        for absoluteRound in 0..<totalRounds {
            let afterSwitch = absoluteRound >= beforeRounds
            let postRound = absoluteRound - beforeRounds
            let finalWindow = afterSwitch && postRound >= afterRounds - finalWindowRounds
            let gap = afterSwitch ? transition.afterGapObjects : transition.beforeGapObjects

            if absoluteRound % coreReuseStride == 0 {
                var serviceMissed = false
                for key in coreKeys {
                    let hit = cache.value(for: key) != nil
                    if afterSwitch {
                        afterCoreRequestBytes += shape.coreObjectCost
                        if hit { afterCoreHitBytes += shape.coreObjectCost }
                        else {
                            serviceMissed = true
                            coreMissBytesAfterSwitch += shape.coreObjectCost
                            cache.insert(key, for: key, cost: shape.coreObjectCost)
                        }
                        if finalWindow {
                            finalCoreRequestBytes += shape.coreObjectCost
                            if hit { finalCoreHitBytes += shape.coreObjectCost }
                        }
                    } else {
                        beforeCoreRequestBytes += shape.coreObjectCost
                        if hit { beforeCoreHitBytes += shape.coreObjectCost }
                        else { cache.insert(key, for: key, cost: shape.coreObjectCost) }
                    }
                }
                if afterSwitch && serviceMissed { postCoreMissRounds.append(postRound) }
            }

            if absoluteRound % warmReuseStride == 0 {
                var serviceMissed = false
                for key in warmKeys {
                    let hit = cache.value(for: key) != nil
                    if afterSwitch {
                        afterWarmRequestBytes += shape.warmObjectCost
                        if hit { afterWarmHitBytes += shape.warmObjectCost }
                        else {
                            serviceMissed = true
                            warmMissBytesAfterSwitch += shape.warmObjectCost
                            cache.insert(key, for: key, cost: shape.warmObjectCost)
                        }
                        if finalWindow {
                            finalWarmRequestBytes += shape.warmObjectCost
                            if hit { finalWarmHitBytes += shape.warmObjectCost }
                        }
                    } else {
                        beforeWarmRequestBytes += shape.warmObjectCost
                        if hit { beforeWarmHitBytes += shape.warmObjectCost }
                        else { cache.insert(key, for: key, cost: shape.warmObjectCost) }
                    }
                }
                if afterSwitch && serviceMissed { postWarmMissRounds.append(postRound) }
            }

            func secondRequest(_ key: Int) {
                let hit = cache.value(for: key) != nil
                if afterSwitch {
                    secondRequestBytesAfterSwitch += scanShape.objectCost
                    if hit { secondHitBytesAfterSwitch += scanShape.objectCost }
                    else { secondMissBytesAfterSwitch += scanShape.objectCost }
                }
                if !hit { cache.insert(key, for: key, cost: scanShape.objectCost) }
            }

            for _ in 0..<scanShape.objectsPerRound {
                let key = nextScanKey
                nextScanKey += 1
                cache.insert(key, for: key, cost: scanShape.objectCost)
                uniqueScanObjectClock += 1
                if gap == 0 {
                    secondRequest(key)
                } else {
                    scheduledSecondTouches[
                        uniqueScanObjectClock + gap,
                        default: []
                    ].append(key)
                }
                if let dueKeys = scheduledSecondTouches.removeValue(forKey: uniqueScanObjectClock) {
                    for due in dueKeys { secondRequest(due) }
                }
            }
        }

        return SIEVESecondTouchPhaseCase(
            residentShape: shape.name,
            topology: topology.rawValue,
            scanObjectCost: scanShape.objectCost,
            scanObjectsPerRound: scanShape.objectsPerRound,
            transition: transition.name,
            beforeGapObjects: transition.beforeGapObjects,
            afterGapObjects: transition.afterGapObjects,
            beforeRounds: beforeRounds,
            afterRounds: afterRounds,
            preSwitchCoreByteHitRatio: ratio(beforeCoreHitBytes, beforeCoreRequestBytes),
            preSwitchWarmByteHitRatio: ratio(beforeWarmHitBytes, beforeWarmRequestBytes),
            postSwitchCoreByteHitRatio: ratio(afterCoreHitBytes, afterCoreRequestBytes),
            postSwitchWarmByteHitRatio: ratio(afterWarmHitBytes, afterWarmRequestBytes),
            finalWindowCoreByteHitRatio: ratio(finalCoreHitBytes, finalCoreRequestBytes),
            finalWindowWarmByteHitRatio: ratio(finalWarmHitBytes, finalWarmRequestBytes),
            postSwitchCoreMissServiceRounds: postCoreMissRounds,
            postSwitchWarmMissServiceRounds: postWarmMissRounds,
            firstPostSwitchCoreMissRound: postCoreMissRounds.first,
            firstPostSwitchWarmMissRound: postWarmMissRounds.first,
            lastPostSwitchCoreMissRound: postCoreMissRounds.last,
            lastPostSwitchWarmMissRound: postWarmMissRounds.last,
            coreMissBytesAfterSwitch: coreMissBytesAfterSwitch,
            warmMissBytesAfterSwitch: warmMissBytesAfterSwitch,
            scanSecondRequestBytesAfterSwitch: secondRequestBytesAfterSwitch,
            scanSecondHitBytesAfterSwitch: secondHitBytesAfterSwitch,
            scanSecondMissBytesAfterSwitch: secondMissBytesAfterSwitch,
            scanSecondByteHitRatioAfterSwitch: ratio(
                secondHitBytesAfterSwitch,
                secondRequestBytesAfterSwitch
            ),
            finalCost: cache.currentCost,
            finalCount: cache.count
        )
    }

    private static func ratio(_ hitBytes: Int, _ requestBytes: Int) -> Double {
        Double(hitBytes) / Double(max(1, requestBytes))
    }

    private static func seedOrder(
        topology: SIEVESecondTouchPhaseTopology,
        fillerKeys: [Int],
        warmKeys: [Int],
        coreKeys: [Int]
    ) -> [Int] {
        let all = fillerKeys + warmKeys + coreKeys
        switch topology {
        case .fillerWarmCore:
            return all
        case .shuffle73:
            return shuffled(all, seed: 73)
        }
    }

    private static func shuffled(_ input: [Int], seed: UInt64) -> [Int] {
        var result = input
        var state = seed
        guard result.count > 1 else { return result }
        for upper in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let index = Int(state % UInt64(upper + 1))
            result.swapAt(upper, index)
        }
        return result
    }
}
