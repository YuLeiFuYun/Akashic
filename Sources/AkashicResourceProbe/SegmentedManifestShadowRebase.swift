import AkashicCore
import AkashicDisk
import Foundation

struct SegmentedShadowRebaseReport: Codable {
    let schemaVersion: Int
    let noSuffixExact: Bool
    let disjointSuffixPreserved: Bool
    let sameKeyTombstoneDominates: Bool
    let sameKeyPhysicalRepairDominates: Bool
    let ownershipConflictRejected: Bool
    let divergentBaseRejected: Bool
    let divergentPrefixRejected: Bool
    let runLimitRebasePreservesState: Bool
    let runLimitBeforeRebase: Int
    let runLimitAfterRebase: Int
    let sixtyFifthRunRejected: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let fileBlobStoreAuthority: Bool
        let publicationAlgorithmQualified: Bool
        let automaticMigration: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func rebaseShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segmentDirectory)

        let baseEntries = try makeBaseEntries(count: 128)
        let baseState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let base = try writeBaseSegment(
            baseEntries,
            fileName: "base-rebase-origin.seg",
            directory: segmentDirectory
        )
        let frozenMutations = try makeRunMutations(base: baseEntries, count: 32)
        let frozenRun = try writeRunSegment(
            frozenMutations,
            fileName: "run-rebase-frozen.seg",
            directory: segmentDirectory
        )
        let frozenState = try apply(frozenMutations, to: baseState)
        let frozenRoot = try makeRoot(generation: 20, base: base, runs: [frozenRun])
        let candidateBase = try writeBaseSegment(
            frozenState.values.sorted { $0.key < $1.key },
            fileName: "base-rebase-candidate.seg",
            directory: segmentDirectory
        )

        let noSuffixRoot = try makeRebasedRoot(
            frozen: frozenRoot,
            current: frozenRoot,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        let noSuffixExact = try recoverState(
            noSuffixRoot,
            segmentDirectory: segmentDirectory
        ) == frozenState
        guard noSuffixExact else { throw SegmentedManifestShadowError.invariantViolation }

        let disjointEntry = try makeRebaseEntry(label: "disjoint-create")
        let disjointRun = try writeRunSegment(
            [.upsert(disjointEntry)],
            fileName: "run-rebase-disjoint.seg",
            directory: segmentDirectory
        )
        let disjointCurrent = try makeRoot(
            generation: 21,
            base: base,
            runs: [frozenRun, disjointRun]
        )
        let disjointExpected = try apply([.upsert(disjointEntry)], to: frozenState)
        let disjointRebased = try makeRebasedRoot(
            frozen: frozenRoot,
            current: disjointCurrent,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        let disjointSuffixPreserved = try recoverState(
            disjointRebased,
            segmentDirectory: segmentDirectory
        ) == disjointExpected
        guard disjointSuffixPreserved else { throw SegmentedManifestShadowError.invariantViolation }

        guard let tombstoneSource = frozenState.values.sorted(by: { $0.key < $1.key }).first else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let tombstoneMutation = SegmentedShadowMutation.tombstone(key: tombstoneSource.key)
        let tombstoneRun = try writeRunSegment(
            [tombstoneMutation],
            fileName: "run-rebase-tombstone.seg",
            directory: segmentDirectory
        )
        let tombstoneCurrent = try makeRoot(
            generation: 21,
            base: base,
            runs: [frozenRun, tombstoneRun]
        )
        let tombstoneExpected = try apply([tombstoneMutation], to: frozenState)
        let tombstoneRebased = try makeRebasedRoot(
            frozen: frozenRoot,
            current: tombstoneCurrent,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        let tombstoneRecovered = try recoverState(tombstoneRebased, segmentDirectory: segmentDirectory)
        let sameKeyTombstoneDominates = tombstoneRecovered == tombstoneExpected
            && tombstoneRecovered[tombstoneSource.key] == nil
        guard sameKeyTombstoneDominates else { throw SegmentedManifestShadowError.invariantViolation }

        guard let repairSource = frozenState.values.sorted(by: { $0.key < $1.key }).dropFirst().first else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let repaired = SegmentedShadowEntry(
            key: repairSource.key,
            physicalID: PhysicalBlobID(),
            partition: repairSource.partition,
            digest: repairSource.digest,
            byteCount: repairSource.byteCount,
            lastAccess: repairSource.lastAccess.addingTimeInterval(1)
        )
        let repairMutation = SegmentedShadowMutation.upsert(repaired)
        let repairRun = try writeRunSegment(
            [repairMutation],
            fileName: "run-rebase-repair.seg",
            directory: segmentDirectory
        )
        let repairCurrent = try makeRoot(
            generation: 21,
            base: base,
            runs: [frozenRun, repairRun]
        )
        let repairExpected = try apply([repairMutation], to: frozenState)
        let repairRebased = try makeRebasedRoot(
            frozen: frozenRoot,
            current: repairCurrent,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        let repairRecovered = try recoverState(repairRebased, segmentDirectory: segmentDirectory)
        let sameKeyPhysicalRepairDominates = repairRecovered == repairExpected
            && repairRecovered[repairSource.key]?.physicalID == repaired.physicalID
        guard sameKeyPhysicalRepairDominates else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        guard let retainedPhysicalID = frozenState.values.first?.physicalID else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let conflictEntry = try makeRebaseEntry(
            label: "ownership-conflict",
            physicalID: retainedPhysicalID
        )
        let conflictRun = try writeRunSegment(
            [.upsert(conflictEntry)],
            fileName: "run-rebase-conflict.seg",
            directory: segmentDirectory
        )
        let conflictCurrent = try makeRoot(
            generation: 21,
            base: base,
            runs: [frozenRun, conflictRun]
        )
        var ownershipConflictRejected = false
        do {
            _ = try makeRebasedRoot(
                frozen: frozenRoot,
                current: conflictCurrent,
                candidateBase: candidateBase,
                segmentDirectory: segmentDirectory
            )
        } catch {
            ownershipConflictRejected = true
        }
        guard ownershipConflictRejected else { throw SegmentedManifestShadowError.invariantViolation }

        var alternateBaseEntries = baseEntries
        let changed = alternateBaseEntries[0]
        alternateBaseEntries[0] = SegmentedShadowEntry(
            key: changed.key,
            physicalID: PhysicalBlobID(),
            partition: changed.partition,
            digest: changed.digest,
            byteCount: changed.byteCount,
            lastAccess: changed.lastAccess
        )
        let alternateBase = try writeBaseSegment(
            alternateBaseEntries,
            fileName: "base-rebase-diverged.seg",
            directory: segmentDirectory
        )
        let divergentBaseRoot = try makeRoot(
            generation: 21,
            base: alternateBase,
            runs: [frozenRun]
        )
        let divergentBaseRejected = rejectsRebase(
            frozen: frozenRoot,
            current: divergentBaseRoot,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        guard divergentBaseRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let divergentMutation = SegmentedShadowMutation.upsert(try makeRebaseEntry(label: "prefix-diverged"))
        let divergentRun = try writeRunSegment(
            [divergentMutation],
            fileName: "run-rebase-prefix-diverged.seg",
            directory: segmentDirectory
        )
        let divergentPrefixRoot = try makeRoot(
            generation: 21,
            base: base,
            runs: [divergentRun]
        )
        let divergentPrefixRejected = rejectsRebase(
            frozen: frozenRoot,
            current: divergentPrefixRoot,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        guard divergentPrefixRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let limitResult = try runLimitRebaseScenario(
            base: base,
            baseState: baseState,
            segmentDirectory: segmentDirectory
        )

        let report = SegmentedShadowRebaseReport(
            schemaVersion: 1,
            noSuffixExact: true,
            disjointSuffixPreserved: true,
            sameKeyTombstoneDominates: true,
            sameKeyPhysicalRepairDominates: true,
            ownershipConflictRejected: true,
            divergentBaseRejected: true,
            divergentPrefixRejected: true,
            runLimitRebasePreservesState: limitResult.preservesState,
            runLimitBeforeRebase: limitResult.before,
            runLimitAfterRebase: limitResult.after,
            sixtyFifthRunRejected: limitResult.sixtyFifthRejected,
            claims: .init(
                productionFormat: false,
                fileBlobStoreAuthority: false,
                publicationAlgorithmQualified: false,
                automaticMigration: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func makeRebasedRoot(
        frozen: SegmentedShadowRoot,
        current: SegmentedShadowRoot,
        candidateBase: SegmentedShadowDescriptor,
        segmentDirectory: URL
    ) throws -> SegmentedShadowRoot {
        guard try rootExtends(current, frozen: frozen), candidateBase.kind == .base else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let nextGeneration = current.generation.addingReportingOverflow(1)
        guard !nextGeneration.overflow else { throw SegmentedManifestShadowError.invalidFormat }
        let suffix = Array(current.runs.dropFirst(frozen.runs.count))
        let proposed = try makeRoot(
            generation: nextGeneration.partialValue,
            base: candidateBase,
            runs: suffix
        )
        // This full replay is an adversarial oracle, not a proposed foreground algorithm. A
        // production design must replace it with a bounded proof that the background candidate is
        // exactly the frozen state and that the already-authoritative suffix remains valid.
        _ = try recoverState(proposed, segmentDirectory: segmentDirectory)
        return proposed
    }

    private static func rootExtends(
        _ current: SegmentedShadowRoot,
        frozen: SegmentedShadowRoot
    ) throws -> Bool {
        guard try validateRootSeal(current),
            try validateRootSeal(frozen),
            current.generation >= frozen.generation,
            current.base == frozen.base,
            current.runs.count >= frozen.runs.count
        else { return false }
        return Array(current.runs.prefix(frozen.runs.count)) == frozen.runs
    }

    private static func recoverState(
        _ root: SegmentedShadowRoot,
        segmentDirectory: URL
    ) throws -> [String: SegmentedShadowEntry] {
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        var state = Dictionary(
            uniqueKeysWithValues: try readBase(root.base, directory: segmentDirectory).map { ($0.key, $0) }
        )
        for descriptor in root.runs {
            state = try apply(try readRun(descriptor, directory: segmentDirectory), to: state)
        }
        return state
    }

    private static func rejectsRebase(
        frozen: SegmentedShadowRoot,
        current: SegmentedShadowRoot,
        candidateBase: SegmentedShadowDescriptor,
        segmentDirectory: URL
    ) -> Bool {
        do {
            _ = try makeRebasedRoot(
                frozen: frozen,
                current: current,
                candidateBase: candidateBase,
                segmentDirectory: segmentDirectory
            )
            return false
        } catch {
            return true
        }
    }

    private static func writeBaseSegment(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    private static func writeRunSegment(
        _ mutations: [SegmentedShadowMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: url)
        return try descriptor(.run, url: url, expectedRecords: mutations.count)
    }

    private static func makeRebaseEntry(
        label: String,
        physicalID: PhysicalBlobID = PhysicalBlobID()
    ) throws -> SegmentedShadowEntry {
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-rebase-v1",
            material: Data(label.utf8)
        )
        let payload = Data("segment-rebase-\(label)".utf8)
        let digest = BlobDigest.sha256(of: payload)
        return SegmentedShadowEntry(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            physicalID: physicalID,
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 950_000_000)
        )
    }

    private static func runLimitRebaseScenario(
        base: SegmentedShadowDescriptor,
        baseState: [String: SegmentedShadowEntry],
        segmentDirectory: URL
    ) throws -> (preservesState: Bool, before: Int, after: Int, sixtyFifthRejected: Bool) {
        var runs: [SegmentedShadowDescriptor] = []
        var states: [[String: SegmentedShadowEntry]] = [baseState]
        runs.reserveCapacity(maximumRunDescriptors + 1)
        states.reserveCapacity(maximumRunDescriptors + 1)
        for index in 0 ..< maximumRunDescriptors {
            let entry = try makeRebaseEntry(label: "limit-\(index)")
            let mutation = SegmentedShadowMutation.upsert(entry)
            let run = try writeRunSegment(
                [mutation],
                fileName: String(format: "run-limit-%02d.seg", index),
                directory: segmentDirectory
            )
            runs.append(run)
            states.append(try apply([mutation], to: states.last!))
        }
        let frozenRunCount = maximumRunDescriptors - 4
        let frozenRuns = Array(runs.prefix(frozenRunCount))
        let frozenState = states[frozenRunCount]
        let currentState = states[maximumRunDescriptors]
        let frozen = try makeRoot(generation: 30, base: base, runs: frozenRuns)
        let current = try makeRoot(generation: 31, base: base, runs: runs)
        let candidateBase = try writeBaseSegment(
            frozenState.values.sorted { $0.key < $1.key },
            fileName: "base-limit-compacted.seg",
            directory: segmentDirectory
        )
        let rebased = try makeRebasedRoot(
            frozen: frozen,
            current: current,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        let recovered = try recoverState(rebased, segmentDirectory: segmentDirectory)
        let preservesState = recovered == currentState && rebased.runs.count == 4
        guard preservesState else { throw SegmentedManifestShadowError.invariantViolation }

        let extraEntry = try makeRebaseEntry(label: "limit-64")
        let extraRun = try writeRunSegment(
            [.upsert(extraEntry)],
            fileName: "run-limit-64.seg",
            directory: segmentDirectory
        )
        var sixtyFifthRejected = false
        do {
            _ = try makeRoot(generation: 32, base: base, runs: runs + [extraRun])
        } catch {
            sixtyFifthRejected = true
        }
        guard sixtyFifthRejected else { throw SegmentedManifestShadowError.invariantViolation }
        return (
            preservesState: true,
            before: current.runs.count,
            after: rebased.runs.count,
            sixtyFifthRejected: true
        )
    }
}
