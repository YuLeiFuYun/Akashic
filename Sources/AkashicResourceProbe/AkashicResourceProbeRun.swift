import AkashicCore
import AkashicDisk
import Darwin
import Foundation

@main
enum AkashicResourceProbe {
    static func main() async throws {
        if CommandLine.arguments.count >= 2 {
            switch CommandLine.arguments[1] {
            case "checkpoint-phases":
                try await CheckpointPhaseProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "multiprocess-open-hold":
                try await MultiProcessOpenProbe.hold(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "multiprocess-open-attempt":
                try await MultiProcessOpenProbe.attempt(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "manifest-encode":
                try await ManifestEncodeProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "reopen-scaling":
                try await ReopenScalingProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "manifest-layout":
                try ManifestLayoutProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "record-replay":
                try await RecordReplayProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "xattr-shadow":
                try XattrShadowProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "directory-head-shadow":
                try DirectoryHeadShadowProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "directory-head-migration":
                try await DirectoryHeadMigrationProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "schema-open-control":
                try await SchemaOpenControlProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "schema3-carrier-loss":
                try await Schema3CarrierLossProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "legacy-xattr-maintenance":
                try await LegacyXattrMaintenanceProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "physical-debt-growth-current":
                try await PhysicalDebtGrowthProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "physical-debt-mixed-current":
                try await PhysicalDebtMixedProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-locality-io-current":
                try await SegmentedSchema5LocalityIOProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-locality-order-io-current":
                try await SegmentedSchema5LocalityOrderIOProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-epoch-operation-current":
                try await SegmentedSchema5EpochOperationProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-compound-preseal-crash":
                try await SegmentedSchema5CompoundPresealCrashProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-compound-preseal-crash-inspect":
                try await SegmentedSchema5CompoundPresealCrashProbe.inspect(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-v4-run-collapse-crash-seed":
                try await SegmentedSchema5V4RunCollapseCrashProbe.seed(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-v4-run-collapse-crash":
                try await SegmentedSchema5V4RunCollapseCrashProbe.crash(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-v4-run-collapse-crash-inspect":
                try await SegmentedSchema5V4RunCollapseCrashProbe.inspect(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-collapse-current":
                try await SegmentedSchema5StablePrefixCollapseProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-collapse-crash":
                try await SegmentedSchema5StablePrefixCollapseCrashProbe.crash(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-collapse-crash-inspect":
                try await SegmentedSchema5StablePrefixCollapseCrashProbe.inspect(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-materialization-crash":
                try await SegmentedSchema5StablePrefixCollapseCrashProbe.materializationCrash(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-materialization-crash-inspect":
                try await SegmentedSchema5StablePrefixCollapseCrashProbe.materializationInspect(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-concurrency-current":
                try await SegmentedSchema5StablePrefixConcurrencyProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-resource-current":
                try await SegmentedSchema5StablePrefixResourceProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-incompressible-current":
                try await SegmentedSchema5StablePrefixIncompressibleProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-automatic-current":
                try await SegmentedSchema5StablePrefixAutomaticProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-automatic-deadline-current":
                try await SegmentedSchema5StablePrefixAutomaticDeadlineProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-suffix-erosion-current":
                try await SegmentedSchema5StablePrefixSuffixErosionProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-retry-eligibility-current":
                try await SegmentedSchema5StablePrefixRetryEligibilityProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-segment-debt-headroom-current":
                try await SegmentedSchema5SegmentDebtHeadroomProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-hardcap-debt-fallback-current":
                try await SegmentedSchema5HardCapDebtFallbackProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-hardcap-minimum-rescue-current":
                try await SegmentedSchema5HardCapMinimumRescueProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-rescue-debt-self-restoration-current":
                try await SegmentedSchema5RescueDebtSelfRestorationProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            case "segmented-schema5-stable-prefix-weak-gain-current":
                try await SegmentedSchema5StablePrefixWeakGainProbe.run(
                    arguments: Array(CommandLine.arguments.dropFirst(2))
                )
                return
            default:
                let researchArguments = Array(CommandLine.arguments.dropFirst(2))
                if try await CacheReadResearchCommand.dispatch(
                    CommandLine.arguments[1], arguments: researchArguments
                ) { return }
                if try await SegmentedManifestShadowProbe.dispatchResearchCommand(
                    CommandLine.arguments[1], arguments: researchArguments
                ) { return }
                break
            }
        }
        let configuration = try ProbeConfiguration.parse(CommandLine.arguments)
        try resetRoot(configuration.root)
        let logicalPayloadBytes = try checkedProduct(
            configuration.blobCount,
            configuration.blobBytes
        )
        let inputs = try makeInputs(configuration)
        if configuration.preseedStore {
            try await prepareStore(
                root: configuration.root,
                softLimitBytes: logicalPayloadBytes,
                migrateDirectoryHead: configuration.useDirectoryHead
            )
        }

        var maximumFDs = sampledOpenFileDescriptors()
        try configuration.measurementBarrier?.waitForMeasurementStart()
        let population = try await populate(
            root: configuration.root,
            inputs: inputs,
            softLimitBytes: logicalPayloadBytes,
            countInitialMetadata: !configuration.preseedStore,
            forceSidecarFastCommit: configuration.forceSidecarFastCommit,
            maximumFDs: &maximumFDs
        )
        try configuration.measurementBarrier?.waitForMeasurementRelease()

        for _ in 0 ..< 64 {
            await Task.yield()
        }
        let reopenStarted = DispatchTime.now().uptimeNanoseconds
        let reopened = try await FileBlobStore.open(
            root: configuration.root,
            softLimitBytes: Int(logicalPayloadBytes)
        )
        let reopenNanoseconds = DispatchTime.now().uptimeNanoseconds &- reopenStarted
        maximumFDs = max(maximumFDs, sampledOpenFileDescriptors())

        let readStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< configuration.readPasses {
            for input in inputs {
                let restored = try await reopened.read(
                    digest: input.digest,
                    partition: input.partition
                )
                guard restored == input.data else { throw ProbeError.payloadMismatch }
                maximumFDs = max(maximumFDs, sampledOpenFileDescriptors())
            }
        }
        let readNanoseconds = DispatchTime.now().uptimeNanoseconds &- readStarted
        let logicalReadBytes = try checkedProduct(
            logicalPayloadBytes,
            Int64(configuration.readPasses)
        )
        let footprint = try measureFootprint(root: configuration.root)
        let usage = try processUsage(sampledOpenFileDescriptors: maximumFDs)
        let amplification = Double(
            logicalPayloadBytes + population.logicalMetadataWriteBytes
        ) / Double(logicalPayloadBytes)

        let report = ProbeReport(
            schemaVersion: 3,
            workloadID: "blob-\(configuration.blobCount)x\(configuration.blobBytes)-read-\(configuration.readPasses)"
                + (configuration.useDirectoryHead ? "-directory-head" : "")
                + (configuration.preseedStore && !configuration.useDirectoryHead ? "-preseed" : "")
                + (configuration.forceSidecarFastCommit ? "-forced-sidecar-fast-commit" : "-native-fast-commit"),
            architecture: architectureName,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            blobCount: configuration.blobCount,
            blobBytes: configuration.blobBytes,
            readPasses: configuration.readPasses,
            logicalPayloadBytes: logicalPayloadBytes,
            logicalReadBytes: logicalReadBytes,
            logicalMetadataWriteBytes: population.logicalMetadataWriteBytes,
            logicalWriteAmplification: amplification,
            commitNanoseconds: population.commitNanoseconds,
            reopenNanoseconds: reopenNanoseconds,
            readNanoseconds: readNanoseconds,
            footprint: footprint,
            usage: usage,
            claims: Claims(
                energy: false,
                physicalDevice: false,
                physicalIOBytes: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileHandle.standardOutput.write(encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func resetRoot(_ root: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) {
            try manager.removeItem(at: root)
        }
    }

    private static func makeInputs(_ configuration: ProbeConfiguration) throws -> [InputBlob] {
        var result: [InputBlob] = []
        result.reserveCapacity(configuration.blobCount)
        for index in 0 ..< configuration.blobCount {
            var data = Data(count: configuration.blobBytes)
            data.withUnsafeMutableBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for offset in 0 ..< bytes.count {
                    bytes[offset] = UInt8(truncatingIfNeeded: (index &* 131) ^ offset)
                }
            }
            let partition = try CachePartitionID.derive(
                domain: "akashic-resource-probe-v1",
                material: Data([UInt8(truncatingIfNeeded: index % 2)])
            )
            result.append(
                InputBlob(
                    data: data,
                    digest: BlobDigest.sha256(of: data),
                    partition: partition
                )
            )
        }
        return result
    }

    private static func prepareStore(
        root: URL,
        softLimitBytes: Int64,
        migrateDirectoryHead: Bool
    ) async throws {
        guard softLimitBytes <= Int64(Int.max) else { throw ProbeError.arithmeticOverflow }
        let store = try await FileBlobStore.open(
            root: root,
            softLimitBytes: Int(softLimitBytes)
        )
        if migrateDirectoryHead {
            guard try await store.migrateLegacyManifestToDirectoryHeadSchema4() else {
                throw ProbeError.directoryHeadUnavailable
            }
        }
    }

    private static func populate(
        root: URL,
        inputs: [InputBlob],
        softLimitBytes: Int64,
        countInitialMetadata: Bool,
        forceSidecarFastCommit: Bool,
        maximumFDs: inout Int
    ) async throws -> PopulationResult {
        guard softLimitBytes <= Int64(Int.max) else { throw ProbeError.arithmeticOverflow }
        let openStarted = DispatchTime.now().uptimeNanoseconds
        let store: FileBlobStore
        if forceSidecarFastCommit {
            store = try await FileBlobStore.open(
                root: root,
                limits: FileBlobStoreLimits(
                    softTotalBytes: Int(softLimitBytes),
                    maximumBlobBytes: Int(softLimitBytes)
                ),
                faultInjector: { _ in },
                fastCommitOperations: forcedSidecarFastCommitOperations
            )
        } else {
            store = try await FileBlobStore.open(
                root: root,
                softLimitBytes: Int(softLimitBytes)
            )
        }
        var commitNanoseconds = DispatchTime.now().uptimeNanoseconds &- openStarted
        var previousMetadata = try metadataSnapshot(root: root)
        var logicalMetadataWriteBytes: Int64 = 0
        if countInitialMetadata {
            logicalMetadataWriteBytes = try previousMetadata.values.reduce(Int64(0)) {
                try checkedSum($0, Int64($1.count))
            }
        }
        for input in inputs {
            let commitStarted = DispatchTime.now().uptimeNanoseconds
            _ = try await store.commit(
                data: input.data,
                digest: input.digest,
                partition: input.partition
            )
            commitNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- commitStarted

            let currentMetadata = try metadataSnapshot(root: root)
            for (path, data) in currentMetadata where previousMetadata[path] != data {
                logicalMetadataWriteBytes = try checkedSum(
                    logicalMetadataWriteBytes,
                    Int64(data.count)
                )
            }
            previousMetadata = currentMetadata
            maximumFDs = max(maximumFDs, sampledOpenFileDescriptors())
        }
        return PopulationResult(
            commitNanoseconds: commitNanoseconds,
            logicalMetadataWriteBytes: logicalMetadataWriteBytes
        )
    }

    /// Same real fast-commit syscall table except that the manifest-xattr capability probe is
    /// forced to the production `ENOTSUP` fallback. This is a resource-control seam: it exercises
    /// the real sidecar transaction on the same filesystem without changing payload, fsync or
    /// rename behavior.
    private static var forcedSidecarFastCommitOperations: FileBlobStoreFastCommitOperations {
        FileBlobStoreFastCommitOperations(
            setManifestXattr: { _, _, _ in
                errno = ENOTSUP
                return -1
            }
        )
    }

    private static func processUsage(sampledOpenFileDescriptors: Int) throws -> ResourceUsage {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw ProbeError.resourceSampleFailed
        }
        return ResourceUsage(
            maximumResidentBytes: Int64(usage.ru_maxrss),
            sampledOpenFileDescriptors: sampledOpenFileDescriptors,
            systemCPUNanoseconds: timevalNanoseconds(usage.ru_stime),
            userCPUNanoseconds: timevalNanoseconds(usage.ru_utime)
        )
    }

    private static func sampledOpenFileDescriptors() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return -1
        }
        return names.reduce(into: 0) { count, name in
            if Int(name) != nil {
                count += 1
            }
        }
    }

    private static func timevalNanoseconds(_ value: timeval) -> UInt64 {
        let seconds = UInt64(max(0, value.tv_sec))
        let microseconds = UInt64(max(0, value.tv_usec))
        return seconds &* 1_000_000_000 &+ microseconds &* 1000
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int64 {
        try checkedProduct(Int64(lhs), Int64(rhs))
    }

    private static func checkedProduct(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw ProbeError.arithmeticOverflow }
        return result.partialValue
    }

    static func checkedSum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ProbeError.arithmeticOverflow }
        return result.partialValue
    }

    private static var architectureName: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }
}
