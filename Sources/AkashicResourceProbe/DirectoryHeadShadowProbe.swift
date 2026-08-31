import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Dispatch
import Foundation

enum DirectoryHeadShadowProbe {
    static let headVersion: UInt16 = 1
    static let zeroRoot = Data(repeating: 0, count: 32)
    static let processTestGeneration: UInt64 = 53

    static func run(arguments: [String]) throws {
        if let mode = arguments.first {
            let remaining = Array(arguments.dropFirst())
            switch mode {
            case "crash-prepare":
                try crashPrepare(arguments: remaining)
                return
            case "crash-child":
                try crashChild(arguments: remaining)
                return
            case "crash-random":
                try crashRandomChild(arguments: remaining)
                return
            case "crash-verify":
                try crashVerify(arguments: remaining)
                return
            case "scale":
                try runScale(arguments: remaining)
                return
            case "fault-shadow":
                try runFaultShadow(arguments: remaining)
                return
            default:
                throw DirectoryHeadShadowError.invalidArguments
            }
        }
        let generation: UInt64 = 41
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-directory-head-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let root = parent.appendingPathComponent("main", isDirectory: true)
        try createPrivateDirectory(root)
        let initialHead0 = try makeHead(generation: generation, slot: 0, sequence: 0, count: 0, root: zeroRoot)
        let initialHead1 = try makeHead(generation: generation, slot: 1, sequence: 0, count: 0, root: zeroRoot)
        try writeHead(initialHead0, at: root, create: true)
        try writeHead(initialHead1, at: root, create: true)
        try DirectoryHeadShadowIO.synchronize(root)

        let identities = try identityPool(count: 32)
        var expected: [String: FileBlobStoreRecordShadowEntry] = [:]
        var operationCount = 0
        var maximumRecordNameBytes = 0
        var maximumRecordValueBytes = 0
        var maximumHeadNameBytes = 0
        var maximumHeadValueBytes = 0
        var maximumRecordAttributes = 0
        var maximumRecordsPerKey = 0

        for round in 0..<6 {
            for offset in identities.indices {
                let identity = identities[(offset + round * 7) % identities.count]
                let shouldDelete = (round + offset) % 7 == 6 && expected[identity.key] != nil
                let entry: FileBlobStoreRecordShadowEntry?
                if shouldDelete {
                    entry = nil
                } else {
                    entry = FileBlobStoreRecordShadowEntry(
                        physicalID: PhysicalBlobID(),
                        partition: identity.partition,
                        digest: identity.digest,
                        byteCount: identity.byteCount,
                        lastAccess: Date(timeIntervalSinceReferenceDate: Double(operationCount + 1))
                    )
                }
                let sample = try performMutation(
                    root: root,
                    generation: generation,
                    key: identity.key,
                    entry: entry
                )
                operationCount += 1
                if let entry {
                    expected[identity.key] = entry
                } else {
                    expected.removeValue(forKey: identity.key)
                }
                let recovered = try recover(root: root, generation: generation, base: [:])
                guard recovered.logical == expected else {
                    throw DirectoryHeadShadowError.stateMismatch
                }
                maximumRecordNameBytes = max(maximumRecordNameBytes, sample.recordNameBytes)
                maximumRecordValueBytes = max(maximumRecordValueBytes, sample.recordValueBytes)
                maximumHeadNameBytes = max(maximumHeadNameBytes, sample.headNameBytes)
                maximumHeadValueBytes = max(maximumHeadValueBytes, sample.headValueBytes)
                maximumRecordAttributes = max(maximumRecordAttributes, recovered.recordIdentities.count)
                let counts = Dictionary(grouping: recovered.recordIdentities, by: \.key).mapValues(\.count)
                maximumRecordsPerKey = max(maximumRecordsPerKey, counts.values.max() ?? 0)
                guard counts.values.allSatisfy({ $0 <= 2 }) else {
                    throw DirectoryHeadShadowError.stateMismatch
                }
            }
        }

        let randomReplayMatched = try recover(root: root, generation: generation, base: [:]).logical == expected
        let currentRecordDeletionRejected = try verifyCurrentRecordDeletionRejected(
            root: root,
            generation: generation
        )
        let currentRecordCorruptionRejected = try verifyCurrentRecordCorruptionRejected(
            root: root,
            generation: generation
        )
        let staleRecordCorruptionIgnored = try verifyStaleRecordCorruptionIgnored(
            root: root,
            generation: generation,
            expected: expected
        )
        let uncommittedRecordCorruptionIgnored = try verifyUncommittedCorruptionIgnored(
            root: root,
            generation: generation,
            identity: identities[0],
            expected: expected
        )
        let headDeletionRejected = try verifyHeadDeletionRejected(root: root, generation: generation)
        let headCorruptionRejected = try verifyHeadCorruptionRejected(root: root, generation: generation)
        let duplicateSequenceRejected = try verifyDuplicateSequenceRejected(
            root: root,
            generation: generation,
            freshIdentity: identities[0]
        )
        let futureGenerationRejected = try verifyFutureGenerationRejected(
            root: root,
            generation: generation,
            identity: identities[1]
        )
        let malformedBase32Rejected = try verifyMalformedBase32Rejected(root: root, generation: generation)
        let keyBodyMismatchRejected = try verifyKeyBodyMismatchRejected(
            parent: parent,
            generation: generation + 10,
            identities: (identities[2], identities[3])
        )
        let duplicatePhysicalOwnershipRejected = try verifyDuplicatePhysicalOwnershipRejected(
            parent: parent,
            generation: generation + 20,
            identities: (identities[4], identities[5])
        )

        guard randomReplayMatched,
            currentRecordDeletionRejected,
            currentRecordCorruptionRejected,
            staleRecordCorruptionIgnored,
            uncommittedRecordCorruptionIgnored,
            headDeletionRejected,
            headCorruptionRejected,
            duplicateSequenceRejected,
            futureGenerationRejected,
            malformedBase32Rejected,
            keyBodyMismatchRejected,
            duplicatePhysicalOwnershipRejected
        else { throw DirectoryHeadShadowError.stateMismatch }

        let report = DirectoryHeadShadowReport(
            schemaVersion: 1,
            status: "passed",
            generation: generation,
            operationCount: operationCount,
            maximumRecordNameBytes: maximumRecordNameBytes,
            maximumRecordValueBytes: maximumRecordValueBytes,
            maximumHeadNameBytes: maximumHeadNameBytes,
            maximumHeadValueBytes: maximumHeadValueBytes,
            maximumRecordAttributes: maximumRecordAttributes,
            maximumRecordsPerKey: maximumRecordsPerKey,
            randomReplayMatched: randomReplayMatched,
            currentRecordDeletionRejected: currentRecordDeletionRejected,
            currentRecordCorruptionRejected: currentRecordCorruptionRejected,
            staleRecordCorruptionIgnored: staleRecordCorruptionIgnored,
            uncommittedRecordCorruptionIgnored: uncommittedRecordCorruptionIgnored,
            headDeletionRejected: headDeletionRejected,
            headCorruptionRejected: headCorruptionRejected,
            duplicateSequenceRejected: duplicateSequenceRejected,
            futureGenerationRejected: futureGenerationRejected,
            malformedBase32Rejected: malformedBase32Rejected,
            keyBodyMismatchRejected: keyBodyMismatchRejected,
            duplicatePhysicalOwnershipRejected: duplicatePhysicalOwnershipRejected,
            claims: .init(
                productionAuthorityChanged: false,
                productionSchemaChanged: false,
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

    struct Identity {
        let key: String
        let partition: CachePartitionID
        let digest: BlobDigest
        let byteCount: Int
    }

    struct MutationSample {
        let recordNameBytes: Int
        let recordValueBytes: Int
        let headNameBytes: Int
        let headValueBytes: Int
    }

    static func identityPool(count: Int) throws -> [Identity] {
        try (0..<count).map { index in
            let partition = try CachePartitionID.derive(
                domain: "akashic-directory-head-shadow-v1",
                material: Data("partition-\(index)".utf8)
            )
            let data = Data("directory-head-payload-\(index)-\(String(repeating: "q", count: index % 17))".utf8)
            let digest = BlobDigest.sha256(of: data)
            return Identity(
                key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
                partition: partition,
                digest: digest,
                byteCount: data.count
            )
        }
    }

    static func initializeMigrationShadow(root: URL, generation: UInt64) throws {
        try initializeHeads(root: root, generation: generation)
    }

    static func applyMigrationShadowMutation(
        root: URL,
        generation: UInt64,
        key: String,
        entry: FileBlobStoreRecordShadowEntry?
    ) throws {
        _ = try performMutation(root: root, generation: generation, key: key, entry: entry)
    }

    static func recoverMigrationShadow(
        root: URL,
        generation: UInt64,
        base: [String: FileBlobStoreRecordShadowEntry]
    ) throws -> [String: FileBlobStoreRecordShadowEntry] {
        try recover(root: root, generation: generation, base: base).logical
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    static func argumentValues(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else {
            throw DirectoryHeadShadowError.invalidArguments
        }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        return values
    }

    static func processTestIdentity() throws -> Identity {
        let partition = try CachePartitionID.derive(
            domain: "akashic-directory-head-process-v1",
            material: Data("single-logical-key".utf8)
        )
        let data = Data("directory-head-process-payload".utf8)
        let digest = BlobDigest.sha256(of: data)
        return Identity(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            partition: partition,
            digest: digest,
            byteCount: data.count
        )
    }

    static func crashPrepare(arguments: [String]) throws {
        let values = try argumentValues(arguments)
        guard let rootValue = values["--root"] else {
            throw DirectoryHeadShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try createPrivateDirectory(root)
        try initializeHeads(root: root, generation: processTestGeneration)
    }

    static func crashVerify(arguments: [String]) throws {
        let values = try argumentValues(arguments)
        guard let rootValue = values["--root"] else {
            throw DirectoryHeadShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let identity = try processTestIdentity()
        let report: DirectoryHeadCrashVerifyReport
        do {
            let recovered = try recover(root: root, generation: processTestGeneration, base: [:])
            let state: String
            if recovered.logical.isEmpty {
                state = "miss"
            } else if recovered.logical.count == 1, recovered.logical[identity.key] != nil {
                state = "hit"
            } else {
                state = "unexpected"
            }
            report = DirectoryHeadCrashVerifyReport(
                schemaVersion: 1,
                state: state,
                headSequence: recovered.activeHead.s,
                recordAttributeCount: recovered.recordIdentities.count,
                processCrashClaim: true,
                powerLossClaim: false
            )
        } catch {
            report = DirectoryHeadCrashVerifyReport(
                schemaVersion: 1,
                state: "invalid",
                headSequence: nil,
                recordAttributeCount: nil,
                processCrashClaim: true,
                powerLossClaim: false
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func runFaultShadow(arguments: [String]) throws {
        guard arguments.isEmpty else { throw DirectoryHeadShadowError.invalidArguments }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-directory-head-fault-shadow-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try createPrivateDirectory(parent)
        defer { try? FileManager.default.removeItem(at: parent) }

        enum AppliedState {
            case empty
            case record
            case head
            case synchronized
        }

        let specifications: [(String, AppliedState, String, String)] = [
            (
                "record-pre-syscall-fault",
                .empty,
                "no record or head side effect",
                "old state remains authoritative; no writer poison is required if the operation is proven not to have run"
            ),
            (
                "record-post-side-effect-fault",
                .record,
                "new record exists but head is unchanged",
                "logical state is still old; before reusing head.sequence+1 the uncommitted record must be removed and that cleanup made durable, otherwise reopen is required"
            ),
            (
                "head-pre-syscall-fault",
                .record,
                "record exists, head update is proven not to have run",
                "logical state is old; the intent may be cleaned before a later mutation"
            ),
            (
                "head-ambiguous-after-side-effect",
                .head,
                "record and new head exist but caller observes an error",
                "writer must poison and reopen because disk authority may already be new"
            ),
            (
                "directory-sync-fault-after-head",
                .head,
                "record and new head are process-visible; directory fsync is omitted/fails",
                "writer must poison and reopen; this is not a power-loss durability claim"
            ),
            (
                "complete",
                .synchronized,
                "record, head, and directory fsync complete",
                "new state may be adopted by the actor"
            ),
        ]

        var rows: [DirectoryHeadFaultShadowReport.Case] = []
        for (index, specification) in specifications.enumerated() {
            let root = parent.appendingPathComponent("case-\(index)", isDirectory: true)
            try createPrivateDirectory(root)
            try initializeHeads(root: root, generation: processTestGeneration)
            let prepared = try prepareProcessTestMutation(root: root)
            switch specification.1 {
            case .empty:
                break
            case .record:
                try DirectoryHeadShadowIO.setAttribute(
                    prepared.recordIdentity.name,
                    value: prepared.recordData,
                    at: root,
                    flags: XATTR_CREATE
                )
            case .head:
                try DirectoryHeadShadowIO.setAttribute(
                    prepared.recordIdentity.name,
                    value: prepared.recordData,
                    at: root,
                    flags: XATTR_CREATE
                )
                try writeHead(prepared.nextHead, at: root, create: false)
            case .synchronized:
                try DirectoryHeadShadowIO.setAttribute(
                    prepared.recordIdentity.name,
                    value: prepared.recordData,
                    at: root,
                    flags: XATTR_CREATE
                )
                try writeHead(prepared.nextHead, at: root, create: false)
                try DirectoryHeadShadowIO.synchronize(root)
            }
            let recovered = try recover(root: root, generation: processTestGeneration, base: [:])
            let state: String
            if recovered.logical.isEmpty {
                state = "old-miss"
            } else if recovered.logical.count == 1 {
                state = "new-hit"
            } else {
                state = "unexpected"
            }
            let expected = switch specification.1 {
            case .empty, .record: "old-miss"
            case .head, .synchronized: "new-hit"
            }
            guard state == expected else { throw DirectoryHeadShadowError.stateMismatch }
            rows.append(
                .init(
                    id: specification.0,
                    simulatedSideEffect: specification.2,
                    recoveredState: state,
                    writerPolicy: specification.3
                )
            )
        }

        let report = DirectoryHeadFaultShadowReport(
            schemaVersion: 1,
            status: "passed",
            cases: rows,
            claims: .init(
                realSyscallFailureInjected: false,
                recoveryStateUsesRealXattrs: true,
                productionAuthorityChanged: false,
                processCrash: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
