import AkashicCore
import Foundation

package struct SegmentedManifestRunCollapsePlanV1: Sendable {
    package let frozenRoot: SegmentedManifestRootV1
    package let replacementMutationRuns: [[SegmentedManifestMutation]]
    package let touchedKeyCount: Int
    package let finalUpsertCount: Int
    package let inputRunCount: Int
    package let outputRunCount: Int
    package let inputRunBytes: Int
    package let outputRunBytes: Int
}

/// Bounded run-only topology reduction for segmented manifest V3/V4.
///
/// The planner never reads the base. It derives the complete touched-key set and each touched key's
/// final mutation from the immutable run vector, then emits two replay-safe phases:
///
/// 1. tombstone every touched key, releasing any base/run physical ownership;
/// 2. upsert each touched key whose final mutation is an upsert.
///
/// This is deliberately more conservative than arbitrary latest-per-key chunking. Splitting latest
/// mutations directly can place a PhysicalBlobID acquisition in an earlier replacement run than the
/// tombstone that releases its previous owner. The release-all phase prevents that transient replay
/// collision without scanning O(live) base state.
package enum SegmentedManifestRunCollapseV1 {
    package static func plan(
        frozenRoot: SegmentedManifestRootV1,
        segmentDirectory: URL,
        cancellationCheck: (@Sendable () throws -> Void)? = nil
    ) throws -> SegmentedManifestRunCollapsePlanV1? {
        guard (frozenRoot.profile == SegmentedManifestPrototypeV1.profileV3
                || frozenRoot.profile == SegmentedManifestPrototypeV1.profileV4),
            frozenRoot.base.kind == .baseBinaryV2,
            !frozenRoot.runs.isEmpty,
            frozenRoot.runs.count <= SegmentedManifestPrototypeV1.maximumRunDescriptors
        else { throw AkashicError.invalidManifest }

        var latestByKey: [String: SegmentedManifestMutation] = [:]
        latestByKey.reserveCapacity(
            min(
                frozenRoot.runs.count * SegmentedManifestPrototypeV1.maximumRunRecords,
                SegmentedManifestPrototypeV1.maximumRunDescriptors
                    * SegmentedManifestPrototypeV1.maximumRunRecords
            )
        )
        var inputRunBytes = 0
        for descriptor in frozenRoot.runs {
            try cancellationCheck?()
            let nextBytes = inputRunBytes.addingReportingOverflow(descriptor.byteCount)
            guard !nextBytes.overflow else { throw AkashicError.invalidManifest }
            inputRunBytes = nextBytes.partialValue
            let mutations = try SegmentedManifestPrototypeV1.readRun(
                descriptor,
                directory: segmentDirectory
            )
            for mutation in mutations { latestByKey[mutation.key] = mutation }
        }
        guard !latestByKey.isEmpty else { throw AkashicError.invalidManifest }

        let sortedKeys = latestByKey.keys.sorted()
        let releases = sortedKeys.map { SegmentedManifestMutation.tombstone(key: $0) }
        let finalUpserts = sortedKeys.compactMap { key -> SegmentedManifestMutation? in
            guard let mutation = latestByKey[key], case .upsert = mutation else { return nil }
            return mutation
        }
        let replacement = chunk(releases) + chunk(finalUpserts)
        guard !replacement.isEmpty else { throw AkashicError.invalidManifest }

        // This primitive exists to buy descriptor headroom. No materialization is allowed when the
        // exact replay-safe geometry does not strictly improve the root descriptor count.
        guard replacement.count < frozenRoot.runs.count,
            replacement.count <= SegmentedManifestPrototypeV1.maximumRunDescriptors
        else { return nil }

        var outputRunBytes = 0
        for run in replacement {
            try cancellationCheck?()
            let encoded = try SegmentedManifestPrototypeV1.encodeRun(run)
            let nextBytes = outputRunBytes.addingReportingOverflow(encoded.count)
            guard !nextBytes.overflow else { throw AkashicError.invalidManifest }
            outputRunBytes = nextBytes.partialValue
        }
        let referenced = frozenRoot.base.byteCount.addingReportingOverflow(outputRunBytes)
        guard !referenced.overflow,
            referenced.partialValue <= SegmentedManifestPrototypeV1.maximumReferencedSegmentBytes
        else { return nil }

        return SegmentedManifestRunCollapsePlanV1(
            frozenRoot: frozenRoot,
            replacementMutationRuns: replacement,
            touchedKeyCount: sortedKeys.count,
            finalUpsertCount: finalUpserts.count,
            inputRunCount: frozenRoot.runs.count,
            outputRunCount: replacement.count,
            inputRunBytes: inputRunBytes,
            outputRunBytes: outputRunBytes
        )
    }

    private static func chunk(
        _ mutations: [SegmentedManifestMutation]
    ) -> [[SegmentedManifestMutation]] {
        guard !mutations.isEmpty else { return [] }
        var result: [[SegmentedManifestMutation]] = []
        result.reserveCapacity(
            (mutations.count + SegmentedManifestPrototypeV1.maximumRunRecords - 1)
                / SegmentedManifestPrototypeV1.maximumRunRecords
        )
        var offset = 0
        while offset < mutations.count {
            let end = min(
                mutations.count,
                offset + SegmentedManifestPrototypeV1.maximumRunRecords
            )
            result.append(Array(mutations[offset..<end]))
            offset = end
        }
        return result
    }
}
