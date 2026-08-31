import AkashicCore
import Foundation

extension FileBlobStoreReadIO {
    final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    struct Request: @unchecked Sendable {
        let url: URL
        let maximumBytes: Int
        let expectedBytes: Int
        let digest: BlobDigest
        let token: CancellationToken
        let continuation: CheckedContinuation<Result<BoundedFileReadResult, any Error>, Never>
    }
}
