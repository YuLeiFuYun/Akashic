import AkashicMemory
import Foundation

extension MemoryAdmissionCompetitionProbe {
    static func runFutureArrivalOracle(workloads: [String]) throws {
        guard !workloads.isEmpty, Set(workloads).count == workloads.count else {
            throw ProbeError.resourceSampleFailed
        }

        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            let policy = FutureArrivalOracleCompetitionPolicy(
                limit: costLimit,
                windowLimit: windowLimit
            )
            policy.prepare(requests: trace.requests)
            policy.seed(trace.seed)
            results.append(
                run(policy: policy, workload: workload, requests: trace.requests)
            )
        }

        let checks: [String: Bool] = [
            "all-resident-bounds-preserved": results.allSatisfy {
                $0.maximumResidentCost <= costLimit
            },
            "all-oracle-future-state-consumed": results.allSatisfy {
                $0.metadataBytes == 0
            },
            "all-results-are-future-arrival-oracle": results.allSatisfy {
                $0.policy == "future-arrival-oracle-byte"
            },
        ]
        let report = AdmissionCompetitionReport(
            schemaVersion: 4,
            costLimit: costLimit,
            windowLimit: windowLimit,
            workloads: workloads,
            policies: ["future-arrival-oracle-byte"],
            results: results,
            comparisonsAgainstBaseline: [],
            collisions: [],
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    static func runFutureArrivalNoStaleVisitOracle(workloads: [String]) throws {
        guard !workloads.isEmpty, Set(workloads).count == workloads.count else {
            throw ProbeError.resourceSampleFailed
        }

        let policyName = "future-arrival-no-stale-visit-oracle-byte"
        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            let policy = FutureArrivalOracleCompetitionPolicy(
                limit: costLimit,
                windowLimit: windowLimit,
                suppressFinalVisit: true
            )
            policy.prepare(requests: trace.requests)
            policy.seed(trace.seed)
            results.append(
                run(policy: policy, workload: workload, requests: trace.requests)
            )
        }

        let checks: [String: Bool] = [
            "all-resident-bounds-preserved": results.allSatisfy {
                $0.maximumResidentCost <= costLimit
            },
            "all-oracle-future-state-consumed": results.allSatisfy {
                $0.metadataBytes == 0
            },
            "all-results-are-future-arrival-no-stale-visit-oracle": results.allSatisfy {
                $0.policy == policyName
            },
        ]
        let report = AdmissionCompetitionReport(
            schemaVersion: 5,
            costLimit: costLimit,
            windowLimit: windowLimit,
            workloads: workloads,
            policies: [policyName],
            results: results,
            comparisonsAgainstBaseline: [],
            collisions: [],
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    static func runExpiringSecondHitFrontier(workloads: [String]) throws {
        guard !workloads.isEmpty, Set(workloads).count == workloads.count else {
            throw ProbeError.resourceSampleFailed
        }

        let budgets = [64, 128, 256]
        let pressureTTLs = [32, 64, 128, 256, 512, 1_024, 2_048, 4_096]
        var factories: [(name: String, budget: Int, make: () -> AdmissionCompetitionPolicy)] = []
        for budget in budgets {
            for pressureTTL in pressureTTLs {
                let name = "expiring-second-hit-b\(budget)-p\(pressureTTL)"
                factories.append((
                    name: name,
                    budget: budget,
                    make: {
                        ExpiringSecondHitCompetitionPolicy(
                            limit: costLimit,
                            secondHitBudget: budget,
                            pressureTTL: pressureTTL
                        )
                    }
                ))
            }
        }

        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            for factory in factories {
                let policy = factory.make()
                policy.seed(trace.seed)
                results.append(
                    run(policy: policy, workload: workload, requests: trace.requests)
                )
            }
        }
        let budgetByPolicy = Dictionary(
            uniqueKeysWithValues: factories.map { ($0.name, $0.budget) }
        )
        let checks: [String: Bool] = [
            "all-resident-bounds-preserved": results.allSatisfy {
                $0.maximumResidentCost <= costLimit
            },
            "all-second-hit-protection-budgets-preserved": results.allSatisfy { result in
                guard let budget = budgetByPolicy[result.policy] else { return false }
                return result.maximumProtectedSecondHitBytes <= budget
            },
            "all-results-are-expiring-second-hit-policies": results.allSatisfy {
                budgetByPolicy[$0.policy] != nil
            },
        ]
        let report = AdmissionCompetitionReport(
            schemaVersion: 6,
            costLimit: costLimit,
            windowLimit: 0,
            workloads: workloads,
            policies: factories.map(\.name),
            results: results,
            comparisonsAgainstBaseline: [],
            collisions: [],
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    static func runPhysicalExpirySecondHitFrontier(workloads: [String]) throws {
        guard !workloads.isEmpty, Set(workloads).count == workloads.count else {
            throw ProbeError.resourceSampleFailed
        }

        let budgets = [64, 128, 256]
        // p4 expires before the first 4-byte miss can consume the provisional visited bit;
        // p8 is the first boundary immediately after that hand encounter in the unit-pressure
        // witness. Wider values test whether any apparent benefit is a phase artifact.
        let pressureTTLs = [4, 8, 16, 32, 64, 128, 256, 448, 452, 456, 460, 512]
        var factories: [(
            name: String,
            budget: Int?,
            make: () -> AdmissionCompetitionPolicy
        )] = [
            (
                name: "delayed-promotion-1",
                budget: nil,
                make: { DelayedPromotionCompetitionPolicy(limit: costLimit) }
            )
        ]
        for budget in budgets {
            factories.append((
                name: "budgeted-second-hit-b\(budget)",
                budget: budget,
                make: {
                    BudgetedSecondHitCompetitionPolicy(
                        limit: costLimit,
                        secondHitBudget: budget
                    )
                }
            ))
            for pressureTTL in pressureTTLs {
                factories.append((
                    name: "expiring-second-hit-b\(budget)-p\(pressureTTL)",
                    budget: budget,
                    make: {
                        ExpiringSecondHitCompetitionPolicy(
                            limit: costLimit,
                            secondHitBudget: budget,
                            pressureTTL: pressureTTL
                        )
                    }
                ))
                factories.append((
                    name: "physical-expiring-second-hit-b\(budget)-p\(pressureTTL)",
                    budget: budget,
                    make: {
                        PhysicalExpirySecondHitCompetitionPolicy(
                            limit: costLimit,
                            secondHitBudget: budget,
                            pressureTTL: pressureTTL
                        )
                    }
                ))
            }
        }

        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            for factory in factories {
                let policy = factory.make()
                policy.seed(trace.seed)
                results.append(
                    run(policy: policy, workload: workload, requests: trace.requests)
                )
            }
        }
        let budgetByPolicy = Dictionary(
            uniqueKeysWithValues: factories.compactMap { factory in
                factory.budget.map { (factory.name, $0) }
            }
        )
        let physicalResults = results.filter {
            $0.policy.hasPrefix("physical-expiring-second-hit-")
        }
        let bitExpiryResults = results.filter {
            $0.policy.hasPrefix("expiring-second-hit-")
        }
        let expectedExpiringPolicyCount = budgets.count * pressureTTLs.count
        let checks: [String: Bool] = [
            "all-resident-bounds-preserved": results.allSatisfy {
                $0.maximumResidentCost <= costLimit
            },
            "all-second-hit-protection-budgets-preserved": results.allSatisfy { result in
                guard let budget = budgetByPolicy[result.policy] else { return true }
                return result.maximumProtectedSecondHitBytes <= budget
            },
            "all-physical-expiry-policies-reported": Set(physicalResults.map(\.policy)).count
                == expectedExpiringPolicyCount,
            "all-bit-expiry-controls-reported": Set(bitExpiryResults.map(\.policy)).count
                == expectedExpiringPolicyCount,
            "physical-expiry-revocations-are-nonnegative": physicalResults.allSatisfy {
                $0.provisionalRevocations >= 0
            },
        ]
        let report = AdmissionCompetitionReport(
            schemaVersion: 9,
            costLimit: costLimit,
            windowLimit: 0,
            workloads: workloads,
            policies: factories.map(\.name),
            results: results,
            comparisonsAgainstBaseline: [],
            collisions: [],
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }

    static func runHandRevokedSecondHitFrontier(workloads: [String]) throws {
        guard !workloads.isEmpty, Set(workloads).count == workloads.count else {
            throw ProbeError.resourceSampleFailed
        }

        let budgets = [64, 128, 256, 512]
        let factories: [(name: String, budget: Int?, make: () -> AdmissionCompetitionPolicy)] = [
            ("delayed-promotion-1", nil, {
                DelayedPromotionCompetitionPolicy(limit: costLimit)
            }),
            ("budgeted-second-hit-b64", 64, {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 64)
            }),
            ("budgeted-second-hit-b128", 128, {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 128)
            }),
            ("budgeted-second-hit-b256", 256, {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 256)
            }),
            ("budgeted-second-hit-b512", 512, {
                BudgetedSecondHitCompetitionPolicy(limit: costLimit, secondHitBudget: 512)
            }),
            ("density-capped-second-hit-b512-r4", 512, {
                DensityCappedSecondHitCompetitionPolicy(
                    limit: costLimit,
                    secondHitBudget: 512,
                    unvisitedReserve: 4
                )
            }),
            ("density-capped-second-hit-b512-r64", 512, {
                DensityCappedSecondHitCompetitionPolicy(
                    limit: costLimit,
                    secondHitBudget: 512,
                    unvisitedReserve: 64
                )
            }),
            ("density-capped-second-hit-b512-r128", 512, {
                DensityCappedSecondHitCompetitionPolicy(
                    limit: costLimit,
                    secondHitBudget: 512,
                    unvisitedReserve: 128
                )
            }),
            ("density-capped-second-hit-b512-r256", 512, {
                DensityCappedSecondHitCompetitionPolicy(
                    limit: costLimit,
                    secondHitBudget: 512,
                    unvisitedReserve: 256
                )
            }),
        ] + budgets.map { budget in
            (
                name: "hand-revoked-second-hit-b\(budget)",
                budget: Optional(budget),
                make: {
                    HandRevokedSecondHitCompetitionPolicy(
                        limit: costLimit,
                        secondHitBudget: budget
                    ) as AdmissionCompetitionPolicy
                }
            )
        } + budgets.map { budget in
            (
                name: "hand-fixedpoint-revoked-second-hit-b\(budget)",
                budget: Optional(budget),
                make: {
                    FixedPointHandRevokedSecondHitCompetitionPolicy(
                        limit: costLimit,
                        secondHitBudget: budget
                    ) as AdmissionCompetitionPolicy
                }
            )
        }

        var results: [AdmissionCompetitionPolicyResult] = []
        for workload in workloads {
            let trace = makeTrace(workload)
            for factory in factories {
                let policy = factory.make()
                policy.seed(trace.seed)
                results.append(
                    run(policy: policy, workload: workload, requests: trace.requests)
                )
            }
        }

        let budgetByPolicy = Dictionary(
            uniqueKeysWithValues: factories.compactMap { factory in
                factory.budget.map { (factory.name, $0) }
            }
        )
        let handPrefix = "hand-revoked-second-hit-b"
        let fixedPointPrefix = "hand-fixedpoint-revoked-second-hit-b"
        let handResults = results.filter { $0.policy.hasPrefix(handPrefix) }
        let fixedPointResults = results.filter { $0.policy.hasPrefix(fixedPointPrefix) }
        let checks: [String: Bool] = [
            "all-resident-bounds-preserved": results.allSatisfy {
                $0.maximumResidentCost <= costLimit
            },
            "all-budgeted-protection-bounds-preserved": results.allSatisfy { result in
                guard let budget = budgetByPolicy[result.policy] else { return true }
                return result.maximumProtectedSecondHitBytes <= budget
            },
            "all-hand-policies-reported": Set(handResults.map(\.policy)) == Set(
                budgets.map { "hand-revoked-second-hit-b\($0)" }
            ),
            "all-fixedpoint-hand-policies-reported": Set(fixedPointResults.map(\.policy)) == Set(
                budgets.map { "hand-fixedpoint-revoked-second-hit-b\($0)" }
            ),
            "hand-revocations-never-exceed-granted-events": handResults.allSatisfy {
                $0.provisionalRevocations >= 0 && $0.provisionalConfirmations >= 0
            },
            "fixedpoint-revocations-never-exceed-granted-events": fixedPointResults.allSatisfy {
                $0.provisionalRevocations >= 0 && $0.provisionalConfirmations >= 0
            },
        ]
        let report = AdmissionCompetitionReport(
            schemaVersion: 8,
            costLimit: costLimit,
            windowLimit: 0,
            workloads: workloads,
            policies: factories.map(\.name),
            results: results,
            comparisonsAgainstBaseline: [],
            collisions: [],
            checks: checks,
            claims: .init(
                productionPolicyRecommendation: false,
                formalPerformance: false,
                memoryFootprintQualified: false,
                shardedConcurrencyQualified: false,
                diskSemantics: false,
                authoritySemantics: false,
                physicalDedupSemantics: false,
                foveaBusinessSemantics: false
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard checks.values.allSatisfy({ $0 }) else {
            throw ProbeError.resourceSampleFailed
        }
    }
}
