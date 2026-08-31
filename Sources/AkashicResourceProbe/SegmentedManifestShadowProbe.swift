import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

enum SegmentedManifestShadowError: Error {
    case invalidArguments
    case invalidFormat
    case invariantViolation
    case workspaceInvariant(String)
}

struct SegmentedShadowEntry: Equatable {
    let key: String
    let physicalID: PhysicalBlobID
    let partition: CachePartitionID
    let digest: BlobDigest
    let byteCount: Int
    let lastAccess: Date
}

enum SegmentedShadowMutation: Equatable {
    case upsert(SegmentedShadowEntry)
    case tombstone(key: String)

    var key: String {
        switch self {
        case .upsert(let entry): entry.key
        case .tombstone(let key): key
        }
    }
}

struct SegmentedShadowDescriptor: Codable, Equatable {
    enum Kind: String, Codable {
        case base
        case run
    }

    let kind: Kind
    let fileName: String
    let byteCount: Int
    let recordCount: Int
    let sha256: String
}

struct SegmentedShadowRoot: Codable, Equatable {
    let schemaVersion: Int
    let generation: UInt64
    let base: SegmentedShadowDescriptor
    let runs: [SegmentedShadowDescriptor]
    let seal: String
}

struct SegmentedShadowRootTranscript: Codable {
    let schemaVersion: Int
    let generation: UInt64
    let base: SegmentedShadowDescriptor
    let runs: [SegmentedShadowDescriptor]
}

struct SegmentedShadowFaultResult: Codable {
    let preRenameDestinationExists: Bool
    let postRenameDestinationExists: Bool
    let postRenameValidSegment: Bool
    let postRenameReferencedByRoot: Bool
}

struct SegmentedManifestShadowReport: Codable {
    let schemaVersion: Int
    let baseRecords: Int
    let runRecords: Int
    let expectedFinalRecords: Int
    let baseBytes: Int
    let runBytes: Int
    let rootBytes: Int
    let baseRecordBytes: Int
    let runRecordBytes: Int
    let exactRoundTrip: Bool
    let canonicalOrder: Bool
    let exactFinalState: Bool
    let corruptionRejected: Bool
    let nonCanonicalReservedRejected: Bool
    let rootSealTamperRejected: Bool
    let descriptorContentSubstitutionRejected: Bool
    let duplicatePhysicalOwnershipRejected: Bool
    let rootPublicationFault: SegmentedShadowRootPublicationFaultResult
    let workspaceRestart: SegmentedShadowWorkspaceResult
    let fault: SegmentedShadowFaultResult
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let fileBlobStoreAuthority: Bool
        let automaticMigration: Bool
        let keyedAuthentication: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

enum SegmentedManifestShadowProbe {
    static let headerBytes = 64
    static let baseRecordBytes = 128
    static let runRecordBytes = 136
    static let maximumBaseRecords = 100_000
    static let maximumRunRecords = 512
    static let maximumRunDescriptors = 64
    static let maximumBaseBytes = 16 * 1024 * 1024
    static let maximumRunBytes = 1 * 1024 * 1024
    static let maximumReferencedSegmentBytes = 32 * 1024 * 1024
    static let maximumRootBytes = 64 * 1024
    static let maximumBlobBytes = 1024 * 1024 * 1024
    static let magic = Data("AKSGv001".utf8)

    static func run(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw SegmentedManifestShadowError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let rootPath = values["--root"] else {
            throw SegmentedManifestShadowError.invalidArguments
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segmentDirectory = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segmentDirectory)

        let baseEntries = try makeBaseEntries(count: 1_024)
        let mutations = try makeRunMutations(base: baseEntries, count: 512)
        let expected = try apply(mutations, to: Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) }))

        let baseData = try encodeBase(baseEntries)
        let runData = try encodeRun(mutations)
        let decodedBase = try decodeBase(baseData)
        let decodedRun = try decodeRun(runData)
        guard decodedBase == baseEntries, decodedRun == mutations else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let baseURL = segmentDirectory.appendingPathComponent("base-0001.seg")
        let runURL = segmentDirectory.appendingPathComponent("run-0001.seg")
        try DurableFileWriter.writeReplacing(baseData, to: baseURL)
        try DurableFileWriter.writeReplacing(runData, to: runURL)
        try StorageDirectorySecurity.validateRegularFile(baseURL)
        try StorageDirectorySecurity.validateRegularFile(runURL)

        let baseDescriptor = try descriptor(.base, url: baseURL, expectedRecords: baseEntries.count)
        let runDescriptor = try descriptor(.run, url: runURL, expectedRecords: mutations.count)
        let rootManifest = try makeRoot(
            generation: 2,
            base: baseDescriptor,
            runs: [runDescriptor]
        )
        let rootEncoder = JSONEncoder()
        rootEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rootData = try rootEncoder.encode(rootManifest)
        guard rootData.count <= maximumRootBytes else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let rootURL = root.appendingPathComponent("shadow-root.json")
        try DurableFileWriter.writeReplacing(rootData, to: rootURL)

        let recoveredRootData = try BoundedFileReader.read(from: rootURL, maximumBytes: maximumRootBytes)
        let recoveredRoot = try JSONDecoder().decode(SegmentedShadowRoot.self, from: recoveredRootData)
        guard recoveredRoot == rootManifest,
            try validateRootSeal(recoveredRoot)
        else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var recovered = Dictionary(uniqueKeysWithValues: try readBase(recoveredRoot.base, directory: segmentDirectory).map { ($0.key, $0) })
        for descriptor in recoveredRoot.runs {
            recovered = try apply(try readRun(descriptor, directory: segmentDirectory), to: recovered)
        }
        guard recovered == expected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let corrupted = runData.enumerated().map { offset, byte in
            offset == headerBytes + 17 ? byte ^ 0x01 : byte
        }
        var corruptionRejected = false
        do {
            _ = try decodeRun(Data(corrupted))
        } catch {
            corruptionRejected = true
        }
        guard corruptionRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        var nonCanonicalReserved = runData
        let reservedOffset = headerBytes + 32 + 1
        nonCanonicalReserved.replaceSubrange(reservedOffset..<(reservedOffset + 1), with: [0x01])
        let nonCanonicalPayload = nonCanonicalReserved.subdata(in: headerBytes..<nonCanonicalReserved.count)
        nonCanonicalReserved.replaceSubrange(32..<64, with: Data(SHA256.hash(data: nonCanonicalPayload)))
        var nonCanonicalReservedRejected = false
        do {
            _ = try decodeRun(nonCanonicalReserved)
        } catch {
            nonCanonicalReservedRejected = true
        }
        guard nonCanonicalReservedRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let preRenameURL = segmentDirectory.appendingPathComponent("fault-pre.seg")
        do {
            try DurableFileWriter.writeReplacing(
                runData,
                to: preRenameURL,
                faultInjector: { point in
                    if point == .afterFileSynced { throw POSIXError(.EIO) }
                }
            )
            throw SegmentedManifestShadowError.invariantViolation
        } catch is POSIXError {
        }
        let preRenameExists = FileManager.default.fileExists(atPath: preRenameURL.path)
        guard !preRenameExists else { throw SegmentedManifestShadowError.invariantViolation }

        let postRenameURL = segmentDirectory.appendingPathComponent("fault-post.seg")
        do {
            try DurableFileWriter.writeReplacing(
                runData,
                to: postRenameURL,
                faultInjector: { point in
                    if point == .afterRename { throw POSIXError(.EIO) }
                }
            )
            throw SegmentedManifestShadowError.invariantViolation
        } catch is POSIXError {
        }
        let postRenameExists = FileManager.default.fileExists(atPath: postRenameURL.path)
        var postRenameValid = false
        if postRenameExists {
            let data = try BoundedFileReader.read(
                from: postRenameURL,
                maximumBytes: headerBytes + mutations.count * runRecordBytes
            )
            postRenameValid = (try? decodeRun(data)) == mutations
        }
        let postReferenced = recoveredRoot.runs.contains { $0.fileName == postRenameURL.lastPathComponent }
        guard postRenameExists, postRenameValid, !postReferenced else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let tamperedRoot = SegmentedShadowRoot(
            schemaVersion: recoveredRoot.schemaVersion,
            generation: recoveredRoot.generation + 1,
            base: recoveredRoot.base,
            runs: recoveredRoot.runs,
            seal: recoveredRoot.seal
        )
        let rootSealTamperRejected = try !validateRootSeal(tamperedRoot)
        guard rootSealTamperRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        var alternateMutations = mutations
        guard let alternateIndex = alternateMutations.firstIndex(where: {
            if case .upsert = $0 { return true }
            return false
        }),
            case .upsert(let alternateSource) = alternateMutations[alternateIndex]
        else { throw SegmentedManifestShadowError.invariantViolation }
        alternateMutations[alternateIndex] = .upsert(
            SegmentedShadowEntry(
                key: alternateSource.key,
                physicalID: PhysicalBlobID(),
                partition: alternateSource.partition,
                digest: alternateSource.digest,
                byteCount: alternateSource.byteCount,
                lastAccess: alternateSource.lastAccess
            )
        )
        let alternateData = try encodeRun(alternateMutations)
        let alternateURL = segmentDirectory.appendingPathComponent("run-alternate.seg")
        try DurableFileWriter.writeReplacing(alternateData, to: alternateURL)
        guard try decodeRun(alternateData) == alternateMutations,
            alternateData.count == runData.count
        else { throw SegmentedManifestShadowError.invariantViolation }
        let mismatchedDescriptor = SegmentedShadowDescriptor(
            kind: .run,
            fileName: alternateURL.lastPathComponent,
            byteCount: runDescriptor.byteCount,
            recordCount: runDescriptor.recordCount,
            sha256: runDescriptor.sha256
        )
        let mismatchedRoot = try makeRoot(
            generation: recoveredRoot.generation,
            base: recoveredRoot.base,
            runs: [mismatchedDescriptor]
        )
        guard try validateRootSeal(mismatchedRoot) else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var descriptorContentSubstitutionRejected = false
        do {
            _ = try readRun(mismatchedDescriptor, directory: segmentDirectory)
        } catch {
            descriptorContentSubstitutionRejected = true
        }
        guard descriptorContentSubstitutionRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let baseMap = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        guard let created = mutations.compactMap({ mutation -> SegmentedShadowEntry? in
            guard case .upsert(let entry) = mutation, baseMap[entry.key] == nil else { return nil }
            return entry
        }).first,
            let retainedPhysicalID = baseEntries.last?.physicalID
        else { throw SegmentedManifestShadowError.invariantViolation }
        let ownershipConflict = SegmentedShadowEntry(
            key: created.key,
            physicalID: retainedPhysicalID,
            partition: created.partition,
            digest: created.digest,
            byteCount: created.byteCount,
            lastAccess: created.lastAccess
        )
        let ownershipRun = try decodeRun(encodeRun([.upsert(ownershipConflict)]))
        var duplicatePhysicalOwnershipRejected = false
        do {
            _ = try apply(ownershipRun, to: baseMap)
        } catch {
            duplicatePhysicalOwnershipRejected = true
        }
        guard duplicatePhysicalOwnershipRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        let rootPublicationFault = try rootPublicationFaults(
            root: root,
            segmentDirectory: segmentDirectory,
            base: baseDescriptor,
            run: runDescriptor,
            oldState: baseMap,
            newState: expected
        )
        let workspaceRestart = try workspaceRestartScenarios(
            root: root,
            frozenRoot: recoveredRoot,
            baseData: baseData
        )

        let report = SegmentedManifestShadowReport(
            schemaVersion: 1,
            baseRecords: baseEntries.count,
            runRecords: mutations.count,
            expectedFinalRecords: expected.count,
            baseBytes: baseData.count,
            runBytes: runData.count,
            rootBytes: rootData.count,
            baseRecordBytes: baseRecordBytes,
            runRecordBytes: runRecordBytes,
            exactRoundTrip: true,
            canonicalOrder: true,
            exactFinalState: true,
            corruptionRejected: corruptionRejected,
            nonCanonicalReservedRejected: nonCanonicalReservedRejected,
            rootSealTamperRejected: rootSealTamperRejected,
            descriptorContentSubstitutionRejected: descriptorContentSubstitutionRejected,
            duplicatePhysicalOwnershipRejected: duplicatePhysicalOwnershipRejected,
            rootPublicationFault: rootPublicationFault,
            workspaceRestart: workspaceRestart,
            fault: SegmentedShadowFaultResult(
                preRenameDestinationExists: preRenameExists,
                postRenameDestinationExists: postRenameExists,
                postRenameValidSegment: postRenameValid,
                postRenameReferencedByRoot: postReferenced
            ),
            claims: .init(
                productionFormat: false,
                fileBlobStoreAuthority: false,
                automaticMigration: false,
                keyedAuthentication: false,
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

}
