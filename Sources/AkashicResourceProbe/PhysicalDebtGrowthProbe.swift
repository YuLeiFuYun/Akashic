import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct PhysicalDebtGrowthIdentity {
    let label: String
    let data: Data
    let digest: BlobDigest
    let partition: CachePartitionID
}

private struct PhysicalDebtGrowthStep: Codable {
    let cycle: Int
    let removedLabel: String
    let addedLabel: String
    let debtCountAfterRemove: Int
    let debtBytesAfterRemove: Int64
    let physicalPayloadFileCountAfterRemove: Int
    let physicalPayloadBytesAfterRemove: Int64
    let liveCountAfterRefill: Int
    let liveBytesAfterRefill: Int64
    let debtCountAfterRefill: Int
    let debtBytesAfterRefill: Int64
    let physicalPayloadFileCountAfterRefill: Int
    let physicalPayloadBytesAfterRefill: Int64
}

private struct PhysicalDebtGrowthReport: Codable {
    struct Claims: Codable {
        let formalPerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let independentDebtBudgetPresent: Bool
    }

    let schemaVersion: Int
    let blobBytes: Int
    let steadyLiveCount: Int
    let softLiveByteLimit: Int
    let cycles: Int
    let steps: [PhysicalDebtGrowthStep]
    let finalLiveBytesBeforeRepayment: Int64
    let finalDebtCountBeforeRepayment: Int
    let finalDebtBytesBeforeRepayment: Int64
    let finalPhysicalPayloadBytesBeforeRepayment: Int64
    let physicalPayloadToLiveLimitRatioBeforeRepayment: Double
    let reopenSucceededWhileDebtImmutable: Bool
    let reopenErrorWhileDebtImmutable: String?
    let liveAuthorityExactAfterReopen: Bool
    let debtCountAfterRepayment: Int
    let debtBytesAfterRepayment: Int64
    let finalPhysicalPayloadBytesAfterRepayment: Int64
    let liveAuthorityExactAfterRepayment: Bool
    let debtGrowthObserved: Bool
    let softLiveLimitDidNotBoundPhysicalPayloadBytes: Bool
    let claims: Claims
}

enum PhysicalDebtGrowthProbe {
    private static let blobBytes = 64 * 1_024
    private static let steadyLiveCount = 4
    private static let cycles = 8

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw ProbeError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            try manager.removeItem(at: root)
        }
        let softLimit = steadyLiveCount * blobBytes
        let identities = try (0..<(steadyLiveCount + cycles)).map(makeIdentity)
        var immutableDebtURLs: [URL] = []
        defer {
            for url in immutableDebtURLs where manager.fileExists(atPath: url.path) {
                _ = Darwin.chflags(url.path, 0)
            }
        }

        var store: FileBlobStore? = try await FileBlobStore.open(
            root: root,
            softLimitBytes: softLimit
        )
        var liveQueue: [Int] = []
        var livePhysical: [Int: String] = [:]
        for index in 0..<steadyLiveCount {
            let identity = identities[index]
            _ = try await store!.commit(
                data: identity.data,
                digest: identity.digest,
                partition: identity.partition
            )
            guard let physical = await store!.physicalID(
                digest: identity.digest,
                partition: identity.partition
            ) else { throw ProbeError.resourceSampleFailed }
            liveQueue.append(index)
            livePhysical[index] = physical.rawValue.uuidString.lowercased()
        }

        var steps: [PhysicalDebtGrowthStep] = []
        var debtURLs: [URL] = []
        for cycle in 0..<cycles {
            let removedIndex = liveQueue.removeFirst()
            let removed = identities[removedIndex]
            guard let physicalString = livePhysical.removeValue(forKey: removedIndex) else {
                throw ProbeError.resourceSampleFailed
            }
            let payloadURL = root
                .appendingPathComponent("blobs", isDirectory: true)
                .appendingPathComponent(physicalString, isDirectory: false)
            guard Darwin.chflags(payloadURL.path, UInt32(UF_IMMUTABLE)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            immutableDebtURLs.append(payloadURL)
            try await store!.remove(
                digest: removed.digest,
                partition: removed.partition
            )
            guard await store!.physicalID(
                digest: removed.digest,
                partition: removed.partition
            ) == nil else { throw ProbeError.resourceSampleFailed }
            do {
                _ = try await store!.read(
                    digest: removed.digest,
                    partition: removed.partition
                )
                throw ProbeError.resourceSampleFailed
            } catch AkashicError.notFound {
                // Expected logical authority after remove.
            }
            guard manager.fileExists(atPath: payloadURL.path) else {
                throw ProbeError.resourceSampleFailed
            }
            debtURLs.append(payloadURL)
            let afterRemove = try payloadFootprint(root: root)
            let debtAfterRemove = try debtFootprint(debtURLs)

            let addedIndex = steadyLiveCount + cycle
            let added = identities[addedIndex]
            _ = try await store!.commit(
                data: added.data,
                digest: added.digest,
                partition: added.partition
            )
            guard let addedPhysical = await store!.physicalID(
                digest: added.digest,
                partition: added.partition
            ) else { throw ProbeError.resourceSampleFailed }
            liveQueue.append(addedIndex)
            livePhysical[addedIndex] = addedPhysical.rawValue.uuidString.lowercased()
            let afterRefill = try payloadFootprint(root: root)
            let debtAfterRefill = try debtFootprint(debtURLs)
            let liveBytes = Int64(liveQueue.count * blobBytes)
            guard liveQueue.count == steadyLiveCount,
                liveBytes == Int64(softLimit)
            else { throw ProbeError.resourceSampleFailed }

            steps.append(
                PhysicalDebtGrowthStep(
                    cycle: cycle,
                    removedLabel: removed.label,
                    addedLabel: added.label,
                    debtCountAfterRemove: debtAfterRemove.count,
                    debtBytesAfterRemove: debtAfterRemove.bytes,
                    physicalPayloadFileCountAfterRemove: afterRemove.count,
                    physicalPayloadBytesAfterRemove: afterRemove.bytes,
                    liveCountAfterRefill: liveQueue.count,
                    liveBytesAfterRefill: liveBytes,
                    debtCountAfterRefill: debtAfterRefill.count,
                    debtBytesAfterRefill: debtAfterRefill.bytes,
                    physicalPayloadFileCountAfterRefill: afterRefill.count,
                    physicalPayloadBytesAfterRefill: afterRefill.bytes
                )
            )
        }

        let finalDebtBefore = try debtFootprint(debtURLs)
        let finalPayloadBefore = try payloadFootprint(root: root)
        let expectedLiveMapping = livePhysical
        store = nil

        var reopenSucceeded = false
        var reopenError: String?
        var liveExactAfterReopen = false
        do {
            store = try await FileBlobStore.open(root: root, softLimitBytes: softLimit)
            reopenSucceeded = true
            liveExactAfterReopen = await liveMappingExact(
                store: store!,
                identities: identities,
                expected: expectedLiveMapping
            )
        } catch {
            reopenError = String(describing: error)
        }
        store = nil

        for url in immutableDebtURLs where manager.fileExists(atPath: url.path) {
            guard Darwin.chflags(url.path, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        immutableDebtURLs.removeAll()

        store = try await FileBlobStore.open(root: root, softLimitBytes: softLimit)
        let liveReferences = Set(expectedLiveMapping.keys.map { index in
            LiveBlobReference(
                partition: identities[index].partition,
                digest: identities[index].digest
            )
        })
        let maintenanceLimits = try BlobMaintenanceLimits(
            maximumReferenceCount: max(1, liveReferences.count),
            maximumReferencedBytes: max(1, liveReferences.count * blobBytes)
        )
        _ = try await store!.garbageCollect(
            retaining: liveReferences,
            limits: maintenanceLimits
        )
        let liveExactAfterRepayment = await liveMappingExact(
            store: store!,
            identities: identities,
            expected: expectedLiveMapping
        )
        let debtAfterRepayment = try debtFootprint(debtURLs)
        let payloadAfterRepayment = try payloadFootprint(root: root)
        let finalLiveBytes = Int64(steadyLiveCount * blobBytes)
        let ratio = Double(finalPayloadBefore.bytes) / Double(softLimit)
        let debtGrowthObserved = finalDebtBefore.count == cycles
            && finalDebtBefore.bytes == Int64(cycles * blobBytes)
        let softLimitDidNotBoundPhysical = finalPayloadBefore.bytes > Int64(softLimit)

        let report = PhysicalDebtGrowthReport(
            schemaVersion: 1,
            blobBytes: blobBytes,
            steadyLiveCount: steadyLiveCount,
            softLiveByteLimit: softLimit,
            cycles: cycles,
            steps: steps,
            finalLiveBytesBeforeRepayment: finalLiveBytes,
            finalDebtCountBeforeRepayment: finalDebtBefore.count,
            finalDebtBytesBeforeRepayment: finalDebtBefore.bytes,
            finalPhysicalPayloadBytesBeforeRepayment: finalPayloadBefore.bytes,
            physicalPayloadToLiveLimitRatioBeforeRepayment: ratio,
            reopenSucceededWhileDebtImmutable: reopenSucceeded,
            reopenErrorWhileDebtImmutable: reopenError,
            liveAuthorityExactAfterReopen: liveExactAfterReopen,
            debtCountAfterRepayment: debtAfterRepayment.count,
            debtBytesAfterRepayment: debtAfterRepayment.bytes,
            finalPhysicalPayloadBytesAfterRepayment: payloadAfterRepayment.bytes,
            liveAuthorityExactAfterRepayment: liveExactAfterRepayment,
            debtGrowthObserved: debtGrowthObserved,
            softLiveLimitDidNotBoundPhysicalPayloadBytes: softLimitDidNotBoundPhysical,
            claims: .init(
                formalPerformance: false,
                physicalIOBytes: false,
                physicalDevice: false,
                powerLoss: false,
                independentDebtBudgetPresent: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard debtGrowthObserved,
            softLimitDidNotBoundPhysical,
            reopenSucceeded,
            liveExactAfterReopen,
            debtAfterRepayment.count == 0,
            debtAfterRepayment.bytes == 0,
            liveExactAfterRepayment
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func makeIdentity(index: Int) throws -> PhysicalDebtGrowthIdentity {
        var data = Data(count: blobBytes)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for offset in bytes.indices {
                bytes[offset] = UInt8(truncatingIfNeeded: index &* 67 &+ offset &* 29)
            }
        }
        var bigEndian = UInt64(index).bigEndian
        let material = withUnsafeBytes(of: &bigEndian) { Data($0) }
        return PhysicalDebtGrowthIdentity(
            label: String(format: "debt-%02d", index),
            data: data,
            digest: BlobDigest.sha256(of: data),
            partition: try CachePartitionID.derive(
                domain: "akashic-physical-debt-growth-v1",
                material: material
            )
        )
    }

    private static func payloadFootprint(root: URL) throws -> (count: Int, bytes: Int64) {
        let directory = root.appendingPathComponent("blobs", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var count = 0
        var bytes: Int64 = 0
        for name in names {
            guard let uuid = UUID(uuidString: name),
                uuid.uuidString.lowercased() == name
            else { continue }
            var status = stat()
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            guard Darwin.lstat(path, &status) == 0 else { continue }
            guard (status.st_mode & S_IFMT) == S_IFREG else { continue }
            count += 1
            bytes += Int64(status.st_size)
        }
        return (count, bytes)
    }

    private static func debtFootprint(_ urls: [URL]) throws -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for url in urls {
            var status = stat()
            if Darwin.lstat(url.path, &status) == 0 {
                count += 1
                bytes += Int64(status.st_size)
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return (count, bytes)
    }

    private static func liveMappingExact(
        store: FileBlobStore,
        identities: [PhysicalDebtGrowthIdentity],
        expected: [Int: String]
    ) async -> Bool {
        for (index, physicalString) in expected {
            let identity = identities[index]
            guard let physical = await store.physicalID(
                digest: identity.digest,
                partition: identity.partition
            ), physical.rawValue.uuidString.lowercased() == physicalString
            else { return false }
            do {
                let data = try await store.read(
                    digest: identity.digest,
                    partition: identity.partition
                )
                if data != identity.data { return false }
            } catch {
                return false
            }
        }
        return true
    }
}
