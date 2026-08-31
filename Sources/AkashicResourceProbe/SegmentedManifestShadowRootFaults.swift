import AkashicCore
import CryptoKit
import Foundation

struct SegmentedShadowRootPublicationFaultResult: Codable {
    let runDurableWithoutRootPreservesOldState: Bool
    let preRenameRootFaultPreservesOldState: Bool
    let postRenameRootFaultRecoversNewState: Bool
    let oldGeneration: UInt64
    let newGeneration: UInt64
}

extension SegmentedManifestShadowProbe {
    static func rootPublicationFaults(
        root: URL,
        segmentDirectory: URL,
        base: SegmentedShadowDescriptor,
        run: SegmentedShadowDescriptor,
        oldState: [String: SegmentedShadowEntry],
        newState: [String: SegmentedShadowEntry]
    ) throws -> SegmentedShadowRootPublicationFaultResult {
        let oldRoot = try makeRoot(generation: 10, base: base, runs: [])
        let newRoot = try makeRoot(generation: 11, base: base, runs: [run])
        let rootURL = root.appendingPathComponent("fault-root.json")
        try DurableFileWriter.writeReplacing(try encodeRoot(oldRoot), to: rootURL)

        // The run file is already complete and durable at this point, but an unreferenced segment
        // is only physical metadata. Root authority still reconstructs the old state.
        let runDurableWithoutRootPreservesOldState = try recoverRootState(
            rootURL: rootURL,
            segmentDirectory: segmentDirectory
        ) == oldState
        guard runDurableWithoutRootPreservesOldState else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        do {
            try DurableFileWriter.writeReplacing(
                try encodeRoot(newRoot),
                to: rootURL,
                faultInjector: { point in
                    if point == .afterFileSynced { throw POSIXError(.EIO) }
                }
            )
            throw SegmentedManifestShadowError.invariantViolation
        } catch is POSIXError {
        }
        let preRenameRootFaultPreservesOldState = try recoverRootState(
            rootURL: rootURL,
            segmentDirectory: segmentDirectory
        ) == oldState
        guard preRenameRootFaultPreservesOldState else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        do {
            try DurableFileWriter.writeReplacing(
                try encodeRoot(newRoot),
                to: rootURL,
                faultInjector: { point in
                    if point == .afterRename { throw POSIXError(.EIO) }
                }
            )
            throw SegmentedManifestShadowError.invariantViolation
        } catch is POSIXError {
        }
        let postRenameRootFaultRecoversNewState = try recoverRootState(
            rootURL: rootURL,
            segmentDirectory: segmentDirectory
        ) == newState
        guard postRenameRootFaultRecoversNewState else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        return SegmentedShadowRootPublicationFaultResult(
            runDurableWithoutRootPreservesOldState: true,
            preRenameRootFaultPreservesOldState: true,
            postRenameRootFaultRecoversNewState: true,
            oldGeneration: oldRoot.generation,
            newGeneration: newRoot.generation
        )
    }

    static func encodeRoot(_ root: SegmentedShadowRoot) throws -> Data {
        try validateRootStructure(root)
        guard try validateRootSeal(root) else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(root)
        guard data.count <= maximumRootBytes else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        return data
    }

    static func recoverRootState(
        rootURL: URL,
        segmentDirectory: URL
    ) throws -> [String: SegmentedShadowEntry] {
        let data = try BoundedFileReader.read(from: rootURL, maximumBytes: maximumRootBytes)
        let root = try JSONDecoder().decode(SegmentedShadowRoot.self, from: data)
        try validateRootStructure(root)
        guard try validateRootSeal(root) else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        var state = Dictionary(
            uniqueKeysWithValues: try readBase(root.base, directory: segmentDirectory).map { ($0.key, $0) }
        )
        for descriptor in root.runs {
            state = try apply(try readRun(descriptor, directory: segmentDirectory), to: state)
        }
        return state
    }
}
