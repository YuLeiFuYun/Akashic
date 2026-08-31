import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct PhysicalDebtMixedIdentity {
    let data: Data
    let digest: BlobDigest
    let partition: CachePartitionID
}

private struct PhysicalDebtMixedCase: Codable {
    let name: String
    let objectBytes: Int
    let steadyLiveCount: Int
    let softLiveByteLimit: Int
    let cycles: Int
    let finalLiveBytes: Int64
    let debtCountBeforeRepayment: Int
    let debtBytesBeforeRepayment: Int64
    let physicalPayloadCountBeforeRepayment: Int
    let physicalPayloadBytesBeforeRepayment: Int64
    let physicalPayloadToLiveLimitRatio: Double
    let reopenSucceededWithImmutableDebt: Bool
    let liveAuthorityExactAfterReopen: Bool
    let debtCountAfterRepayment: Int
    let debtBytesAfterRepayment: Int64
    let physicalPayloadBytesAfterRepayment: Int64
    let liveAuthorityExactAfterRepayment: Bool
}

private struct PhysicalDebtMixedReport: Codable {
    struct Claims: Codable {
        let formalPerformance: Bool
        let physicalIOBytes: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let independentDebtBudgetPresent: Bool
    }

    let schemaVersion: Int
    let softLiveByteLimit: Int
    let cases: [PhysicalDebtMixedCase]
    let equalCountPairShowsByteDivergence: Bool
    let equalDebtBytesPairShowsCountDivergence: Bool
    let allDebtRepaidExactly: Bool
    let allReopensPreserveLiveAuthority: Bool
    let claims: Claims
}

enum PhysicalDebtMixedProbe {
    private static let softLimit = 256 * 1_024

    static func run(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw ProbeError.invalidArguments
        }
        let rootBase = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let specs: [(String, Int, Int)] = [
            ("small-count-4", 4 * 1_024, 4),
            ("large-count-4", 256 * 1_024, 4),
            ("small-bytes-256k", 4 * 1_024, 64),
            ("large-bytes-256k", 256 * 1_024, 1),
        ]
        var cases: [PhysicalDebtMixedCase] = []
        for (name, objectBytes, cycles) in specs {
            let root = rootBase.appendingPathComponent(name, isDirectory: true)
            cases.append(
                try await runCase(
                    name: name,
                    root: root,
                    objectBytes: objectBytes,
                    cycles: cycles
                )
            )
        }

        func named(_ value: String) -> PhysicalDebtMixedCase {
            cases.first(where: { $0.name == value })!
        }
        let smallCount = named("small-count-4")
        let largeCount = named("large-count-4")
        let smallBytes = named("small-bytes-256k")
        let largeBytes = named("large-bytes-256k")
        let equalCountPairShowsByteDivergence =
            smallCount.debtCountBeforeRepayment == largeCount.debtCountBeforeRepayment
            && smallCount.debtBytesBeforeRepayment != largeCount.debtBytesBeforeRepayment
        let equalDebtBytesPairShowsCountDivergence =
            smallBytes.debtBytesBeforeRepayment == largeBytes.debtBytesBeforeRepayment
            && smallBytes.debtCountBeforeRepayment != largeBytes.debtCountBeforeRepayment
        let allDebtRepaidExactly = cases.allSatisfy {
            $0.debtCountAfterRepayment == 0
                && $0.debtBytesAfterRepayment == 0
                && $0.liveAuthorityExactAfterRepayment
        }
        let allReopensPreserveLiveAuthority = cases.allSatisfy {
            $0.reopenSucceededWithImmutableDebt && $0.liveAuthorityExactAfterReopen
        }

        let report = PhysicalDebtMixedReport(
            schemaVersion: 1,
            softLiveByteLimit: softLimit,
            cases: cases,
            equalCountPairShowsByteDivergence: equalCountPairShowsByteDivergence,
            equalDebtBytesPairShowsCountDivergence: equalDebtBytesPairShowsCountDivergence,
            allDebtRepaidExactly: allDebtRepaidExactly,
            allReopensPreserveLiveAuthority: allReopensPreserveLiveAuthority,
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
        guard equalCountPairShowsByteDivergence,
            equalDebtBytesPairShowsCountDivergence,
            allDebtRepaidExactly,
            allReopensPreserveLiveAuthority
        else { throw ProbeError.resourceSampleFailed }
    }

    private static func runCase(
        name: String,
        root: URL,
        objectBytes: Int,
        cycles: Int
    ) async throws -> PhysicalDebtMixedCase {
        precondition(softLimit % objectBytes == 0)
        let liveCount = softLimit / objectBytes
        let identityCount = liveCount + cycles
        let identities = try (0..<identityCount).map {
            try makeIdentity(caseName: name, index: $0, objectBytes: objectBytes)
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        var immutableURLs: [URL] = []
        defer {
            for url in immutableURLs where manager.fileExists(atPath: url.path) {
                _ = Darwin.chflags(url.path, 0)
            }
        }

        var store: FileBlobStore? = try await FileBlobStore.open(
            root: root,
            softLimitBytes: softLimit
        )
        var liveQueue: [Int] = []
        var livePhysical: [Int: String] = [:]
        for index in 0..<liveCount {
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
            immutableURLs.append(payloadURL)
            try await store!.remove(digest: removed.digest, partition: removed.partition)
            guard await store!.physicalID(
                digest: removed.digest,
                partition: removed.partition
            ) == nil,
                manager.fileExists(atPath: payloadURL.path)
            else { throw ProbeError.resourceSampleFailed }
            debtURLs.append(payloadURL)

            let addedIndex = liveCount + cycle
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
            guard liveQueue.count == liveCount else { throw ProbeError.resourceSampleFailed }
        }

        let debtBefore = try debtFootprint(debtURLs)
        let payloadBefore = try payloadFootprint(root: root)
        let expectedLive = livePhysical
        let finalLiveBytes = Int64(liveCount * objectBytes)
        guard finalLiveBytes == Int64(softLimit) else { throw ProbeError.resourceSampleFailed }
        store = nil

        var reopenSucceeded = false
        var liveExactAfterReopen = false
        do {
            store = try await FileBlobStore.open(root: root, softLimitBytes: softLimit)
            reopenSucceeded = true
            liveExactAfterReopen = await liveMappingExact(
                store: store!,
                identities: identities,
                expected: expectedLive
            )
        } catch {
            reopenSucceeded = false
        }
        store = nil

        for url in immutableURLs where manager.fileExists(atPath: url.path) {
            guard Darwin.chflags(url.path, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        immutableURLs.removeAll()
        store = try await FileBlobStore.open(root: root, softLimitBytes: softLimit)
        let liveReferences = Set(expectedLive.keys.map { index in
            LiveBlobReference(
                partition: identities[index].partition,
                digest: identities[index].digest
            )
        })
        let maintenanceLimits = try BlobMaintenanceLimits(
            maximumReferenceCount: max(1, liveReferences.count),
            maximumReferencedBytes: max(1, liveReferences.count * objectBytes)
        )
        _ = try await store!.garbageCollect(
            retaining: liveReferences,
            limits: maintenanceLimits
        )
        let liveExactAfterRepayment = await liveMappingExact(
            store: store!,
            identities: identities,
            expected: expectedLive
        )
        let debtAfter = try debtFootprint(debtURLs)
        let payloadAfter = try payloadFootprint(root: root)

        return PhysicalDebtMixedCase(
            name: name,
            objectBytes: objectBytes,
            steadyLiveCount: liveCount,
            softLiveByteLimit: softLimit,
            cycles: cycles,
            finalLiveBytes: finalLiveBytes,
            debtCountBeforeRepayment: debtBefore.count,
            debtBytesBeforeRepayment: debtBefore.bytes,
            physicalPayloadCountBeforeRepayment: payloadBefore.count,
            physicalPayloadBytesBeforeRepayment: payloadBefore.bytes,
            physicalPayloadToLiveLimitRatio: Double(payloadBefore.bytes) / Double(softLimit),
            reopenSucceededWithImmutableDebt: reopenSucceeded,
            liveAuthorityExactAfterReopen: liveExactAfterReopen,
            debtCountAfterRepayment: debtAfter.count,
            debtBytesAfterRepayment: debtAfter.bytes,
            physicalPayloadBytesAfterRepayment: payloadAfter.bytes,
            liveAuthorityExactAfterRepayment: liveExactAfterRepayment
        )
    }

    private static func makeIdentity(
        caseName: String,
        index: Int,
        objectBytes: Int
    ) throws -> PhysicalDebtMixedIdentity {
        var data = Data(count: objectBytes)
        let caseSeed = caseName.utf8.reduce(0) { ($0 &* 131) &+ Int($1) }
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for offset in bytes.indices {
                bytes[offset] = UInt8(truncatingIfNeeded: caseSeed &+ index &* 71 &+ offset &* 19)
            }
        }
        var materialValue = UInt64(truncatingIfNeeded: index ^ caseSeed).bigEndian
        let material = withUnsafeBytes(of: &materialValue) { Data($0) }
        return PhysicalDebtMixedIdentity(
            data: data,
            digest: BlobDigest.sha256(of: data),
            partition: try CachePartitionID.derive(
                domain: "akashic-physical-debt-mixed-v1-\(caseName)",
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
            guard let uuid = UUID(uuidString: name), uuid.uuidString.lowercased() == name else { continue }
            var status = stat()
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            guard Darwin.lstat(path, &status) == 0,
                (status.st_mode & S_IFMT) == S_IFREG
            else { continue }
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
        identities: [PhysicalDebtMixedIdentity],
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
