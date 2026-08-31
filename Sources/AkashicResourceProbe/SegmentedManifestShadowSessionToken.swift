import AkashicCore
import AkashicDisk
import CryptoKit
import Foundation

private struct SegmentedShadowVerifiedCandidateToken: Equatable {
    let writerSessionID: UUID
    let workspaceID: String
    let proof: SegmentedShadowSemanticProof
}

private struct SegmentedShadowVerifiedWorkspace {
    enum Phase {
        case building
        case verified
        case consumed
    }

    let writerSessionID: UUID
    let candidateURL: URL
    private(set) var phase: Phase = .building
    private var activeToken: SegmentedShadowVerifiedCandidateToken?

    mutating func verify(
        frozen: SegmentedShadowRoot,
        candidateBase: SegmentedShadowDescriptor,
        segmentDirectory: URL
    ) throws -> SegmentedShadowVerifiedCandidateToken {
        guard phase == .building,
            candidateURL.lastPathComponent == candidateBase.fileName
        else { throw SegmentedManifestShadowError.invalidFormat }
        let proof = try SegmentedManifestShadowProbe.makeSemanticProof(
            frozen: frozen,
            candidateBase: candidateBase,
            segmentDirectory: segmentDirectory
        )
        let token = SegmentedShadowVerifiedCandidateToken(
            writerSessionID: writerSessionID,
            workspaceID: SegmentedManifestShadowProbe.verifiedWorkspaceID(frozen),
            proof: proof
        )
        activeToken = token
        phase = .verified
        return token
    }

    mutating func replaceCandidateInternally(_ data: Data) throws {
        guard phase == .building else { throw SegmentedManifestShadowError.invalidFormat }
        try DurableFileWriter.writeReplacing(data, to: candidateURL)
    }

    mutating func publish(
        frozen: SegmentedShadowRoot,
        current: SegmentedShadowRoot,
        token: SegmentedShadowVerifiedCandidateToken
    ) throws -> SegmentedShadowRoot {
        guard phase == .verified,
            activeToken == token,
            token.writerSessionID == writerSessionID,
            token.workspaceID == SegmentedManifestShadowProbe.verifiedWorkspaceID(frozen)
        else { throw SegmentedManifestShadowError.invalidFormat }
        let root = try SegmentedManifestShadowProbe.boundedRebasedRoot(
            frozen: frozen,
            current: current,
            proof: token.proof,
            expectedCandidate: token.proof.candidateBase
        )
        activeToken = nil
        phase = .consumed
        return root
    }
}

struct SegmentedShadowSessionTokenReport: Codable {
    let schemaVersion: Int
    let sameSessionPublicationMatchesOracle: Bool
    let consumedTokenReuseRejected: Bool
    let internalMutationAfterVerificationRejected: Bool
    let internalMutationRejectionPreservesBytes: Bool
    let reopenedWorkspaceWithoutLiveTokenRejected: Bool
    let priorSessionTokenRejected: Bool
    let prefixDivergenceRejected: Bool
    let revalidationInNewSessionSucceeds: Bool
    let externallyMutatedCandidateAcceptedWithoutReread: Bool
    let externallyMutatedCandidateRejectedByRecovery: Bool
    let sessionTokenClosesInternalStaleProofGap: Bool
    let externalPostValidationMutationRemainsOutOfClaim: Bool
    let claims: Claims

    struct Claims: Codable {
        let productionFormat: Bool
        let publicationAlgorithmQualified: Bool
        let maliciousSameUserProtection: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

extension SegmentedManifestShadowProbe {
    static func sessionTokenShadow(arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)
        let segments = root.appendingPathComponent("segments", isDirectory: true)
        try StorageDirectorySecurity.prepareDirectory(segments)

        let baseEntries = try makeBaseEntries(count: 64)
        let baseState = Dictionary(uniqueKeysWithValues: baseEntries.map { ($0.key, $0) })
        let base = try sessionWriteBase(
            baseEntries,
            fileName: "base-session-origin.seg",
            directory: segments
        )
        let frozenMutations = try makeRunMutations(base: baseEntries, count: 16)
        let frozenRun = try sessionWriteRun(
            frozenMutations,
            fileName: "run-session-frozen.seg",
            directory: segments
        )
        let frozenState = try apply(frozenMutations, to: baseState)
        let frozen = try makeRoot(generation: 80, base: base, runs: [frozenRun])
        let candidateEntries = frozenState.values.sorted { $0.key < $1.key }
        let candidateData = try encodeBase(candidateEntries)
        let candidate = try sessionWriteBase(
            candidateEntries,
            fileName: "base-session-candidate.seg",
            directory: segments
        )
        let suffix = try sessionMixedSuffix(frozenState.values.sorted { $0.key < $1.key })
        let suffixRun = try sessionWriteRun(
            suffix,
            fileName: "run-session-suffix.seg",
            directory: segments
        )
        let current = try makeRoot(generation: 81, base: base, runs: [frozenRun, suffixRun])
        let expected = try apply(suffix, to: frozenState)
        let candidateURL = segments.appendingPathComponent(candidate.fileName)

        var workspaceA = SegmentedShadowVerifiedWorkspace(
            writerSessionID: UUID(),
            candidateURL: candidateURL
        )
        let tokenA = try workspaceA.verify(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segments
        )
        let beforeInternalMutation = try BoundedFileReader.read(
            from: candidateURL,
            maximumBytes: candidate.byteCount
        )
        var internalMutationAfterVerificationRejected = false
        do {
            try workspaceA.replaceCandidateInternally(Data("forbidden".utf8))
        } catch {
            internalMutationAfterVerificationRejected = true
        }
        let afterInternalMutation = try BoundedFileReader.read(
            from: candidateURL,
            maximumBytes: candidate.byteCount
        )
        let internalMutationRejectionPreservesBytes = beforeInternalMutation == afterInternalMutation
        guard internalMutationAfterVerificationRejected,
            internalMutationRejectionPreservesBytes
        else { throw SegmentedManifestShadowError.invariantViolation }

        let publishedA = try workspaceA.publish(
            frozen: frozen,
            current: current,
            token: tokenA
        )
        let sameSessionPublicationMatchesOracle = try sessionRecover(
            publishedA,
            directory: segments
        ) == expected
        guard sameSessionPublicationMatchesOracle else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        var consumedTokenReuseRejected = false
        do {
            _ = try workspaceA.publish(frozen: frozen, current: current, token: tokenA)
        } catch {
            consumedTokenReuseRejected = true
        }
        guard consumedTokenReuseRejected else { throw SegmentedManifestShadowError.invariantViolation }

        var workspaceB = SegmentedShadowVerifiedWorkspace(
            writerSessionID: UUID(),
            candidateURL: candidateURL
        )
        var reopenedWorkspaceWithoutLiveTokenRejected = false
        do {
            _ = try workspaceB.publish(frozen: frozen, current: current, token: tokenA)
        } catch {
            reopenedWorkspaceWithoutLiveTokenRejected = true
        }
        guard reopenedWorkspaceWithoutLiveTokenRejected else {
            throw SegmentedManifestShadowError.invariantViolation
        }
        let tokenB = try workspaceB.verify(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segments
        )
        var priorSessionTokenRejected = false
        do {
            _ = try workspaceB.publish(frozen: frozen, current: current, token: tokenA)
        } catch {
            priorSessionTokenRejected = true
        }
        guard priorSessionTokenRejected else { throw SegmentedManifestShadowError.invariantViolation }

        let divergent = try makeRoot(generation: 81, base: base, runs: [])
        var prefixDivergenceRejected = false
        do {
            _ = try workspaceB.publish(frozen: frozen, current: divergent, token: tokenB)
        } catch {
            prefixDivergenceRejected = true
        }
        guard prefixDivergenceRejected else { throw SegmentedManifestShadowError.invariantViolation }
        let publishedB = try workspaceB.publish(
            frozen: frozen,
            current: current,
            token: tokenB
        )
        let revalidationInNewSessionSucceeds = try sessionRecover(
            publishedB,
            directory: segments
        ) == expected
        guard revalidationInNewSessionSucceeds else {
            throw SegmentedManifestShadowError.invariantViolation
        }

        var workspaceC = SegmentedShadowVerifiedWorkspace(
            writerSessionID: UUID(),
            candidateURL: candidateURL
        )
        let tokenC = try workspaceC.verify(
            frozen: frozen,
            candidateBase: candidate,
            segmentDirectory: segments
        )
        var externallyMutated = candidateData
        externallyMutated[externallyMutated.index(externallyMutated.startIndex, offsetBy: headerBytes)] ^= 0x01
        try DurableFileWriter.writeReplacing(externallyMutated, to: candidateURL)
        let externallyMutatedRoot = try workspaceC.publish(
            frozen: frozen,
            current: current,
            token: tokenC
        )
        let externallyMutatedCandidateAcceptedWithoutReread = externallyMutatedRoot.base == candidate
        var externallyMutatedCandidateRejectedByRecovery = false
        do {
            _ = try sessionRecover(externallyMutatedRoot, directory: segments)
        } catch {
            externallyMutatedCandidateRejectedByRecovery = true
        }
        guard externallyMutatedCandidateAcceptedWithoutReread,
            externallyMutatedCandidateRejectedByRecovery
        else { throw SegmentedManifestShadowError.invariantViolation }
        try DurableFileWriter.writeReplacing(candidateData, to: candidateURL)

        let report = SegmentedShadowSessionTokenReport(
            schemaVersion: 1,
            sameSessionPublicationMatchesOracle: true,
            consumedTokenReuseRejected: true,
            internalMutationAfterVerificationRejected: true,
            internalMutationRejectionPreservesBytes: true,
            reopenedWorkspaceWithoutLiveTokenRejected: true,
            priorSessionTokenRejected: true,
            prefixDivergenceRejected: true,
            revalidationInNewSessionSucceeds: true,
            externallyMutatedCandidateAcceptedWithoutReread: true,
            externallyMutatedCandidateRejectedByRecovery: true,
            sessionTokenClosesInternalStaleProofGap: true,
            externalPostValidationMutationRemainsOutOfClaim: true,
            claims: .init(
                productionFormat: false,
                publicationAlgorithmQualified: false,
                maliciousSameUserProtection: false,
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

    fileprivate static func verifiedWorkspaceID(_ frozen: SegmentedShadowRoot) -> String {
        var data = Data("AKSEG-VERIFIED-WORK-V1\0".utf8)
        data.append(Data(frozen.seal.utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sessionMixedSuffix(
        _ entries: [SegmentedShadowEntry]
    ) throws -> [SegmentedShadowMutation] {
        guard entries.count >= 2 else { throw SegmentedManifestShadowError.invalidFormat }
        let source = entries[1]
        let repaired = SegmentedShadowEntry(
            key: source.key,
            physicalID: PhysicalBlobID(),
            partition: source.partition,
            digest: source.digest,
            byteCount: source.byteCount,
            lastAccess: source.lastAccess.addingTimeInterval(3)
        )
        let created = try sessionEntry(label: "created")
        return [
            .tombstone(key: entries[0].key),
            .upsert(repaired),
            .upsert(created),
        ].sorted { $0.key < $1.key }
    }

    private static func sessionEntry(label: String) throws -> SegmentedShadowEntry {
        let partition = try CachePartitionID.derive(
            domain: "resource-segment-session-token-v1",
            material: Data(label.utf8)
        )
        let payload = Data("session-token-\(label)".utf8)
        let digest = BlobDigest.sha256(of: payload)
        return SegmentedShadowEntry(
            key: FileBlobStore.resourceProbeManifestKey(digest: digest, partition: partition),
            physicalID: PhysicalBlobID(),
            partition: partition,
            digest: digest,
            byteCount: payload.count,
            lastAccess: Date(timeIntervalSinceReferenceDate: 990_000_000)
        )
    }

    private static func sessionWriteBase(
        _ entries: [SegmentedShadowEntry],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeBase(entries), to: url)
        return try descriptor(.base, url: url, expectedRecords: entries.count)
    }

    private static func sessionWriteRun(
        _ mutations: [SegmentedShadowMutation],
        fileName: String,
        directory: URL
    ) throws -> SegmentedShadowDescriptor {
        let url = directory.appendingPathComponent(fileName)
        try DurableFileWriter.writeReplacing(try encodeRun(mutations), to: url)
        return try descriptor(.run, url: url, expectedRecords: mutations.count)
    }

    private static func sessionRecover(
        _ root: SegmentedShadowRoot,
        directory: URL
    ) throws -> [String: SegmentedShadowEntry] {
        try validateRootStructure(root)
        guard try validateRootSeal(root) else { throw SegmentedManifestShadowError.invalidFormat }
        var state = Dictionary(uniqueKeysWithValues: try readBase(root.base, directory: directory).map { ($0.key, $0) })
        for run in root.runs {
            state = try apply(try readRun(run, directory: directory), to: state)
        }
        return state
    }
}
