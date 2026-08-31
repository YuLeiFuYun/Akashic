import AkashicCore
import CryptoKit
import Darwin
import Foundation

struct SegmentedShadowWorkspaceResult: Codable {
    let validPrefixResumes: Bool
    let invalidatedPrefixBecomesDebt: Bool
    let corruptMarkerRejected: Bool
    let secondWorkspaceRejected: Bool
    let cleanupFailureBlocksReplacement: Bool
    let cleanupRecoveryCreatesSingleWorkspace: Bool
}

private struct SegmentedShadowWorkspaceMarker: Codable, Equatable {
    let schemaVersion: Int
    let workspaceID: String
    let frozenRoot: SegmentedShadowRoot
    let seal: String
}

private struct SegmentedShadowWorkspaceMarkerTranscript: Codable {
    let schemaVersion: Int
    let workspaceID: String
    let frozenRoot: SegmentedShadowRoot
}

private enum SegmentedShadowWorkspaceClassification {
    case none
    case resumable(URL)
    case stale(URL)
}

extension SegmentedManifestShadowProbe {
    static func workspaceRestartScenarios(
        root: URL,
        frozenRoot: SegmentedShadowRoot,
        baseData: Data
    ) throws -> SegmentedShadowWorkspaceResult {
        let parent = root.appendingPathComponent("compaction", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(parent)
        let workspace = try createWorkspace(
            parent: parent,
            frozenRoot: frozenRoot,
            candidateData: baseData
        )

        let validPrefixResumes: Bool
        switch try classifyWorkspace(parent: parent, currentRoot: frozenRoot) {
        case .resumable(let url):
            validPrefixResumes = sameWorkspacePath(url, workspace)
        default:
            validPrefixResumes = false
        }
        guard validPrefixResumes else { throw SegmentedManifestShadowError.workspaceInvariant("valid-prefix-resume") }

        let invalidatingRoot = try makeRoot(
            generation: frozenRoot.generation + 1,
            base: frozenRoot.base,
            runs: []
        )
        let invalidatedPrefixBecomesDebt: Bool
        switch try classifyWorkspace(parent: parent, currentRoot: invalidatingRoot) {
        case .stale(let url):
            invalidatedPrefixBecomesDebt = url == workspace
        default:
            invalidatedPrefixBecomesDebt = false
        }
        guard invalidatedPrefixBecomesDebt else {
            throw SegmentedManifestShadowError.workspaceInvariant("invalidated-prefix-debt")
        }

        let markerURL = workspace.appendingPathComponent("marker.json")
        let validMarkerData = try BoundedFileReader.read(from: markerURL, maximumBytes: maximumRootBytes * 2)
        var corruptMarker = validMarkerData
        guard !corruptMarker.isEmpty else { throw SegmentedManifestShadowError.workspaceInvariant("marker-empty") }
        corruptMarker[corruptMarker.startIndex] ^= 0x01
        try DurableFileWriter.writeReplacing(corruptMarker, to: markerURL)
        var corruptMarkerRejected = false
        do {
            _ = try classifyWorkspace(parent: parent, currentRoot: frozenRoot)
        } catch {
            corruptMarkerRejected = true
        }
        guard corruptMarkerRejected else { throw SegmentedManifestShadowError.workspaceInvariant("corrupt-marker-reject") }
        try DurableFileWriter.writeReplacing(validMarkerData, to: markerURL)

        let foreign = parent.appendingPathComponent("workspace-foreign", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(foreign)
        var secondWorkspaceRejected = false
        do {
            _ = try classifyWorkspace(parent: parent, currentRoot: frozenRoot)
        } catch {
            secondWorkspaceRejected = true
        }
        guard secondWorkspaceRejected else { throw SegmentedManifestShadowError.workspaceInvariant("second-workspace-reject") }
        try FileManager.default.removeItem(at: foreign)

        try setImmutable(true, url: markerURL)
        defer { try? setImmutable(false, url: markerURL) }
        let replacementRoot = invalidatingRoot
        let replacementURL = workspaceURL(parent: parent, frozenRoot: replacementRoot)
        var cleanupFailureBlocksReplacement = false
        do {
            _ = try prepareSingleWorkspace(
                parent: parent,
                currentRoot: invalidatingRoot,
                frozenRoot: replacementRoot,
                candidateData: baseData
            )
        } catch {
            cleanupFailureBlocksReplacement = !FileManager.default.fileExists(atPath: replacementURL.path)
        }
        guard cleanupFailureBlocksReplacement else {
            throw SegmentedManifestShadowError.workspaceInvariant("cleanup-failure-blocks-replacement")
        }
        try setImmutable(false, url: markerURL)

        let recoveredWorkspace = try prepareSingleWorkspace(
            parent: parent,
            currentRoot: invalidatingRoot,
            frozenRoot: replacementRoot,
            candidateData: baseData
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let cleanupRecoveryCreatesSingleWorkspace = entries.count == 1
            && entries.first.map { sameWorkspacePath($0, recoveredWorkspace) } == true
        guard cleanupRecoveryCreatesSingleWorkspace else {
            throw SegmentedManifestShadowError.workspaceInvariant("cleanup-recovery-single-workspace")
        }

        return SegmentedShadowWorkspaceResult(
            validPrefixResumes: true,
            invalidatedPrefixBecomesDebt: true,
            corruptMarkerRejected: true,
            secondWorkspaceRejected: true,
            cleanupFailureBlocksReplacement: true,
            cleanupRecoveryCreatesSingleWorkspace: true
        )
    }

    private static func prepareSingleWorkspace(
        parent: URL,
        currentRoot: SegmentedShadowRoot,
        frozenRoot: SegmentedShadowRoot,
        candidateData: Data
    ) throws -> URL {
        switch try classifyWorkspace(parent: parent, currentRoot: currentRoot) {
        case .none:
            break
        case .resumable(let existing):
            let expected = workspaceURL(parent: parent, frozenRoot: frozenRoot)
            guard existing == expected else { throw SegmentedManifestShadowError.invalidFormat }
            return existing
        case .stale(let stale):
            do {
                try FileManager.default.removeItem(at: stale)
            } catch {
                throw AkashicError.storageUnavailable
            }
        }
        return try createWorkspace(parent: parent, frozenRoot: frozenRoot, candidateData: candidateData)
    }

    private static func createWorkspace(
        parent: URL,
        frozenRoot: SegmentedShadowRoot,
        candidateData: Data
    ) throws -> URL {
        guard try validateRootSeal(frozenRoot) else { throw SegmentedManifestShadowError.invalidFormat }
        let url = workspaceURL(parent: parent, frozenRoot: frozenRoot)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        try StorageDirectorySecurity.prepareDirectory(url)
        let marker = try makeWorkspaceMarker(frozenRoot: frozenRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let markerData = try encoder.encode(marker)
        guard markerData.count <= maximumRootBytes * 2 else {
            throw SegmentedManifestShadowError.invalidFormat
        }
        // Marker must become durable before any compaction output appears in this workspace.
        try DurableFileWriter.writeReplacing(markerData, to: url.appendingPathComponent("marker.json"))
        try DurableFileWriter.writeReplacing(
            candidateData,
            to: url.appendingPathComponent("candidate-base.seg")
        )
        return url
    }

    private static func classifyWorkspace(
        parent: URL,
        currentRoot: SegmentedShadowRoot
    ) throws -> SegmentedShadowWorkspaceClassification {
        try StorageDirectorySecurity.validateDirectory(parent)
        let entries = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard entries.count <= 1 else { throw SegmentedManifestShadowError.invalidFormat }
        guard let workspace = entries.first else { return .none }
        try StorageDirectorySecurity.validateDirectory(workspace)
        let markerURL = workspace.appendingPathComponent("marker.json")
        let markerData = try BoundedFileReader.read(from: markerURL, maximumBytes: maximumRootBytes * 2)
        let marker = try JSONDecoder().decode(SegmentedShadowWorkspaceMarker.self, from: markerData)
        guard try validateWorkspaceMarker(marker),
            workspace.lastPathComponent == "workspace-\(marker.workspaceID)"
        else { throw SegmentedManifestShadowError.invalidFormat }
        return root(currentRoot, extends: marker.frozenRoot) ? .resumable(workspace) : .stale(workspace)
    }

    private static func root(_ current: SegmentedShadowRoot, extends frozen: SegmentedShadowRoot) -> Bool {
        guard (try? validateRootSeal(current)) == true,
            (try? validateRootSeal(frozen)) == true,
            current.generation >= frozen.generation,
            current.base == frozen.base,
            current.runs.count >= frozen.runs.count
        else { return false }
        return Array(current.runs.prefix(frozen.runs.count)) == frozen.runs
    }

    private static func workspaceURL(parent: URL, frozenRoot: SegmentedShadowRoot) -> URL {
        parent.appendingPathComponent("workspace-\(workspaceID(frozenRoot))", isDirectory: true)
    }

    private static func sameWorkspacePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func workspaceID(_ root: SegmentedShadowRoot) -> String {
        var input = Data("AKSEG-WORK-V1\0".utf8)
        input.append(Data(root.seal.utf8))
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeWorkspaceMarker(
        frozenRoot: SegmentedShadowRoot
    ) throws -> SegmentedShadowWorkspaceMarker {
        let transcript = SegmentedShadowWorkspaceMarkerTranscript(
            schemaVersion: 1,
            workspaceID: workspaceID(frozenRoot),
            frozenRoot: frozenRoot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(transcript)
        let seal = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return SegmentedShadowWorkspaceMarker(
            schemaVersion: transcript.schemaVersion,
            workspaceID: transcript.workspaceID,
            frozenRoot: frozenRoot,
            seal: seal
        )
    }

    private static func validateWorkspaceMarker(_ marker: SegmentedShadowWorkspaceMarker) throws -> Bool {
        guard marker.schemaVersion == 1,
            marker.workspaceID == workspaceID(marker.frozenRoot),
            try validateRootSeal(marker.frozenRoot)
        else { return false }
        let expected = try makeWorkspaceMarker(frozenRoot: marker.frozenRoot)
        return marker.seal == expected.seal
    }

    private static func setImmutable(_ immutable: Bool, url: URL) throws {
        let flags = immutable ? UInt32(UF_IMMUTABLE) : UInt32(0)
        let result = url.path.withCString { chflags($0, flags) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
