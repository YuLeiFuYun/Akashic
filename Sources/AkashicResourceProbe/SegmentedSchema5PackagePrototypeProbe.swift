import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct SegmentedSchema5PrototypeReport: Codable {
    let schemaVersion: Int
    let baseRecords: Int
    let runRecords: Int
    let baseBytes: Int
    let runBytes: Int
    let rootBytes: Int
    let exactBaseRecovery: Bool
    let exactRunRecovery: Bool
    let rootSealTamperRejected: Bool
    let runCorruptionRejected: Bool
    let descriptorSubstitutionRejected: Bool
    let duplicatePhysicalOwnershipRejected: Bool
    let preRenameRootFaultPreservesOldAuthority: Bool
    let postRenameRootFaultRecoversNewAuthority: Bool
    let runCapRejectsBeforeMaterialization: Bool
    let referencedByteCapRejectsBeforeMaterialization: Bool
    let allChecksPass: Bool
    let claims: Claims

    struct Claims: Codable {
        let fileBlobStoreAuthority: Bool
        let automaticMigration: Bool
        let productionFormat: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func schema5PackagePrototype(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let baseEntries = try makeBaseEntries(count: 1_024)
        let baseState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let baseSnapshot = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: schema5ShadowEntries(baseState)
        )
        let base = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseSnapshot,
            entryCount: baseEntries.count,
            fileName: "base-prototype-0001.json",
            directory: segments
        )
        let initialRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 1,
            base: base,
            runs: []
        )
        let rootURL = root.appendingPathComponent("prototype-root.json")
        try SegmentedManifestPrototypeV1.writeRoot(initialRoot, to: rootURL)
        let recoveredBase = try SegmentedManifestPrototypeV1.recover(
            rootURL: rootURL,
            segmentDirectory: segments
        )
        let expectedBase = schema5Entries(baseState)
        let exactBaseRecovery = recoveredBase == expectedBase

        let shadowMutations = try makeRunMutations(base: baseEntries, count: 512)
        let mutations = shadowMutations.map(schema5Mutation)
        let expectedFinal = try SegmentedManifestPrototypeV1.apply(mutations, to: expectedBase)
        let nextRoot = try SegmentedManifestPrototypeV1.publishEpochRun(
            mutations: mutations,
            runFileName: "run-prototype-0001.seg",
            currentRoot: initialRoot,
            rootURL: rootURL,
            segmentDirectory: segments
        )
        let recoveredFinal = try SegmentedManifestPrototypeV1.recover(
            rootURL: rootURL,
            segmentDirectory: segments
        )
        let exactRunRecovery = recoveredFinal == expectedFinal
            && nextRoot.generation == 2
            && nextRoot.runs.count == 1

        let rootSealTamperRejected = try schema5RootTamperRejected(
            nextRoot: nextRoot,
            root: root
        )
        let runCorruptionRejected = try schema5RunCorruptionRejected(
            nextRoot: nextRoot,
            root: root,
            segments: segments
        )
        let descriptorSubstitutionRejected = try schema5DescriptorSubstitutionRejected(
            base: base,
            mutations: mutations,
            root: root,
            segments: segments
        )
        let duplicatePhysicalOwnershipRejected = try schema5DuplicateOwnershipRejected(
            baseEntries: baseEntries
        )
        let rootFaults = try schema5RootFaults(
            base: base,
            mutations: mutations,
            expectedBase: expectedBase,
            expectedFinal: expectedFinal,
            root: root
        )
        let runCapRejectsBeforeMaterialization = try schema5RunCapPreflight(
            base: base,
            mutation: mutations[0],
            root: root
        )
        let referencedByteCapRejectsBeforeMaterialization = try schema5ReferencedBytePreflight(
            mutation: mutations[0],
            root: root
        )

        let allChecksPass = exactBaseRecovery
            && exactRunRecovery
            && rootSealTamperRejected
            && runCorruptionRejected
            && descriptorSubstitutionRejected
            && duplicatePhysicalOwnershipRejected
            && rootFaults.preRename
            && rootFaults.postRename
            && runCapRejectsBeforeMaterialization
            && referencedByteCapRejectsBeforeMaterialization

        let rootBytes = try SegmentedManifestPrototypeV1.encodeRoot(nextRoot).count
        let report = SegmentedSchema5PrototypeReport(
            schemaVersion: 1,
            baseRecords: base.recordCount,
            runRecords: mutations.count,
            baseBytes: base.byteCount,
            runBytes: nextRoot.runs[0].byteCount,
            rootBytes: rootBytes,
            exactBaseRecovery: exactBaseRecovery,
            exactRunRecovery: exactRunRecovery,
            rootSealTamperRejected: rootSealTamperRejected,
            runCorruptionRejected: runCorruptionRejected,
            descriptorSubstitutionRejected: descriptorSubstitutionRejected,
            duplicatePhysicalOwnershipRejected: duplicatePhysicalOwnershipRejected,
            preRenameRootFaultPreservesOldAuthority: rootFaults.preRename,
            postRenameRootFaultRecoversNewAuthority: rootFaults.postRename,
            runCapRejectsBeforeMaterialization: runCapRejectsBeforeMaterialization,
            referencedByteCapRejectsBeforeMaterialization: referencedByteCapRejectsBeforeMaterialization,
            allChecksPass: allChecksPass,
            claims: .init(
                fileBlobStoreAuthority: false,
                automaticMigration: false,
                productionFormat: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard allChecksPass else {
            throw SegmentedManifestShadowError.invariantViolation
        }
    }

    private static func schema5RootTamperRejected(
        nextRoot: SegmentedManifestRootV1,
        root: URL
    ) throws -> Bool {
        let tampered = SegmentedManifestRootV1(
            schemaVersion: nextRoot.schemaVersion,
            profile: nextRoot.profile,
            generation: nextRoot.generation + 1,
            base: nextRoot.base,
            runs: nextRoot.runs,
            seal: nextRoot.seal
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let url = root.appendingPathComponent("tampered-root.json")
        try DurableFileWriter.writeReplacing(try encoder.encode(tampered), to: url)
        do {
            _ = try SegmentedManifestPrototypeV1.readRoot(from: url)
            return false
        } catch {
            return true
        }
    }

    private static func schema5RunCorruptionRejected(
        nextRoot: SegmentedManifestRootV1,
        root: URL,
        segments: URL
    ) throws -> Bool {
        let sourceURL = segments.appendingPathComponent(nextRoot.runs[0].fileName)
        var data = try BoundedFileReader.read(from: sourceURL, maximumBytes: nextRoot.runs[0].byteCount)
        data[data.startIndex + SegmentedManifestPrototypeV1.headerBytes + 17] ^= 0x01
        let corruptName = "run-corrupt-0001.seg"
        let corruptURL = segments.appendingPathComponent(corruptName)
        try DurableFileWriter.writeReplacing(data, to: corruptURL)
        let descriptor = SegmentedManifestDescriptorV1(
            kind: .runV1,
            fileName: corruptName,
            byteCount: nextRoot.runs[0].byteCount,
            recordCount: nextRoot.runs[0].recordCount,
            sha256: nextRoot.runs[0].sha256
        )
        let corruptRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 3,
            base: nextRoot.base,
            runs: [descriptor]
        )
        let rootURL = root.appendingPathComponent("corrupt-run-root.json")
        try SegmentedManifestPrototypeV1.writeRoot(corruptRoot, to: rootURL)
        do {
            _ = try SegmentedManifestPrototypeV1.recover(rootURL: rootURL, segmentDirectory: segments)
            return false
        } catch {
            return true
        }
    }

    private static func schema5DescriptorSubstitutionRejected(
        base: SegmentedManifestDescriptorV1,
        mutations: [SegmentedManifestMutation],
        root: URL,
        segments: URL
    ) throws -> Bool {
        var alternate = mutations
        guard let upsertIndex = alternate.firstIndex(where: { mutation in
            if case .upsert = mutation { return true }
            return false
        }), case .upsert(let source) = alternate[upsertIndex]
        else { return false }
        alternate[upsertIndex] = .upsert(
            SegmentedManifestEntry(
                key: source.key,
                physicalID: PhysicalBlobID(),
                partition: source.partition,
                digest: source.digest,
                byteCount: source.byteCount,
                lastAccess: source.lastAccess
            )
        )
        let alternateName = "run-alternate-0001.seg"
        let alternateDescriptor = try SegmentedManifestPrototypeV1.writeRun(
            alternate,
            fileName: alternateName,
            directory: segments
        )
        let originalData = try SegmentedManifestPrototypeV1.encodeRun(mutations)
        let mismatched = SegmentedManifestDescriptorV1(
            kind: .runV1,
            fileName: alternateDescriptor.fileName,
            byteCount: alternateDescriptor.byteCount,
            recordCount: alternateDescriptor.recordCount,
            sha256: SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined()
        )
        let mismatchedRoot = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 4,
            base: base,
            runs: [mismatched]
        )
        let rootURL = root.appendingPathComponent("substitution-root.json")
        try SegmentedManifestPrototypeV1.writeRoot(mismatchedRoot, to: rootURL)
        do {
            _ = try SegmentedManifestPrototypeV1.recover(rootURL: rootURL, segmentDirectory: segments)
            return false
        } catch {
            return true
        }
    }

    private static func schema5DuplicateOwnershipRejected(
        baseEntries: [SegmentedShadowEntry]
    ) throws -> Bool {
        guard baseEntries.count >= 2 else { return false }
        let first = baseEntries[0]
        let second = baseEntries[1]
        let conflict = SegmentedManifestEntry(
            key: second.key,
            physicalID: first.physicalID,
            partition: second.partition,
            digest: second.digest,
            byteCount: second.byteCount,
            lastAccess: second.lastAccess
        )
        let base = schema5Entries(Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) }))
        do {
            _ = try SegmentedManifestPrototypeV1.apply([.upsert(conflict)], to: base)
            return false
        } catch {
            return true
        }
    }

    private static func schema5RootFaults(
        base: SegmentedManifestDescriptorV1,
        mutations: [SegmentedManifestMutation],
        expectedBase: [String: SegmentedManifestEntry],
        expectedFinal: [String: SegmentedManifestEntry],
        root: URL
    ) throws -> (preRename: Bool, postRename: Bool) {
        let preDirectory = root.appendingPathComponent("fault-pre-segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(preDirectory)
        let baseData = try FileBlobStore.resourceProbeEncodeDirectoryHeadSnapshot(
            generation: 1,
            entries: schema5ShadowEntriesFromPrototype(expectedBase)
        )
        let preBase = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: expectedBase.count,
            fileName: base.fileName,
            directory: preDirectory
        )
        let preRoot = try SegmentedManifestPrototypeV1.makeRoot(generation: 10, base: preBase, runs: [])
        let preRootURL = root.appendingPathComponent("fault-pre-root.json")
        try SegmentedManifestPrototypeV1.writeRoot(preRoot, to: preRootURL)
        do {
            _ = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: mutations,
                runFileName: "run-fault-pre.seg",
                currentRoot: preRoot,
                rootURL: preRootURL,
                segmentDirectory: preDirectory,
                rootFaultInjector: { point in
                    if point == .afterFileSynced { throw POSIXError(.EIO) }
                }
            )
            return (false, false)
        } catch is POSIXError {
        }
        let preRecovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: preRootURL,
            segmentDirectory: preDirectory
        )

        let postDirectory = root.appendingPathComponent("fault-post-segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(postDirectory)
        let postBase = try SegmentedManifestPrototypeV1.writeBaseJSON(
            baseData,
            entryCount: expectedBase.count,
            fileName: base.fileName,
            directory: postDirectory
        )
        let postRoot = try SegmentedManifestPrototypeV1.makeRoot(generation: 20, base: postBase, runs: [])
        let postRootURL = root.appendingPathComponent("fault-post-root.json")
        try SegmentedManifestPrototypeV1.writeRoot(postRoot, to: postRootURL)
        do {
            _ = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: mutations,
                runFileName: "run-fault-post.seg",
                currentRoot: postRoot,
                rootURL: postRootURL,
                segmentDirectory: postDirectory,
                rootFaultInjector: { point in
                    if point == .afterRename { throw POSIXError(.EIO) }
                }
            )
            return (false, false)
        } catch is POSIXError {
        }
        let postRecovered = try SegmentedManifestPrototypeV1.recover(
            rootURL: postRootURL,
            segmentDirectory: postDirectory
        )
        return (preRecovered == expectedBase, postRecovered == expectedFinal)
    }

    private static func schema5RunCapPreflight(
        base: SegmentedManifestDescriptorV1,
        mutation: SegmentedManifestMutation,
        root: URL
    ) throws -> Bool {
        let hash = String(repeating: "a", count: 64)
        let runs = (0..<SegmentedManifestPrototypeV1.maximumRunDescriptors).map { index in
            SegmentedManifestDescriptorV1(
                kind: .runV1,
                fileName: "run-cap-\(index).seg",
                byteCount: SegmentedManifestPrototypeV1.headerBytes
                    + SegmentedManifestPrototypeV1.runRecordBytes,
                recordCount: 1,
                sha256: String(format: "%063x%x", index, index % 16)
            )
        }
        // Use unique valid lowercase hex hashes even if String(format:) above is unavailable on a
        // platform by replacing any accidental duplicate with a deterministic SHA-like suffix.
        let normalizedRuns = runs.enumerated().map { index, descriptor in
            SegmentedManifestDescriptorV1(
                kind: descriptor.kind,
                fileName: descriptor.fileName,
                byteCount: descriptor.byteCount,
                recordCount: descriptor.recordCount,
                sha256: String(hash.dropLast(String(index).count)) + String(index)
            )
        }
        let capped = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 50,
            base: base,
            runs: normalizedRuns
        )
        let directory = root.appendingPathComponent("cap-segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(directory)
        let candidate = directory.appendingPathComponent("run-cap-overflow.seg")
        do {
            _ = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: [mutation],
                runFileName: candidate.lastPathComponent,
                currentRoot: capped,
                rootURL: root.appendingPathComponent("cap-root.json"),
                segmentDirectory: directory
            )
            return false
        } catch {
            return !FileManager.default.fileExists(atPath: candidate.path)
        }
    }

    private static func schema5ReferencedBytePreflight(
        mutation: SegmentedManifestMutation,
        root: URL
    ) throws -> Bool {
        let oversizedBase = SegmentedManifestDescriptorV1(
            kind: .baseJSON,
            fileName: "base-near-reference-cap.json",
            byteCount: SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes - 100,
            recordCount: 1,
            sha256: String(repeating: "b", count: 64)
        )
        let current = try SegmentedManifestPrototypeV1.makeRoot(
            generation: 60,
            base: oversizedBase,
            runs: []
        )
        let directory = root.appendingPathComponent("reference-cap-segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(directory)
        let candidate = directory.appendingPathComponent("run-reference-overflow.seg")
        do {
            _ = try SegmentedManifestPrototypeV1.publishEpochRun(
                mutations: [mutation],
                runFileName: candidate.lastPathComponent,
                currentRoot: current,
                rootURL: root.appendingPathComponent("reference-cap-root.json"),
                segmentDirectory: directory
            )
            return false
        } catch {
            return !FileManager.default.fileExists(atPath: candidate.path)
        }
    }

}
