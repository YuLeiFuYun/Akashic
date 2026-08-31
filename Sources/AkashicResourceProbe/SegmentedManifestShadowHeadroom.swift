import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

struct SegmentedShadowHeadroomCase: Codable {
    let workload: String
    let payloadBytes: Int
    let frozenRuns: Int
    let currentRuns: Int
    let rebasedRuns: Int
    let frozenLiveEntries: Int
    let currentLiveEntries: Int
    let candidateBaseBytes: Int
    let oneRunBytes: Int
    let exactAfterRebase: Bool
    let preflightSixtyFifthRejectedBeforeWrite: Bool
    let naivePostWriteSixtyFifthRejected: Bool
    let naivePostWriteCreatesUnreferencedDebt: Bool
}

struct SegmentedShadowHeadroomReport: Codable {
    let schemaVersion: Int
    let capacityRuns: Int
    let cases: [SegmentedShadowHeadroomCase]
    let allCasesExact: Bool
    let tinyAndLargeRunBytesEqual: Bool
    let hotCandidateBaseIndependentOfPayloadBytes: Bool
    let distinctCandidateBaseIndependentOfPayloadBytes: Bool
    let preflightAdmissionAvoidsPhysicalDebt: Bool
    let naivePostWriteAdmissionCreatesPhysicalDebt: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionPolicy: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let fileBlobStoreAuthority: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func headroomShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        var cases: [SegmentedShadowHeadroomCase] = []
        for workload in ["hot-key", "all-distinct"] {
            for payloadBytes in [64, 1024 * 1024] {
                let caseRoot = root.appendingPathComponent(
                    "\(workload)-\(payloadBytes)",
                    isDirectory: true
                )
                try StorageDirectorySecurity.prepareDirectory(caseRoot)
                cases.append(
                    try runHeadroomCase(
                        root: caseRoot,
                        workload: workload,
                        payloadBytes: payloadBytes
                    )
                )
            }
        }

        let hot = cases.filter { $0.workload == "hot-key" }
        let distinct = cases.filter { $0.workload == "all-distinct" }
        let tinyAndLargeRunBytesEqual = Set(cases.map(\.oneRunBytes)).count == 1
        let hotCandidateBaseIndependentOfPayloadBytes = Set(hot.map(\.candidateBaseBytes)).count == 1
        let distinctCandidateBaseIndependentOfPayloadBytes = Set(distinct.map(\.candidateBaseBytes)).count == 1
        let preflightAdmissionAvoidsPhysicalDebt = cases.allSatisfy(\.preflightSixtyFifthRejectedBeforeWrite)
        let naivePostWriteAdmissionCreatesPhysicalDebt = cases.allSatisfy {
            $0.naivePostWriteSixtyFifthRejected && $0.naivePostWriteCreatesUnreferencedDebt
        }
        let allCasesExact = cases.allSatisfy(\.exactAfterRebase)
        guard allCasesExact,
            tinyAndLargeRunBytesEqual,
            hotCandidateBaseIndependentOfPayloadBytes,
            distinctCandidateBaseIndependentOfPayloadBytes,
            preflightAdmissionAvoidsPhysicalDebt,
            naivePostWriteAdmissionCreatesPhysicalDebt
        else { throw SegmentedManifestShadowError.invariantViolation }

        let report = SegmentedShadowHeadroomReport(
            schemaVersion: 1,
            capacityRuns: maximumRunDescriptors,
            cases: cases,
            allCasesExact: true,
            tinyAndLargeRunBytesEqual: true,
            hotCandidateBaseIndependentOfPayloadBytes: true,
            distinctCandidateBaseIndependentOfPayloadBytes: true,
            preflightAdmissionAvoidsPhysicalDebt: true,
            naivePostWriteAdmissionCreatesPhysicalDebt: true,
            claims: .init(
                productionPolicy: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false,
                fileBlobStoreAuthority: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func runHeadroomCase(
        root: URL,
        workload: String,
        payloadBytes: Int
    ) throws -> SegmentedShadowHeadroomCase {
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segmentDirectory)
        let baseEntry = try makeHeadroomEntry(
            workload: workload,
            payloadBytes: payloadBytes,
            index: -1
        )
        let baseEntries = [baseEntry]
        let base = try writeHeadroomBase(
            baseEntries,
            fileName: "base-headroom-origin.seg",
            directory: segmentDirectory
        )
        var state = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        var states: [[String: SegmentedShadowEntry]] = [state]
        var runs: [SegmentedShadowDescriptor] = []
        runs.reserveCapacity(maximumRunDescriptors)
        states.reserveCapacity(maximumRunDescriptors + 1)

        for index in 0 ..< maximumRunDescriptors {
            let mutation: SegmentedShadowMutation
            if workload == "hot-key" {
                let previous = state[baseEntry.key] ?? baseEntry
                mutation = .upsert(
                    SegmentedShadowEntry(
                        key: baseEntry.key,
                        physicalID: PhysicalBlobID(),
                        partition: baseEntry.partition,
                        digest: baseEntry.digest,
                        byteCount: baseEntry.byteCount,
                        lastAccess: previous.lastAccess.addingTimeInterval(1)
                    )
                )
            } else {
                mutation = .upsert(
                    try makeHeadroomEntry(
                        workload: workload,
                        payloadBytes: payloadBytes,
                        index: index
                    )
                )
            }
            let run = try writeHeadroomRun(
                [mutation],
                fileName: String(format: "run-headroom-%02d.seg", index),
                directory: segmentDirectory
            )
            runs.append(run)
            state = try apply([mutation], to: state)
            states.append(state)
        }

        let frozenRunCount = 48
        let frozenState = states[frozenRunCount]
        let currentState = states[maximumRunDescriptors]
        let frozen = try makeRoot(
            generation: 70,
            base: base,
            runs: Array(runs.prefix(frozenRunCount))
        )
        let current = try makeRoot(generation: 71, base: base, runs: runs)
        let candidateEntries = frozenState.values.sorted { $0.key < $1.key }
        let candidate = try writeHeadroomBase(
            candidateEntries,
            fileName: "base-headroom-candidate.seg",
            directory: segmentDirectory
        )
        let proof = try makeSemanticProof(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segmentDirectory
        )
        let rebased = try boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: proof,
            expectedCandidate: candidate
        )
        let recovered = try recoverHeadroomState(rebased, directory: segmentDirectory)
        let exactAfterRebase = recovered == currentState
            && rebased.runs.count == maximumRunDescriptors - frozenRunCount
        guard exactAfterRebase else { throw SegmentedManifestShadowError.invariantViolation }

        let preflightName = "run-headroom-preflight-64.seg"
        let preflightURL = segmentDirectory.appendingPathComponent(preflightName)
        let syntheticDescriptor = SegmentedShadowDescriptor(
            kind: .run,
            fileName: preflightName,
            byteCount: headerBytes + runRecordBytes,
            recordCount: 1,
            sha256: String(repeating: "a", count: 64)
        )
        var preflightRejected = false
        do {
            _ = try makeRoot(
                generation: 72,
                base: base,
                runs: runs + [syntheticDescriptor]
            )
        } catch {
            preflightRejected = !FileManager.default.fileExists(atPath: preflightURL.path)
        }
        guard preflightRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let extraMutation: SegmentedShadowMutation
        if workload == "hot-key" {
            extraMutation = .upsert(
                SegmentedShadowEntry(
                    key: baseEntry.key,
                    physicalID: PhysicalBlobID(),
                    partition: baseEntry.partition,
                    digest: baseEntry.digest,
                    byteCount: baseEntry.byteCount,
                    lastAccess: baseEntry.lastAccess.addingTimeInterval(1000)
                )
            )
        } else {
            extraMutation = .upsert(
                try makeHeadroomEntry(
                    workload: workload,
                    payloadBytes: payloadBytes,
                    index: maximumRunDescriptors
                )
            )
        }
        let extraRun = try writeHeadroomRun(
            [extraMutation],
            fileName: "run-headroom-naive-64.seg",
            directory: segmentDirectory
        )
        var naiveRejected = false
        do {
            _ = try makeRoot(generation: 72, base: base, runs: runs + [extraRun])
        } catch {
            naiveRejected = true
        }
        let naiveDebt = naiveRejected
            && FileManager.default.fileExists(
                atPath: segmentDirectory.appendingPathComponent(extraRun.fileName).path
            )
        guard naiveDebt else { throw SegmentedManifestShadowError.invariantViolation }
        try FileManager.default.removeItem(at: segmentDirectory.appendingPathComponent(extraRun.fileName))

        return SegmentedShadowHeadroomCase(
            workload: workload,
            payloadBytes: payloadBytes,
            frozenRuns: frozenRunCount,
            currentRuns: current.runs.count,
            rebasedRuns: rebased.runs.count,
            frozenLiveEntries: frozenState.count,
            currentLiveEntries: currentState.count,
            candidateBaseBytes: candidate.byteCount,
            oneRunBytes: runs[0].byteCount,
            exactAfterRebase: true,
            preflightSixtyFifthRejectedBeforeWrite: true,
            naivePostWriteSixtyFifthRejected: true,
            naivePostWriteCreatesUnreferencedDebt: true
        )
    }

    private static func makeHeadroomEntry(
        workload: String,
        payloadBytes: Int,
        index: Int
    ) throws -> SegmentedShadowEntry {
        let material = Data("\(workload)-\(payloadBytes)-\(index)".utf8)
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-headroom-v1",
            material: material
        )
        let fill = UInt8(truncatingIfNeeded: index &+ 129)
        let payload = Data(repeating: fill, count: payloadBytes)
        let digest = BlobDigest.sha256(of: payload)
        return SegmentedShadowEntry(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            physicalID: PhysicalBlobID(),
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 980_000_000 + Double(index + 1))
        )
    }

    private static func writeHeadroomBase(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    private static func writeHeadroomRun(
        _ mutations: [SegmentedShadowMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: url)
        return try descriptor(.run, url: url, expectedRecords: mutations.count)
    }

    private static func recoverHeadroomState(
        _ root: SegmentedShadowRoot,
        directory: URL
    ) throws -> [String: SegmentedShadowEntry] {
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        var state = Dictionary(uniqueKeysWithValues: try readBase(root.base, directory: directory).map { ($0.key, $0) })
        for run in root.runs {
            state = try apply(try readRun(run, directory: directory), to: state)
        }
        return state
    }
}
