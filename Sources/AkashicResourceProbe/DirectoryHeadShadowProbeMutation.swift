import AkashicCore
import AkashicDisk
import CryptoKit
import Darwin
import Dispatch
import Foundation

extension DirectoryHeadShadowProbe {
    static func runScale(arguments: [String]) throws {
        let values = try argumentValues(arguments)
        guard let rootValue = values["--root"],
            let payloadValue = values["--payload-count"],
            let deltaValue = values["--delta-keys"],
            let iterationValue = values["--iterations"],
            let payloadCount = Int(payloadValue), payloadCount >= 0,
            let deltaKeyCount = Int(deltaValue), (1...511).contains(deltaKeyCount),
            let iterations = Int(iterationValue), (1...200).contains(iterations)
        else { throw DirectoryHeadShadowError.invalidArguments }

        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try createPrivateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeHeads(root: root, generation: processTestGeneration)

        let identities = try identityPool(count: deltaKeyCount)
        for (index, identity) in identities.enumerated() {
            let entry = FileBlobStoreRecordShadowEntry(
                physicalID: PhysicalBlobID(),
                partition: identity.partition,
                digest: identity.digest,
                byteCount: identity.byteCount,
                lastAccess: Date(timeIntervalSinceReferenceDate: Double(index + 1))
            )
            _ = try performMutation(
                root: root,
                generation: processTestGeneration,
                key: identity.key,
                entry: entry
            )
        }

        for _ in 0..<payloadCount {
            let name = UUID().uuidString.lowercased()
            let url = root.appendingPathComponent(name, isDirectory: false)
            let descriptor = Darwin.open(
                url.path,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw DirectoryHeadShadowError.posix(errno) }
            guard Darwin.close(descriptor) == 0 else {
                throw DirectoryHeadShadowError.posix(errno)
            }
        }

        for _ in 0..<3 {
            _ = try recover(root: root, generation: processTestGeneration, base: [:])
        }
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        var last: DirectoryHeadRecovered?
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            last = try recover(root: root, generation: processTestGeneration, base: [:])
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
        }
        samples.sort()
        guard let last else { throw DirectoryHeadShadowError.stateMismatch }
        let report = DirectoryHeadScaleReport(
            schemaVersion: 1,
            payloadEntryCount: payloadCount,
            deltaKeyCount: deltaKeyCount,
            recordAttributeCount: last.recordIdentities.count,
            iterations: iterations,
            medianRecoveryNanoseconds: samples[samples.count / 2],
            logicalEntryCount: last.logical.count,
            claims: .init(
                formalPerformance: false,
                physicalDevice: false,
                productionAuthorityChanged: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func prepareProcessTestMutation(root: URL) throws -> (
        recordIdentity: DirectoryHeadRecordIdentity,
        recordData: Data,
        nextHead: DirectoryHeadValue
    ) {
        let recovered = try recover(root: root, generation: processTestGeneration, base: [:])
        guard recovered.activeHead.s == 0, recovered.logical.isEmpty else {
            throw DirectoryHeadShadowError.stateMismatch
        }
        let identity = try processTestIdentity()
        let entry = FileBlobStoreRecordShadowEntry(
            physicalID: PhysicalBlobID(),
            partition: identity.partition,
            digest: identity.digest,
            byteCount: identity.byteCount,
            lastAccess: Date(timeIntervalSinceReferenceDate: 1)
        )
        let mutation = FileBlobStoreRecordShadowMutation(
            generation: processTestGeneration,
            sequence: 1,
            key: identity.key,
            entry: entry
        )
        let data = try FileBlobStore.resourceProbeEncodeManifestRecord(mutation)
        let recordIdentity = try DirectoryHeadRecordIdentity.make(
            generation: processTestGeneration,
            sequence: 1,
            key: identity.key
        )
        let nextHead = try makeHead(
            generation: processTestGeneration,
            slot: 1,
            sequence: 1,
            count: 1,
            root: try leaf(identity: recordIdentity, recordData: data)
        )
        return (recordIdentity, data, nextHead)
    }

    static func crashChild(arguments: [String]) throws {
        let values = try argumentValues(arguments)
        guard let rootValue = values["--root"],
            let phase = values["--phase"],
            ["after-record", "after-head", "after-directory-sync"].contains(phase)
        else { throw DirectoryHeadShadowError.invalidArguments }
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let prepared = try prepareProcessTestMutation(root: root)
        try DirectoryHeadShadowIO.setAttribute(
            prepared.recordIdentity.name,
            value: prepared.recordData,
            at: root,
            flags: XATTR_CREATE
        )
        if phase == "after-record" { Darwin._exit(71) }

        try writeHead(prepared.nextHead, at: root, create: false)
        if phase == "after-head" { Darwin._exit(72) }

        try DirectoryHeadShadowIO.synchronize(root)
        if phase == "after-directory-sync" { Darwin._exit(73) }
        throw DirectoryHeadShadowError.invalidArguments
    }

    static func crashRandomChild(arguments: [String]) throws {
        let values = try argumentValues(arguments)
        guard let rootValue = values["--root"] else {
            throw DirectoryHeadShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: rootValue, isDirectory: true)
        let prepared = try prepareProcessTestMutation(root: root)
        try DirectoryHeadShadowIO.setAttribute(
            prepared.recordIdentity.name,
            value: prepared.recordData,
            at: root,
            flags: XATTR_CREATE
        )
        FileHandle.standardOutput.write(Data("HEAD_READY\n".utf8))

        // Deliberately widen the three process-visible states so an external SIGKILL campaign can
        // sample before head publication, after head publication, and after directory fsync. These
        // sleeps are synchronization instrumentation, not part of the candidate transaction.
        _ = Darwin.usleep(1_500)
        try writeHead(prepared.nextHead, at: root, create: false)
        _ = Darwin.usleep(1_500)
        try DirectoryHeadShadowIO.synchronize(root)
        _ = Darwin.usleep(1_500)
    }

    static func performMutation(
        root: URL,
        generation: UInt64,
        key: String,
        entry: FileBlobStoreRecordShadowEntry?
    ) throws -> MutationSample {
        var recovered = try recover(root: root, generation: generation, base: [:])

        let uncommitted = recovered.recordIdentities.filter {
            $0.generation == generation && $0.sequence > recovered.activeHead.s
        }
        if !uncommitted.isEmpty {
            for identity in uncommitted {
                try DirectoryHeadShadowIO.removeAttribute(identity.name, at: root)
            }
            // The next committed mutation reuses `head.sequence + 1`; make removal of any prior
            // crash intent durable before attempting XATTR_CREATE on that sequence again.
            try DirectoryHeadShadowIO.synchronize(root)
            recovered = try recover(root: root, generation: generation, base: [:])
        }

        let current = recovered.latest[key]
        let stale = recovered.recordIdentities.filter {
            $0.generation == generation
                && $0.sequence <= recovered.activeHead.s
                && $0.key == key
                && $0.sequence != current?.identity.sequence
        }
        guard stale.count <= 1 else { throw DirectoryHeadShadowError.invalidRecord }
        if let staleRecord = stale.first {
            try DirectoryHeadShadowIO.removeAttribute(staleRecord.name, at: root)
        }

        let sequence = recovered.activeHead.s.addingReportingOverflow(1)
        guard !sequence.overflow else { throw DirectoryHeadShadowError.invalidRecord }
        let mutation = FileBlobStoreRecordShadowMutation(
            generation: generation,
            sequence: sequence.partialValue,
            key: key,
            entry: entry
        )
        let recordData = try FileBlobStore.resourceProbeEncodeManifestRecord(mutation)
        let recordIdentity = try DirectoryHeadRecordIdentity.make(
            generation: generation,
            sequence: sequence.partialValue,
            key: key
        )
        try DirectoryHeadShadowIO.setAttribute(
            recordIdentity.name,
            value: recordData,
            at: root,
            flags: XATTR_CREATE
        )

        let newLeaf = try leaf(identity: recordIdentity, recordData: recordData)
        var rootCommitment = recovered.activeHead.r
        if let current {
            rootCommitment = xor(rootCommitment, current.leaf)
        }
        rootCommitment = xor(rootCommitment, newLeaf)
        let newCount = Int(recovered.activeHead.c) + (current == nil ? 1 : 0)
        guard newCount <= 511 else { throw DirectoryHeadShadowError.invalidHead }
        let inactiveSlot: UInt8 = recovered.activeSlot == 0 ? 1 : 0
        let nextHead = try makeHead(
            generation: generation,
            slot: inactiveSlot,
            sequence: sequence.partialValue,
            count: newCount,
            root: rootCommitment
        )
        let headData = try encodeHead(nextHead)
        let headName = DirectoryHeadIdentity(generation: generation, slot: inactiveSlot).name
        try DirectoryHeadShadowIO.setAttribute(
            headName,
            value: headData,
            at: root,
            flags: XATTR_REPLACE
        )
        try DirectoryHeadShadowIO.synchronize(root)

        return MutationSample(
            recordNameBytes: recordIdentity.name.utf8.count,
            recordValueBytes: recordData.count,
            headNameBytes: headName.utf8.count,
            headValueBytes: headData.count
        )
    }
}
