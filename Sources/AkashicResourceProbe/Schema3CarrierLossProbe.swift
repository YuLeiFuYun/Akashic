import AkashicCore
import AkashicDisk
import Foundation

private enum Schema3CarrierLossProbeError: Error {
    case invalidArguments
    case invalidFixture
    case writerLeaseDidNotRelease
}

private struct Schema3CarrierLossReport: Codable {
    struct Case: Codable {
        let carrier: String
        let commitSucceeded: Bool
        let carrierRemovedExternally: Bool
        let payloadStillExists: Bool
        let reopenedState: String
    }

    let schemaVersion: Int
    let status: String
    let fastPayloadXattr: Case
    let explicitSidecar: Case
    let conclusion: String
    let claims: Claims

    struct Claims: Codable {
        let expectedFailureWitness: Bool
        let productionMutationPerformed: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
    }
}

enum Schema3CarrierLossProbe {
    static func run(arguments: [String]) async throws {
        guard arguments.isEmpty else { throw Schema3CarrierLossProbeError.invalidArguments }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "akashic-schema3-carrier-loss-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let xattrCase = try await runFastXattrCase(
            root: parent.appendingPathComponent("fast-xattr", isDirectory: true)
        )
        let sidecarCase = try await runSidecarCase(
            root: parent.appendingPathComponent("sidecar", isDirectory: true)
        )
        guard xattrCase.reopenedState == "miss",
            sidecarCase.reopenedState == "miss",
            xattrCase.payloadStillExists,
            sidecarCase.payloadStillExists
        else { throw Schema3CarrierLossProbeError.invalidFixture }

        let report = Schema3CarrierLossReport(
            schemaVersion: 1,
            status: "expected-failure-witnessed",
            fastPayloadXattr: xattrCase,
            explicitSidecar: sidecarCase,
            conclusion: "schema3 has no set-level commitment/watermark for current delta carriers; deleting the sole current carrier can silently lose a successfully committed logical entry even while its payload remains",
            claims: .init(
                expectedFailureWitness: true,
                productionMutationPerformed: false,
                physicalDevice: false,
                powerLoss: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func runFastXattrCase(root: URL) async throws -> Schema3CarrierLossReport.Case {
        let identity = try makeIdentity(label: "fast-xattr")
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        let publication = try await store!.commit(
            data: identity.data,
            digest: identity.digest,
            partition: identity.partition
        )
        let payload = blobURL(root: root, id: publication.physicalID)
        let attributes = try XattrShadowProbeIO.listAttributes(payload)
            .filter { $0.hasPrefix(ManifestXattrIdentity.prefix) }
        guard attributes.count == 1 else { throw Schema3CarrierLossProbeError.invalidFixture }
        try removeAttribute(attributes[0], from: payload)
        let payloadExists = FileManager.default.fileExists(atPath: payload.path)
        store = nil
        let reopened = try await reopenAfterLeaseRelease(root: root)
        let state = try await logicalState(
            store: reopened,
            digest: identity.digest,
            partition: identity.partition
        )
        return .init(
            carrier: "payload-xattr",
            commitSucceeded: true,
            carrierRemovedExternally: true,
            payloadStillExists: payloadExists,
            reopenedState: state
        )
    }

    private static func runSidecarCase(root: URL) async throws -> Schema3CarrierLossReport.Case {
        let identity = try makeIdentity(label: "sidecar")
        var store: FileBlobStore? = try await FileBlobStore.open(root: root)
        let stage = try await store!.stage(
            data: identity.data,
            digest: identity.digest,
            partition: identity.partition
        )
        let publication = try await store!.publish(stage)
        let payload = blobURL(root: root, id: publication.physicalID)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: blobs,
            includingPropertiesForKeys: nil,
            options: []
        ).filter {
            $0.lastPathComponent.hasPrefix(".manifest-entry-")
                && $0.lastPathComponent.hasSuffix(".json")
        }
        guard sidecars.count == 1 else { throw Schema3CarrierLossProbeError.invalidFixture }
        try FileManager.default.removeItem(at: sidecars[0])
        let payloadExists = FileManager.default.fileExists(atPath: payload.path)
        store = nil
        let reopened = try await reopenAfterLeaseRelease(root: root)
        let state = try await logicalState(
            store: reopened,
            digest: identity.digest,
            partition: identity.partition
        )
        return .init(
            carrier: "sidecar",
            commitSucceeded: true,
            carrierRemovedExternally: true,
            payloadStillExists: payloadExists,
            reopenedState: state
        )
    }

    private struct Identity {
        let data: Data
        let digest: BlobDigest
        let partition: CachePartitionID
    }

    private static func makeIdentity(label: String) throws -> Identity {
        let data = Data("schema3-carrier-loss-\(label)".utf8)
        return Identity(
            data: data,
            digest: BlobDigest.sha256(of: data),
            partition: try CachePartitionID.derive(
                domain: "akashic-schema3-carrier-loss-v1",
                material: Data(label.utf8)
            )
        )
    }

    private static func blobURL(root: URL, id: PhysicalBlobID) -> URL {
        root.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: false)
    }

    private static func logicalState(
        store: FileBlobStore,
        digest: BlobDigest,
        partition: CachePartitionID
    ) async throws -> String {
        do {
            _ = try await store.read(digest: digest, partition: partition)
            return "hit"
        } catch AkashicError.notFound {
            return "miss"
        }
    }

    private static func removeAttribute(_ name: String, from url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Schema3CarrierLossProbeError.invalidFixture }
        defer { _ = Darwin.close(descriptor) }
        let result = name.withCString { Darwin.fremovexattr(descriptor, $0, 0) }
        guard result == 0 else { throw Schema3CarrierLossProbeError.invalidFixture }
    }

    private static func reopenAfterLeaseRelease(root: URL) async throws -> FileBlobStore {
        for _ in 0..<250 {
            do {
                return try await FileBlobStore.open(root: root)
            } catch AkashicError.storageUnavailable {
                await Task.yield()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        throw Schema3CarrierLossProbeError.writerLeaseDidNotRelease
    }
}
