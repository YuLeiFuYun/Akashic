import Dispatch

/// 将阻塞文件系统操作隔离到专用串行队列，避免占用 Swift 协作式执行器。
package final class BlockingIOExecutor: SerialExecutor {
    private let queue: DispatchQueue

    package init(label: String) {
        self.queue = DispatchQueue(label: label, qos: .utility, autoreleaseFrequency: .workItem)
    }

    // 当前最低系统为 iOS 15 / macOS 12，因此仍使用可回部署的 UnownedJob 协议入口。
    // 最低系统提升到 iOS 17 / macOS 14 后，再迁移到 consuming ExecutorJob。
    // 无论使用哪种入口，每个接收的 job 都必须且只能执行一次。
    package func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    /// 在同一条阻塞 I/O 串行通道上执行一次同步操作。
    ///
    /// 取消无法中断已经开始的 POSIX 或 Foundation 调用，因此入队前和完成后都检查取消；
    /// 文件系统操作仍会完整收敛，但已经取消的调用者不会拿到可继续发布的成功结果。
    package func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
        try Task.checkCancellation()
        return value
    }

    package func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    package func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
