import AkashicCore
import AkashicDisk
import Darwin
import Foundation

private struct Schema5ReferencedPhysicalOwnershipCase: Codable {
    let name: String
    let rejected: Bool
    let rejectionClass: String
    let logicalRootUnchanged: Bool
    let referencedPathPreserved: Bool
    let foreignTargetPreserved: Bool?
}

private struct Schema5ReferencedPhysicalOwnershipReport: Codable {
    struct Claims: Codable {
        let sameUserRaceProtection: Bool
        let foreignUIDCovered: Bool
        let formalPerformance: Bool
        let physicalDevice: Bool
        let powerLoss: Bool
        let foveaAuthoritySemantics: Bool
    }

    let schemaVersion: Int
    let controlOpenedExact: Bool
    let cases: [Schema5ReferencedPhysicalOwnershipCase]
    let allHostileCasesRejected: Bool
    let allLogicalRootsUnchanged: Bool
    let allHostileObjectsPreserved: Bool
    let claims: Claims
}

private struct Schema5ReferencedPhysicalOwnershipFixture {
    let root: URL
    let segments: URL
    let manifest: URL
    let base: URL
    let rootBytes: Data
}

extension SegmentedManifestShadowProbe {
    static func schema5ReferencedPhysicalOwnership(arguments: [String]) async throws {
        guard arguments.count == 2, arguments[0] == "--root" else {
            throw SegmentedManifestShadowError.invalidArguments
        }
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try StorageDirectorySecurity.prepareDirectory(root)

        let control = try await schema5ReferencedOwnershipControl(
            root: root.appendingPathComponent("control", isDirectory: true)
        )
        let symlink = try await schema5ReferencedOwnershipSymlink(
            root: root.appendingPathComponent("symlink", isDirectory: true)
        )
        let hardlink = try await schema5ReferencedOwnershipHardlink(
            root: root.appendingPathComponent("hardlink", isDirectory: true)
        )
        let unsafeMode = try await schema5ReferencedOwnershipUnsafeMode(
            root: root.appendingPathComponent("unsafe-mode", isDirectory: true)
        )
        let wrongHash = try await schema5ReferencedOwnershipWrongHash(
            root: root.appendingPathComponent("wrong-hash", isDirectory: true)
        )
        let nonregular = try await schema5ReferencedOwnershipNonregular(
            root: root.appendingPathComponent("nonregular", isDirectory: true)
        )
        let cases = [symlink, hardlink, unsafeMode, wrongHash, nonregular]
        let report = Schema5ReferencedPhysicalOwnershipReport(
            schemaVersion: 1,
            controlOpenedExact: control,
            cases: cases,
            allHostileCasesRejected: cases.allSatisfy(\.rejected),
            allLogicalRootsUnchanged: cases.allSatisfy(\.logicalRootUnchanged),
            allHostileObjectsPreserved: cases.allSatisfy {
                $0.referencedPathPreserved && ($0.foreignTargetPreserved ?? true)
            },
            claims: .init(
                sameUserRaceProtection: false,
                foreignUIDCovered: false,
                formalPerformance: false,
                physicalDevice: false,
                powerLoss: false,
                foveaAuthoritySemantics: false
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data([0x0A]))
        guard report.controlOpenedExact,
            report.allHostileCasesRejected,
            report.allLogicalRootsUnchanged,
            report.allHostileObjectsPreserved
        else { throw SegmentedManifestShadowError.invariantViolation }
    }

    private static func schema5ReferencedOwnershipControl(root: URL) async throws -> Bool {
        let fixture = try schema5ReferencedOwnershipFixture(root: root)
        var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
        let snapshot = await store!.resourceProbeManifestShadowSnapshot()
        store = nil
        let logicalRootUnchanged =
            try Data(contentsOf: fixture.manifest, options: [.mappedIfSafe]) == fixture.rootBytes
        return snapshot.entries.isEmpty && logicalRootUnchanged
    }

    private static func schema5ReferencedOwnershipSymlink(
        root: URL
    ) async throws -> Schema5ReferencedPhysicalOwnershipCase {
        let fixture = try schema5ReferencedOwnershipFixture(root: root)
        let target = fixture.segments.appendingPathComponent("foreign-symlink-target.akb2")
        guard fixture.base.path.withCString({ source in
            target.path.withCString { destination in Darwin.rename(source, destination) }
        }) == 0 else { throw POSIXError(.EIO) }
        guard target.path.withCString({ targetPointer in
            fixture.base.path.withCString { linkPointer in Darwin.symlink(targetPointer, linkPointer) }
        }) == 0 else { throw POSIXError(.EIO) }
        let rejection = await schema5ReferencedOwnershipOpenRejection(root: root)
        return try schema5ReferencedOwnershipResult(
            name: "symlink",
            rejection: rejection,
            fixture: fixture,
            foreignTarget: target
        )
    }

    private static func schema5ReferencedOwnershipHardlink(
        root: URL
    ) async throws -> Schema5ReferencedPhysicalOwnershipCase {
        let fixture = try schema5ReferencedOwnershipFixture(root: root)
        let target = fixture.segments.appendingPathComponent("foreign-hardlink-target.akb2")
        guard fixture.base.path.withCString({ source in
            target.path.withCString { destination in Darwin.rename(source, destination) }
        }) == 0 else { throw POSIXError(.EIO) }
        guard target.path.withCString({ targetPointer in
            fixture.base.path.withCString { linkPointer in Darwin.link(targetPointer, linkPointer) }
        }) == 0 else { throw POSIXError(.EIO) }
        let rejection = await schema5ReferencedOwnershipOpenRejection(root: root)
        return try schema5ReferencedOwnershipResult(
            name: "hardlink",
            rejection: rejection,
            fixture: fixture,
            foreignTarget: target
        )
    }

    private static func schema5ReferencedOwnershipUnsafeMode(
        root: URL
    ) async throws -> Schema5ReferencedPhysicalOwnershipCase {
        let fixture = try schema5ReferencedOwnershipFixture(root: root)
        guard fixture.base.path.withCString({ Darwin.chmod($0, 0o644) }) == 0 else {
            throw POSIXError(.EIO)
        }
        let rejection = await schema5ReferencedOwnershipOpenRejection(root: root)
        return try schema5ReferencedOwnershipResult(
            name: "unsafe-mode",
            rejection: rejection,
            fixture: fixture,
            foreignTarget: nil
        )
    }

    private static func schema5ReferencedOwnershipWrongHash(
        root: URL
    ) async throws -> Schema5ReferencedPhysicalOwnershipCase {
        let fixture = try schema5ReferencedOwnershipFixture(root: root)
        let descriptor = Darwin.open(
            fixture.base.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0, status.st_size > 0 else {
            throw POSIXError(.EIO)
        }
        let offset = status.st_size - 1
        var byte: UInt8 = 0
        guard Darwin.pread(descriptor, &byte, 1, offset) == 1 else {
            throw POSIXError(.EIO)
        }
        byte ^= 0x01
        guard Darwin.pwrite(descriptor, &byte, 1, offset) == 1 else {
            throw POSIXError(.EIO)
        }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        let rejection = await schema5ReferencedOwnershipOpenRejection(root: root)
        return try schema5ReferencedOwnershipResult(
            name: "wrong-hash",
            rejection: rejection,
            fixture: fixture,
            foreignTarget: nil
        )
    }

    private static func schema5ReferencedOwnershipNonregular(
        root: URL
    ) async throws -> Schema5ReferencedPhysicalOwnershipCase {
        let fixture = try schema5ReferencedOwnershipFixture(root: root)
        try FileManager.default.removeItem(at: fixture.base)
        try StorageDirectorySecurity.prepareDirectory(fixture.base)
        let rejection = await schema5ReferencedOwnershipOpenRejection(root: root)
        return try schema5ReferencedOwnershipResult(
            name: "nonregular",
            rejection: rejection,
            fixture: fixture,
            foreignTarget: nil
        )
    }

    private static func schema5ReferencedOwnershipFixture(
        root: URL
    ) throws -> Schema5ReferencedPhysicalOwnershipFixture {
        try StorageDirectorySecurity.prepareDirectory(root)
        try StorageDirectorySecurity.prepareDirectory(
            root.appendingPathComponent("blobs", isDirectory: true)
        )
        let segments = root.appendingPathComponent(
            FileBlobStore.segmentedManifestPrototypeDirectoryName,
            isDirectory: true
        )
        try StorageDirectorySecurity.prepareDirectory(segments)
        let name = "base-binary-v2-\(UUID().uuidString.lowercased()).akb2"
        let baseDescriptor = try SegmentedManifestPrototypeV1.writeBaseBinaryV2(
            [:],
            fileName: name,
            directory: segments
        )
        let manifestRoot = try SegmentedManifestPrototypeV1.makeRootV3(
            generation: 1,
            base: baseDescriptor,
            runs: []
        )
        let manifest = root.appendingPathComponent("manifest.json", isDirectory: false)
        try SegmentedManifestPrototypeV1.writeRoot(manifestRoot, to: manifest)
        return Schema5ReferencedPhysicalOwnershipFixture(
            root: root,
            segments: segments,
            manifest: manifest,
            base: segments.appendingPathComponent(name, isDirectory: false),
            rootBytes: try Data(contentsOf: manifest, options: [.mappedIfSafe])
        )
    }

    private static func schema5ReferencedOwnershipOpenRejection(
        root: URL
    ) async -> (rejected: Bool, rejectionClass: String) {
        do {
            var store: FileBlobStore? = try await FileBlobStore.openSegmentedV3Candidate(root: root)
            _ = await store!.resourceProbeManifestShadowSnapshot()
            store = nil
            return (false, "accepted")
        } catch AkashicError.storageUnavailable {
            return (true, "storageUnavailable")
        } catch AkashicError.invalidManifest {
            return (true, "invalidManifest")
        } catch AkashicError.limitExceeded {
            return (true, "limitExceeded")
        } catch {
            return (true, String(reflecting: type(of: error)))
        }
    }

    private static func schema5ReferencedOwnershipResult(
        name: String,
        rejection: (rejected: Bool, rejectionClass: String),
        fixture: Schema5ReferencedPhysicalOwnershipFixture,
        foreignTarget: URL?
    ) throws -> Schema5ReferencedPhysicalOwnershipCase {
        let logicalRootUnchanged =
            try Data(contentsOf: fixture.manifest, options: [.mappedIfSafe]) == fixture.rootBytes
        var isDirectory: ObjCBool = false
        let referencedPathPreserved = FileManager.default.fileExists(
            atPath: fixture.base.path,
            isDirectory: &isDirectory
        ) || fixture.base.path.withCString({
            var status = stat()
            return Darwin.lstat($0, &status) == 0
        })
        let targetPreserved = foreignTarget.map {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return Schema5ReferencedPhysicalOwnershipCase(
            name: name,
            rejected: rejection.rejected,
            rejectionClass: rejection.rejectionClass,
            logicalRootUnchanged: logicalRootUnchanged,
            referencedPathPreserved: referencedPathPreserved,
            foreignTargetPreserved: targetPreserved
        )
    }
}
