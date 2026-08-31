import AkashicCore
import CryptoKit
import Foundation

extension FileBlobStore.Manifest {
    static func directoryHeadSnapshotSeal(
        generation: UInt64,
        profile: FileBlobStore.DeltaCarrierProfile,
        compact: [CompactEntry]
    ) throws -> Data {
        guard profile == .directoryHeadV2,
            let entryCount = UInt32(exactly: compact.count)
        else { throw AkashicError.invalidManifest }
        var transcript = Data("akashic-directory-head-snapshot-v2\u{0}".utf8)
        appendSnapshotBigEndian(FileBlobStore.directoryHeadManifestSchemaVersion, to: &transcript)
        appendSnapshotBigEndian(generation, to: &transcript)
        appendSnapshotBytes(Data(profile.rawValue.utf8), to: &transcript)
        appendSnapshotBigEndian(entryCount, to: &transcript)
        for item in compact {
            appendSnapshotBytes(
                Data(item.physicalID.uuidString.lowercased().utf8),
                to: &transcript
            )
            appendSnapshotBytes(item.partition, to: &transcript)
            appendSnapshotBytes(item.digest, to: &transcript)
            appendSnapshotBigEndian(item.byteCount, to: &transcript)
            appendSnapshotBigEndian(item.lastAccess.bitPattern, to: &transcript)
        }
        return Data(SHA256.hash(data: transcript))
    }

    private static func appendSnapshotBytes(_ bytes: Data, to transcript: inout Data) {
        precondition(bytes.count <= Int(UInt32.max))
        appendSnapshotBigEndian(UInt32(bytes.count), to: &transcript)
        transcript.append(bytes)
    }

    private static func appendSnapshotBigEndian<T: FixedWidthInteger>(
        _ value: T,
        to transcript: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { transcript.append(contentsOf: $0) }
    }
}
