import AkashicCore
import AkashicDisk
import Foundation

/// 仅供本包故障脚本调用的真实满卷探针。
///
/// 挂载、填充和卸载卷由外部验证器负责；此处只执行与生产相同的
/// `DurableFileWriter` 和 `FileBlobStore` 路径，并输出机器可读结果。
enum FullVolumeProbe {
    private static let baselinePayload = Data("akashic-full-volume-baseline-v1".utf8)

    static func seed(root: URL) async {
        do {
            let store = try await FileBlobStore.open(root: root)
            let publication = try await store.commit(
                data: baselinePayload,
                digest: BlobDigest.sha256(of: baselinePayload),
                partition: partition()
            )
            emit([
                "status": "seeded",
                "byteCount": publication.byteCount,
                "disposition": publication.disposition.rawValue,
            ])
        } catch {
            emit(errorResult(error, operation: "seed"))
        }
    }

    static func commit(root: URL, payloadByteCount: Int) async {
        do {
            let payload = targetPayload(byteCount: payloadByteCount)
            let store = try await FileBlobStore.open(root: root)
            let publication = try await store.commit(
                data: payload,
                digest: BlobDigest.sha256(of: payload),
                partition: partition()
            )
            emit([
                "status": "published",
                "byteCount": publication.byteCount,
                "disposition": publication.disposition.rawValue,
            ])
        } catch {
            emit(errorResult(error, operation: "commit"))
        }
    }

    static func stageThenPublish(root: URL, payloadByteCount: Int) async throws {
        let payload = targetPayload(byteCount: payloadByteCount)
        let store = try await FileBlobStore.open(root: root)
        let stage = try await store.stage(
            data: payload,
            digest: BlobDigest.sha256(of: payload),
            partition: partition()
        )
        FileHandle.standardOutput.write(Data("staged\n".utf8))
        guard !FileHandle.standardInput.readData(ofLength: 1).isEmpty else {
            throw AkashicError.transactionConflict
        }
        do {
            let publication = try await store.publish(stage)
            emit([
                "status": "published",
                "byteCount": publication.byteCount,
                "disposition": publication.disposition.rawValue,
            ])
        } catch {
            emit(errorResult(error, operation: "publish"))
        }
    }

    static func inspect(root: URL, payloadByteCount: Int) async {
        do {
            let store = try await FileBlobStore.open(root: root)
            let baseline = await disposition(
                store: store,
                payload: baselinePayload
            )
            let target = await disposition(
                store: store,
                payload: targetPayload(byteCount: payloadByteCount)
            )
            let blobs = root.appendingPathComponent("blobs", isDirectory: true)
            let blobCount = ((try? FileManager.default.contentsOfDirectory(
                at: blobs,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )) ?? []).count
            let temporaryCount = recursiveChildren(root: root).filter {
                $0.lastPathComponent.hasPrefix(".durable-tmp-")
                    || $0.lastPathComponent.hasPrefix(".tmp-")
            }.count
            emit([
                "status": "inspected",
                "baselineDisposition": baseline,
                "targetDisposition": target,
                "blobCount": blobCount,
                "temporaryCount": temporaryCount,
                "manifestExists": FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("manifest.json").path
                ),
            ])
        } catch {
            emit(errorResult(error, operation: "inspect"))
        }
    }

    static func durableReplace(root: URL, payloadByteCount: Int) {
        let destination = root.appendingPathComponent("state.bin", isDirectory: false)
        do {
            try DurableFileWriter.writeReplacing(
                targetPayload(byteCount: payloadByteCount),
                to: destination
            )
            emit([
                "status": "replaced",
                "byteCount": payloadByteCount,
            ])
        } catch {
            emit(errorResult(error, operation: "durable-replace"))
        }
    }

    private static func disposition(
        store: FileBlobStore,
        payload: Data
    ) async -> String {
        do {
            let restored = try await store.read(
                digest: BlobDigest.sha256(of: payload),
                partition: partition()
            )
            return restored == payload ? "hit" : "corrupt"
        } catch AkashicError.notFound {
            return "miss"
        } catch {
            return "error:\(String(describing: error))"
        }
    }

    private static func targetPayload(byteCount: Int) -> Data {
        Data(repeating: 0x5A, count: byteCount)
    }

    private static func partition() -> CachePartitionID {
        try! CachePartitionID.derive(
            domain: "akashic-real-full-volume-v1",
            material: Data([0x01])
        )
    }

    private static func errorResult(
        _ error: any Error,
        operation: String
    ) -> [String: Any] {
        if let posix = error as? POSIXError {
            return [
                "status": "failed",
                "operation": operation,
                "errorType": "POSIXError",
                "errno": posix.code.rawValue,
                "errorCode": String(describing: posix.code),
            ]
        }
        if let akashic = error as? AkashicError {
            return [
                "status": "failed",
                "operation": operation,
                "errorType": "AkashicError",
                "errorCode": String(describing: akashic),
            ]
        }
        let cocoa = error as NSError
        var result: [String: Any] = [
            "status": "failed",
            "operation": operation,
            "errorType": String(describing: type(of: error)),
            "errorDomain": cocoa.domain,
            "errorCode": cocoa.code,
        ]
        if let posixCode = underlyingPOSIXCode(cocoa) {
            result["errno"] = posixCode
            result["underlyingPOSIXError"] = true
        }
        return result
    }

    private static func underlyingPOSIXCode(_ error: NSError) -> Int? {
        if error.domain == NSPOSIXErrorDomain { return error.code }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return nil
        }
        return underlyingPOSIXCode(underlying)
    }

    private static func emit(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            fputs("unable to encode full-volume result\n", stderr)
        }
    }

    private static func recursiveChildren(root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }
}
