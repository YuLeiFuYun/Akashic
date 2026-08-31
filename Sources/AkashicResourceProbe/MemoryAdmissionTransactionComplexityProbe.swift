import AkashicMemory
import Foundation

struct AdmissionTransactionComplexityCase: Codable {
    let residentCount: Int
    let workload: String
    let incomingCost: Int
    let visitedCount: Int
    let provisionalCount: Int
    let victimCount: Int
    let revocationCount: Int
    let releasedCost: Int
    let epochResetCount: Int
    let inspectedSlotCount: Int
    let inspectedSlotsPerResident: Double
}

struct AdmissionTransactionValidationCase: Codable {
    let workload: String
    let evictionStateVersionChanged: Bool
    let accepted: Bool
    let validationMode: String
    let snapshotVictimCount: Int
    let finalResidentCount: Int
    let finalResidentCost: Int
}

struct AdmissionTransactionValidationScanCase: Codable {
    let residentCount: Int
    let interleaving: String
    let evictionStateVersionChanged: Bool
    let accepted: Bool
    let validationMode: String
    let victimSequenceStable: Bool
    let snapshotInspectedSlotCount: Int
    let currentPlanInspectedSlotCount: Int
    let validationInspectedSlotCount: Int
    let mutationClearedVisitedCount: Int
    let mutationVictimCount: Int
    let mutationEpochResetCount: Int
    let mutationCandidateInspectionCount: Int
    let totalStructuralInspectionCount: Int
}

struct AdmissionTransactionValidationBudgetCase: Codable {
    let residentCount: Int
    let interleaving: String
    let maximumValidationInspectedSlotCount: Int
    let snapshotVictimCount: Int
    let snapshotInspectedSlotCount: Int
    let accepted: Bool
    let validationMode: String
    let validationInspectedSlotCount: Int
    let originalVictimStillResident: Bool
    let incomingResident: Bool
    let finalResidentCount: Int
    let finalResidentCost: Int
}

struct AdmissionTransactionComplexityReport: Codable {
    let schemaVersion: Int
    let cases: [AdmissionTransactionComplexityCase]
    let validationCases: [AdmissionTransactionValidationCase]
    let validationScanCases: [AdmissionTransactionValidationScanCase]
    let validationBudgetCases: [AdmissionTransactionValidationBudgetCase]
    let checks: [String: Bool]
    let observations: [String: Bool]
    let claims: [String: Bool]
}
enum MemoryAdmissionTransactionComplexityProbe {
    static let sizes = [8, 32, 128, 512]

    static func run(arguments: [String]) throws {
        guard arguments.isEmpty else { throw ProbeError.invalidArguments }

        var rows: [AdmissionTransactionComplexityCase] = []
        for size in sizes {
            rows.append(try runCase(size: size, workload: "all-hot"))
            rows.append(try runCase(size: size, workload: "cold-prefix-hot-suffix"))
            rows.append(try runCase(size: size, workload: "alternating"))
            rows.append(try runCase(size: size, workload: "provisional-prefix"))
            rows.append(try runCase(size: size, workload: "tail-provisional"))
            rows.append(try runCase(size: size, workload: "near-two-pass-adversary"))
        }
        let validationCases = runValidationCases()
        let validationScanCases = try sizes.flatMap { size in
            [
                try runValidationScanCase(size: size, interleaving: "stable"),
                try runValidationScanCase(size: size, interleaving: "irrelevant-tail-hit"),
            ]
        }
        let validationBudgetCases = try sizes.flatMap { size in
            [
                try runValidationBudgetCase(size: size, interleaving: "irrelevant-tail-hit"),
                try runValidationBudgetCase(size: size, interleaving: "relevant-victim-hit"),
            ]
        }

        func cases(_ workload: String) -> [AdmissionTransactionComplexityCase] {
            rows.filter { $0.workload == workload }
        }

        let allHot = cases("all-hot")
        let coldPrefix = cases("cold-prefix-hot-suffix")
        let provisionalPrefix = cases("provisional-prefix")
        let tailProvisional = cases("tail-provisional")
        let nearTwoPass = cases("near-two-pass-adversary")
        let checks: [String: Bool] = [
            "all-cases-respect-two-revolution-bound": rows.allSatisfy {
                $0.inspectedSlotCount <= 2 * $0.residentCount
            },
            "all-hot-is-one-slot-independent-of-resident-count": allHot.allSatisfy {
                $0.victimCount == 1
                    && $0.epochResetCount == 1
                    && $0.inspectedSlotCount == 1
            },
            "cold-prefix-enters-reset-without-hot-suffix-scan": coldPrefix.allSatisfy {
                $0.inspectedSlotCount == $0.incomingCost
                    && $0.epochResetCount == 1
            },
            "provisional-prefix-revokes-exact-prefix-before-reset": provisionalPrefix.allSatisfy {
                $0.revocationCount == $0.provisionalCount
                    && $0.inspectedSlotCount == $0.incomingCost
                    && $0.epochResetCount == 1
            },
            "tail-provisional-forces-one-full-revolution-plus-one": tailProvisional.allSatisfy {
                $0.inspectedSlotCount == $0.residentCount + 1
                    && $0.revocationCount == 1
                    && $0.victimCount == 2
            },
            "adversary-approaches-two-revolutions": nearTwoPass.allSatisfy {
                $0.inspectedSlotCount == 2 * $0.residentCount - 1
                    && $0.victimCount == $0.residentCount
            },
            "unchanged-and-noop-state-use-version-fast-path":
                validationCases.filter {
                    $0.workload == "unchanged" || $0.workload == "noop-interleaving"
                }.allSatisfy {
                    $0.accepted
                        && !$0.evictionStateVersionChanged
                        && $0.validationMode == "versionFastPath"
                },
            "relevant-hit-falls-back-and-rejects": validationCases.first {
                $0.workload == "relevant-hit"
            }.map {
                !$0.accepted
                    && $0.evictionStateVersionChanged
                    && $0.validationMode == "exactStreaming"
            } ?? false,
            "irrelevant-hit-falls-back-but-still-accepts": validationCases.first {
                $0.workload == "irrelevant-hit"
            }.map {
                $0.accepted
                    && $0.evictionStateVersionChanged
                    && $0.validationMode == "exactStreaming"
            } ?? false,
            "long-prefix-scan-geometry-is-exact": validationScanCases.allSatisfy {
                $0.victimSequenceStable
                    && $0.snapshotInspectedSlotCount == $0.residentCount - 1
                    && $0.currentPlanInspectedSlotCount == $0.residentCount - 1
                    && $0.mutationEpochResetCount == 0
                    && $0.mutationCandidateInspectionCount == $0.residentCount - 1
            },
            "stable-long-prefix-uses-two-structural-traversals": validationScanCases
                .filter { $0.interleaving == "stable" }
                .allSatisfy {
                    $0.accepted
                        && !$0.evictionStateVersionChanged
                        && $0.validationMode == "versionFastPath"
                        && $0.validationInspectedSlotCount == 0
                        && $0.totalStructuralInspectionCount == 2 * $0.residentCount - 2
                },
            "irrelevant-tail-hit-adds-one-full-prefix-validation": validationScanCases
                .filter { $0.interleaving == "irrelevant-tail-hit" }
                .allSatisfy {
                    $0.accepted
                        && $0.evictionStateVersionChanged
                        && $0.validationMode == "exactStreaming"
                        && $0.validationInspectedSlotCount == $0.residentCount - 1
                        && $0.totalStructuralInspectionCount == 3 * $0.residentCount - 3
                },
            "bounded-tail-hit-still-accepts-within-one-slot": validationBudgetCases
                .filter { $0.interleaving == "irrelevant-tail-hit" }
                .allSatisfy {
                    $0.maximumValidationInspectedSlotCount == 1
                        && $0.snapshotVictimCount == 1
                        && $0.snapshotInspectedSlotCount == 1
                        && $0.accepted
                        && $0.validationMode == "exactStreaming"
                        && $0.validationInspectedSlotCount == 1
                        && !$0.originalVictimStillResident
                        && $0.incomingResident
                        && $0.finalResidentCount == $0.residentCount
                        && $0.finalResidentCost == $0.residentCount
                },
            "bounded-relevant-hit-stops-at-one-slot-without-mutation": validationBudgetCases
                .filter { $0.interleaving == "relevant-victim-hit" }
                .allSatisfy {
                    $0.maximumValidationInspectedSlotCount == 1
                        && $0.snapshotVictimCount == 1
                        && $0.snapshotInspectedSlotCount == 1
                        && !$0.accepted
                        && $0.validationMode == "validationLimited"
                        && $0.validationInspectedSlotCount == 1
                        && $0.originalVictimStillResident
                        && !$0.incomingResident
                        && $0.finalResidentCount == $0.residentCount
                        && $0.finalResidentCost == $0.residentCount
                },
        ]
        let observations: [String: Bool] = [
            "o-victim-fast-paths-do-not-grow-with-hot-suffix":
                allHot.allSatisfy { $0.inspectedSlotCount == 1 }
                    && zip(coldPrefix, coldPrefix.dropFirst()).allSatisfy { lhs, rhs in
                        rhs.inspectedSlotsPerResident < lhs.inspectedSlotsPerResident
                    },
            "provisional-position-can-turn-two-victim-decision-into-linear-scan":
                tailProvisional.allSatisfy {
                    $0.victimCount == 2
                        && $0.inspectedSlotCount > $0.residentCount
                },
            "exact-final-trace-still-has-near-two-n-worst-case": nearTwoPass.allSatisfy {
                $0.inspectedSlotCount >= 2 * $0.residentCount - 1
            },
            "version-token-removes-duplicate-commit-validation-only-when-state-is-stable":
                validationCases.contains {
                    $0.workload == "unchanged" && $0.validationMode == "versionFastPath"
                }
                    && validationCases.contains {
                        $0.workload == "irrelevant-hit"
                            && $0.validationMode == "exactStreaming"
                            && $0.accepted
                    },
            "structurally-irrelevant-tail-hit-can-turn-two-prefix-traversals-into-three":
                validationScanCases.filter { $0.interleaving == "irrelevant-tail-hit" }
                    .allSatisfy {
                        $0.validationInspectedSlotCount == $0.snapshotInspectedSlotCount
                            && $0.mutationCandidateInspectionCount
                                == $0.snapshotInspectedSlotCount
                    },
            "bounded-validation-budget-prevents-stale-rejection-scan-from-scaling-with-residents":
                validationBudgetCases.filter { $0.interleaving == "relevant-victim-hit" }
                    .allSatisfy { $0.validationInspectedSlotCount == 1 },
        ]

        let report = AdmissionTransactionComplexityReport(
            schemaVersion: 3,
            cases: rows,
            validationCases: validationCases,
            validationScanCases: validationScanCases,
            validationBudgetCases: validationBudgetCases,
            checks: checks,
            observations: observations,
            claims: [
                "formalPerformance": false,
                "productionPolicyRecommendation": false,
                "wallTimeLatency": false,
                "allocationFootprintQualified": false,
                "structuralLockWorkMechanism": true,
                "twoRevolutionUpperBound": true,
                "externalPolicyEvidenceLinearized": false,
                "exactStreamingValidationInspectionMechanism": true,
                "boundedCommitValidationMechanism": true,
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))

        guard checks.values.allSatisfy({ $0 }), observations.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }
}
