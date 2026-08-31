import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct Schema5CompactionForegroundIdentity: Sendable {
    let data: Data
    let digest: BlobDigest
    let partition: CachePartitionID
}

extension SegmentedManifestShadowProbe {
    static func schema5CompactionResource(arguments: [String]) async throws {
        let parsed = try schema5CompactionResourceArguments(arguments)
        var seeded: Schema5CompactionResourceSeedResult? = try await schema5CompactionResourceSeed(
            root: parsed.root,
            profile: parsed.profile,
            liveCount: parsed.liveEntries,
            runCount: parsed.runCount,
            recordsPerRun: parsed.recordsPerRun,
            history: parsed.history
        )
        var store: FileBlobStore? = seeded!.store
        let frozenRoot = seeded!.root
        let frozenSegmentStats = try schema5CompactionResourceSegmentStats(root: parsed.root)
        let frozenRootBytes = try SegmentedManifestPrototypeV1.encodeRoot(frozenRoot).count
        let frozenBaseBytes = seeded!.baseBytes
        let frozenRunBytes = seeded!.runBytes
        let replayRecords = seeded!.replayRecords
        let frozenIdentityCommitment = seeded!.expectedCommitment
        seeded = nil

        let hotIdentity: Schema5CompactionForegroundIdentity?
        let checkpointIdentities: [Schema5CompactionForegroundIdentity]
        switch parsed.workload {
        case "hot":
            let identity = try schema5CompactionForegroundIdentity(
                index: parsed.liveEntries + 1_000_000,
                byteCount: parsed.foregroundPayloadBytes,
                fill: 0x68
            )
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
            hotIdentity = identity
            checkpointIdentities = []
        case "checkpoint":
            hotIdentity = nil
            checkpointIdentities = try (0..<512).map { index in
                try schema5CompactionForegroundIdentity(
                    index: parsed.liveEntries + 1_100_000 + index,
                    byteCount: parsed.foregroundPayloadBytes,
                    fill: UInt8(truncatingIfNeeded: 0x40 + index)
                )
            }
        default:
            throw SegmentedManifestShadowError.invalidArguments
        }

        let preMeasurementRoot = try schema5CompactionResourceReadRoot(parsed.root)
        guard preMeasurementRoot == frozenRoot else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        try parsed.barrier.enter()
        let measured = try await schema5CompactionResourceMeasuredPhase(
            store: store!,
            root: parsed.root,
            profile: parsed.profile,
            mode: parsed.mode,
            workload: parsed.workload,
            hotIdentity: hotIdentity,
            checkpointIdentities: checkpointIdentities
        )
        try parsed.barrier.leave()

        let actorCommitment = try schema5IdentityCommitment(measured.finalActorSnapshot.entries)
        let actorLogicalAuthorityCommitment = try schema5CompactionLogicalAuthorityCommitment(
            measured.finalActorSnapshot.entries
        )
        let actorEntryCount = measured.finalActorSnapshot.entries.count
        store = nil
        let reopened = try await schema5CompactionResourceOpen(
            root: parsed.root,
            profile: parsed.profile
        )
        let reopenedSnapshot = await reopened.resourceProbeManifestShadowSnapshot()
        let reopenedCommitment = try schema5IdentityCommitment(reopenedSnapshot.entries)
        let reopenedLogicalAuthorityCommitment = try schema5CompactionLogicalAuthorityCommitment(
            reopenedSnapshot.entries
        )
        let freshReopenExact = reopenedSnapshot.entries == measured.finalActorSnapshot.entries
            && reopenedCommitment == actorCommitment
            && reopenedLogicalAuthorityCommitment == actorLogicalAuthorityCommitment
        guard freshReopenExact else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let preparationNanoseconds: UInt64?
        let totalCompactionNanoseconds: UInt64?
        let overlapNanoseconds: UInt64?
        if let started = measured.compactionStartedAt,
            let verified = measured.candidateVerifiedAt,
            let ended = measured.compactionEndedAt
        {
            preparationNanoseconds = verified &- started
            totalCompactionNanoseconds = ended &- started
            let overlapStart = max(started, measured.foregroundStartedAt)
            let overlapEnd = min(verified, measured.foregroundEndedAt)
            overlapNanoseconds = overlapEnd > overlapStart ? overlapEnd - overlapStart : 0
        } else {
            preparationNanoseconds = nil
            totalCompactionNanoseconds = nil
            overlapNanoseconds = nil
        }

        let report = Schema5CompactionResourceCaseReport(
            schemaVersion: 1,
            profile: parsed.profile.rawValue,
            mode: parsed.mode,
            liveEntries: parsed.liveEntries,
            frozenRunCount: parsed.runCount,
            recordsPerRun: parsed.recordsPerRun,
            replayRecords: replayRecords,
            history: parsed.history,
            workload: parsed.workload,
            foregroundPayloadBytes: parsed.foregroundPayloadBytes,
            frozenBaseBytes: frozenBaseBytes,
            frozenRunBytes: frozenRunBytes,
            frozenRootBytes: frozenRootBytes,
            frozenSegmentStats: frozenSegmentStats,
            pausedSegmentStats: measured.pausedSegmentStats,
            finalSegmentStats: measured.finalSegmentStats,
            finalRootRunCount: measured.finalRootRunCount,
            finalRootBytes: measured.finalRootBytes,
            finalBaseBytes: measured.finalBaseBytes,
            foregroundOperationNanoseconds: measured.foregroundOperationNanoseconds,
            foregroundElapsedNanoseconds: measured.foregroundEndedAt &- measured.foregroundStartedAt,
            checkpointNanoseconds: measured.checkpointNanoseconds,
            capacityBackpressureObserved: measured.capacityBackpressureObserved,
            postCompactionRetryNanoseconds: measured.postCompactionRetryNanoseconds,
            compactionPublished: measured.compactionPublished,
            compactionPreparationNanoseconds: preparationNanoseconds,
            compactionTotalNanoseconds: totalCompactionNanoseconds,
            foregroundPreparationOverlapNanoseconds: overlapNanoseconds,
            finalActiveDistinctKeys: measured.finalActiveDistinctKeys,
            frozenIdentityCommitment: frozenIdentityCommitment,
            actorEntryCount: actorEntryCount,
            freshReopenEntryCount: reopenedSnapshot.entries.count,
            actorLogicalAuthorityCommitment: actorLogicalAuthorityCommitment,
            freshReopenLogicalAuthorityCommitment: reopenedLogicalAuthorityCommitment,
            actorIdentityCommitment: actorCommitment,
            freshReopenIdentityCommitment: reopenedCommitment,
            freshReopenExact: freshReopenExact,
            claims: .init(
                mechanismMeasurement: true,
                formalPerformance: false,
                endToEndStorePerformance: false,
                physicalIOBytes: false,
                physicalDevice: false,
                energy: false,
                powerLoss: false,
                automaticCompactionTrigger: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        _ = reopened
    }

    private static func schema5CompactionResourceMeasuredPhase(
        store: FileBlobStore,
        root: URL,
        profile: Schema5CompactionResourceProfile,
        mode: String,
        workload: String,
        hotIdentity: Schema5CompactionForegroundIdentity?,
        checkpointIdentities: [Schema5CompactionForegroundIdentity]
    ) async throws -> Schema5CompactionResourceMeasuredResult {
        let gate = Schema5CompactionResourceGate()
        let compactionStartedAt: UInt64?
        var compactionTask: Task<Bool, Error>?
        if mode == "compaction" {
            compactionStartedAt = DispatchTime.now().uptimeNanoseconds
            compactionTask = Task { [store, gate, profile] in
                let observer: FileBlobStoreSegmentedCompactionObserver = { phase in
                    switch phase {
                    case .candidateVerified:
                        await gate.candidateVerifiedAndPause()
                    }
                }
                let preparationObserver: FileBlobStoreSegmentedCompactionPreparationObserver = {
                    await gate.preparationStarted()
                }
                switch profile {
                case .v1JSON:
                    return try await store.resourceProbeCompactSegmentedManifestV1(
                        observer: observer,
                        preparationObserver: preparationObserver
                    )
                case .v2Binary:
                    return try await store.resourceProbeCompactSegmentedManifestV2(
                        observer: observer,
                        preparationObserver: preparationObserver
                    )
                case .v3CompactBinary:
                    return try await store.resourceProbeCompactSegmentedManifestV3(
                        observer: observer,
                        preparationObserver: preparationObserver
                    )
                }
            }
            await gate.waitForPreparationStart()
        } else if mode == "baseline" {
            compactionStartedAt = nil
            compactionTask = nil
        } else {
            throw SegmentedManifestShadowError.invalidArguments
        }

        let foregroundStartedAt = DispatchTime.now().uptimeNanoseconds
        var operationNanoseconds: [UInt64] = []
        var checkpointNanoseconds: UInt64?
        var backpressure = false
        var rejectedCheckpointIdentity: Schema5CompactionForegroundIdentity?
        switch workload {
        case "hot":
            guard let hotIdentity else { throw SegmentedManifestShadowError.invalidArguments }
            operationNanoseconds.reserveCapacity(256)
            for _ in 0..<128 {
                let removeStart = DispatchTime.now().uptimeNanoseconds
                try await store.remove(
                    digest: hotIdentity.digest,
                    partition: hotIdentity.partition
                )
                operationNanoseconds.append(
                    DispatchTime.now().uptimeNanoseconds &- removeStart
                )
                let commitStart = DispatchTime.now().uptimeNanoseconds
                _ = try await store.commit(
                    data: hotIdentity.data,
                    digest: hotIdentity.digest,
                    partition: hotIdentity.partition
                )
                operationNanoseconds.append(
                    DispatchTime.now().uptimeNanoseconds &- commitStart
                )
            }
        case "checkpoint":
            guard checkpointIdentities.count == 512 else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            operationNanoseconds.reserveCapacity(512)
            for (index, identity) in checkpointIdentities.enumerated() {
                let start = DispatchTime.now().uptimeNanoseconds
                do {
                    _ = try await store.commit(
                        data: identity.data,
                        digest: identity.digest,
                        partition: identity.partition
                    )
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                    operationNanoseconds.append(elapsed)
                    if index == 511 { checkpointNanoseconds = elapsed }
                } catch AkashicError.limitExceeded where index == 511 {
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                    operationNanoseconds.append(elapsed)
                    checkpointNanoseconds = elapsed
                    backpressure = true
                    rejectedCheckpointIdentity = identity
                }
            }
        default:
            throw SegmentedManifestShadowError.invalidArguments
        }
        let foregroundEndedAt = DispatchTime.now().uptimeNanoseconds

        var pausedStats: Schema5CompactionResourceSegmentStats?
        var compactionPublished: Bool?
        var compactionEndedAt: UInt64?
        var postCompactionRetryNanoseconds: UInt64?
        if let task = compactionTask {
            let timingBeforeRelease = await gate.timing()
            if timingBeforeRelease.candidateVerifiedAt != nil {
                pausedStats = try schema5CompactionResourceSegmentStats(root: root)
            }
            await gate.releaseVerifiedPause()
            compactionPublished = try await task.value
            compactionEndedAt = DispatchTime.now().uptimeNanoseconds
            if let identity = rejectedCheckpointIdentity {
                let retryStart = DispatchTime.now().uptimeNanoseconds
                _ = try await store.commit(
                    data: identity.data,
                    digest: identity.digest,
                    partition: identity.partition
                )
                postCompactionRetryNanoseconds = DispatchTime.now().uptimeNanoseconds &- retryStart
            }
        }
        compactionTask = nil
        let timing = await gate.timing()
        let finalRoot = try schema5CompactionResourceReadRoot(root)
        let finalStats = try schema5CompactionResourceSegmentStats(root: root)
        let finalSnapshot = await store.resourceProbeManifestShadowSnapshot()
        let active = try await store.resourceProbeDirectoryHeadEpochSnapshot()
        return Schema5CompactionResourceMeasuredResult(
            foregroundOperationNanoseconds: operationNanoseconds,
            foregroundStartedAt: foregroundStartedAt,
            foregroundEndedAt: foregroundEndedAt,
            checkpointNanoseconds: checkpointNanoseconds,
            capacityBackpressureObserved: backpressure,
            postCompactionRetryNanoseconds: postCompactionRetryNanoseconds,
            compactionPublished: compactionPublished,
            compactionStartedAt: compactionStartedAt,
            candidateVerifiedAt: timing.candidateVerifiedAt,
            compactionEndedAt: compactionEndedAt,
            pausedSegmentStats: pausedStats,
            finalSegmentStats: finalStats,
            finalRootRunCount: finalRoot.runs.count,
            finalRootBytes: try SegmentedManifestPrototypeV1.encodeRoot(finalRoot).count,
            finalBaseBytes: finalRoot.base.byteCount,
            finalActorSnapshot: finalSnapshot,
            finalActiveDistinctKeys: active.distinctKeyCount
        )
    }

    private static func schema5CompactionForegroundIdentity(
        index: Int,
        byteCount: Int,
        fill: UInt8
    ) throws -> Schema5CompactionForegroundIdentity {
        guard byteCount > 0, byteCount <= 64 * 1024 else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let data = Data(repeating: fill, count: byteCount)
        return Schema5CompactionForegroundIdentity(
            data: data,
            digest: BlobDigest.sha256(of: data),
            partition: try schema5CompactionResourcePartition(index)
        )
    }

    private static func schema5CompactionResourceReadRoot(
        _ root: URL
    ) throws -> SegmentedManifestRootV1 {
        try SegmentedManifestPrototypeV1.readRoot(
            from: root.appendingPathComponent("manifest.json", isDirectory: false)
        )
    }

    private static func schema5CompactionResourceSegmentStats(
        root: URL
    ) throws -> Schema5CompactionResourceSegmentStats {
        let directory = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        let names = try BoundedDirectoryReader.names(
            in: directory,
            maximumCount: SegmentedManifestSegmentCleanupV1.maximumDirectoryEntries
        )
        var bytes = 0
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes += (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
        return Schema5CompactionResourceSegmentStats(
            fileCount: names.count,
            byteCount: bytes
        )
    }

    private static func schema5CompactionResourceOpen(
        root: URL,
        profile: Schema5CompactionResourceProfile
    ) async throws -> FileBlobStore {
        for _ in 0..<500 {
            do {
                switch profile {
                case .v1JSON:
                    return try await FileBlobStore.open(root: root)
                case .v2Binary:
                    return try await FileBlobStore.openSegmentedV2Candidate(root: root)
                case .v3CompactBinary:
                    return try await FileBlobStore.openSegmentedV3Candidate(root: root)
                }
            }
            catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch AkashicError.transactionConflict {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema5MigrationProbeError.writerLeaseDidNotRelease
    }

    private static func schema5CompactionLogicalAuthorityCommitment(
        _ entries: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> String {
        var transcript = Data("AKASHIC-SCHEMA5-LOGICAL-AUTHORITY-V1\0".utf8)
        for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let keyBytes = Data(key.utf8)
            guard keyBytes.count <= Int(UInt32.max), entry.byteCount >= 0 else {
                throw SegmentedManifestShadowError.invariantViolation
            }
            schema5CompactionAppendLittleEndian(UInt32(keyBytes.count), to: &transcript)
            transcript.append(keyBytes)
            transcript.append(entry.partition.canonicalBytes)
            transcript.append(entry.digest.bytes)
            schema5CompactionAppendLittleEndian(UInt64(entry.byteCount), to: &transcript)
        }
        return SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
    }

    private static func schema5CompactionAppendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func schema5CompactionResourceArguments(
        _ arguments: [String]
    ) throws -> (
        root: URL,
        profile: Schema5CompactionResourceProfile,
        mode: String,
        liveEntries: Int,
        runCount: Int,
        recordsPerRun: Int,
        history: String,
        workload: String,
        foregroundPayloadBytes: Int,
        barrier: Schema5CompactionResourceBarrier
    ) {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let root = values["--root"],
            let profileRaw = values["--profile"],
            let profile = Schema5CompactionResourceProfile(rawValue: profileRaw),
            let mode = values["--mode"],
            mode == "baseline" || mode == "compaction",
            let liveEntries = values["--live"].flatMap(Int.init),
            let runCount = values["--runs"].flatMap(Int.init),
            let recordsPerRun = values["--records-per-run"].flatMap(Int.init),
            let history = values["--history"],
            let workload = values["--workload"],
            let foregroundPayloadBytes = values["--foreground-payload-bytes"].flatMap(Int.init),
            let ready = values["--ready-fd"].flatMap(Int32.init),
            let go = values["--go-fd"].flatMap(Int32.init),
            let done = values["--done-fd"].flatMap(Int32.init),
            let release = values["--release-fd"].flatMap(Int32.init)
        else { throw SegmentedManifestShadowError.invalidArguments }
        return (
            root: URL(fileURLWithPath: root, isDirectory: true),
            profile: profile,
            mode: mode,
            liveEntries: liveEntries,
            runCount: runCount,
            recordsPerRun: recordsPerRun,
            history: history,
            workload: workload,
            foregroundPayloadBytes: foregroundPayloadBytes,
            barrier: Schema5CompactionResourceBarrier(
                readyFD: ready,
                goFD: go,
                doneFD: done,
                releaseFD: release
            )
        )
    }
}
