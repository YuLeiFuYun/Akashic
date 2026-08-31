import AkashicCore
import Darwin
import Foundation

extension FileBlobStore {
    func canCoalesceDirectoryHeadCommit(key: String) throws -> Bool {
        guard manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2
        else { return false }
        let state = try currentDirectoryHeadState()
        guard state.uncommittedRecordNames.isEmpty else { return false }
        let createsRecord = state.latest[key] == nil
        guard Int(state.activeHead.c) + (createsRecord ? 1 : 0)
            < Self.manifestCheckpointRecordLimit
        else { return false }
        return !state.activeHead.s.addingReportingOverflow(1).overflow
    }

    func persistDirectoryHeadManifest(_ candidate: Manifest) throws -> Manifest {
        guard manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2,
            candidate.entries.count <= Self.maximumManifestEntryCount
        else { throw AkashicError.storageUnavailable }
        repayManifestRecordCleanupDebtBestEffort()
        let next = Manifest(
            schemaVersion: manifest.schemaVersion,
            generation: manifest.generation,
            deltaCarrierProfile: manifest.deltaCarrierProfile,
            entries: candidate.entries
        )
        guard isValidManifestEntriesAndOwnership(next) else {
            throw AkashicError.storageUnavailable
        }
        guard next.entries != manifest.entries else { return manifest }
        // Arbitrary candidates intentionally never use the single-key hot path. Multi-key
        // maintenance and bootstrap reconciliation retain a full-state validation/checkpoint
        // boundary; only persistSingleKeyManifestEntry may enter the O(1) delta protocol.
        return try checkpointManifest(next)
    }

    func persistDirectoryHeadSingleKeyEntry(
        key: String,
        entry: Entry?
    ) throws -> Manifest {
        guard manifest.schemaVersion == Self.directoryHeadManifestSchemaVersion,
            manifest.deltaCarrierProfile == .directoryHeadV2
        else { throw AkashicError.storageUnavailable }
        repayManifestRecordCleanupDebtBestEffort()
        if manifestOwnershipIndex == nil {
            guard let rebuilt = validatedManifestOwnershipIndex(manifest) else {
                throw AkashicError.invalidManifest
            }
            manifestOwnershipIndex = rebuilt
        }
        guard let ownershipTransition = try validatedSchema4SingleKeyOwnershipTransition(
            key: key,
            newEntry: entry
        ) else { return manifest }

        var state = try currentDirectoryHeadState()
        try repayDirectoryHeadCleanupDebtBeforeMutation(limit: 2)
        if !state.uncommittedRecordNames.isEmpty {
            do {
                for name in state.uncommittedRecordNames {
                    try directoryHeadOperations.removeAttribute(name, blobs)
                }
                try directoryHeadOperations.synchronizeDirectory(blobs)
            } catch {
                requiresReopenBeforeFurtherAccess = true
                throw error
            }
            state = try Self.loadDirectoryHeadState(
                directory: blobs,
                generation: manifest.generation,
                operations: directoryHeadOperations
            )
        }

        let current = state.latest[key]
        let createsRecord = current == nil
        if Int(state.activeHead.c) + (createsRecord ? 1 : 0) >= Self.manifestCheckpointRecordLimit {
            return try checkpointManifest(applying: ownershipTransition)
        }

        if let staleName = state.staleCommittedByKey[key] {
            do {
                try directoryHeadOperations.removeAttribute(staleName, blobs)
            } catch {
                throw error
            }
        }

        let sequence = state.activeHead.s.addingReportingOverflow(1)
        guard !sequence.overflow else {
            return try checkpointManifest(applying: ownershipTransition)
        }
        let record = ManifestRecord(
            generation: manifest.generation,
            sequence: sequence.partialValue,
            key: key,
            entry: entry
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let recordData = try encoder.encode(record)
        guard recordData.count <= Self.maximumManifestRecordBytes else {
            throw AkashicError.storageUnavailable
        }
        let recordIdentity = try DirectoryHeadRecordIdentity.make(
            generation: manifest.generation,
            sequence: sequence.partialValue,
            key: key
        )

        do {
            try directoryHeadOperations.setAttribute(
                recordIdentity.name,
                recordData,
                blobs,
                XATTR_CREATE
            )
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }

        let newLeaf = try Self.directoryHeadLeaf(
            identity: recordIdentity,
            recordData: recordData
        )
        var nextRoot = state.activeHead.r
        if let current {
            nextRoot = try Self.directoryHeadXor(nextRoot, current.leaf)
        }
        nextRoot = try Self.directoryHeadXor(nextRoot, newLeaf)
        let nextCount = Int(state.activeHead.c) + (createsRecord ? 1 : 0)
        let inactiveSlot: UInt8 = state.activeSlot == 0 ? 1 : 0
        let nextHead = try Self.makeDirectoryHead(
            generation: manifest.generation,
            slot: inactiveSlot,
            sequence: sequence.partialValue,
            count: nextCount,
            root: nextRoot
        )

        requiresReopenBeforeFurtherAccess = true
        do {
            try writeDirectoryHead(nextHead, flags: XATTR_REPLACE)
            try directoryHeadOperations.synchronizeDirectory(blobs)
        } catch {
            throw error
        }

        directoryHeadState = nil
        if let current {
            state.staleCommittedByKey[key] = current.identity.name
        } else {
            state.staleCommittedByKey.removeValue(forKey: key)
        }
        state.latest[key] = DirectoryHeadLatestRecord(
            identity: recordIdentity,
            data: recordData,
            record: record,
            leaf: newLeaf
        )
        state.activeSlot = inactiveSlot
        state.activeHead = nextHead
        state.uncommittedRecordNames.removeAll(keepingCapacity: true)
        directoryHeadState = state
        manifestRecordSequence = nextHead.s
        if createsRecord { manifestRecordKeys.insert(key) }

        if let entry {
            manifest.entries[key] = entry
        } else {
            manifest.entries.removeValue(forKey: key)
        }
        do {
            try adoptSchema4SingleKeyOwnershipTransition(ownershipTransition)
        } catch {
            requiresReopenBeforeFurtherAccess = true
            throw error
        }
        requiresReopenBeforeFurtherAccess = false
        return manifest
    }

    func currentDirectoryHeadState() throws -> DirectoryHeadRecoveredState {
        if let state = directoryHeadState,
            state.activeHead.g == manifest.generation
        {
            return state
        }
        let state = try loadOrRepairDirectoryHeadGeneration(
            generation: manifest.generation
        )
        directoryHeadState = state
        manifestRecordSequence = state.activeHead.s
        manifestRecordKeys = Set(state.latest.keys)
        return state
    }

    func enqueueCurrentDirectoryHeadGenerationForCleanup(
        state: DirectoryHeadRecoveredState,
        generation: UInt64
    ) {
        var known = Set(staleDirectoryHeadCleanupQueue)
        for item in state.latest.values {
            if known.insert(item.identity.name).inserted {
                staleDirectoryHeadCleanupQueue.append(item.identity.name)
            }
        }
        for name in state.staleCommittedByKey.values {
            if known.insert(name).inserted {
                staleDirectoryHeadCleanupQueue.append(name)
            }
        }
        for name in state.uncommittedRecordNames {
            if known.insert(name).inserted {
                staleDirectoryHeadCleanupQueue.append(name)
            }
        }
        for slot: UInt8 in [0, 1] {
            let name = DirectoryHeadIdentity(generation: generation, slot: slot).name
            if known.insert(name).inserted {
                staleDirectoryHeadCleanupQueue.append(name)
            }
        }
    }

    func repayDirectoryHeadCleanupDebtBeforeMutation(limit: Int) throws {
        guard limit > 0 else { return }
        var removedAny = false
        var removedNames: [String] = []
        removedNames.reserveCapacity(limit)
        for _ in 0..<limit {
            guard let name = staleDirectoryHeadCleanupQueue.last else { break }
            do {
                try directoryHeadOperations.removeAttribute(name, blobs)
            } catch {
                // Metadata-capacity debt is stricter than payload cleanup debt: do not grow a new
                // generation while stale authority metadata cannot be retired.
                throw error
            }
            _ = staleDirectoryHeadCleanupQueue.popLast()
            removedNames.append(name)
            removedAny = true
        }
        // No independent fsync here: a successful record/head mutation below synchronizes the same
        // directory and makes cleanup durable. If the caller exits before writing an intent, these
        // removals target only already-stale generations and are safe to be observed early.
        _ = removedAny
        _ = removedNames
    }
}
