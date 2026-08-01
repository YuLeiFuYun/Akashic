/// `FileBlobStore` 的包内故障注入点。
///
/// 子进程在这些点直接退出，父进程随后重开 store，以区分进程崩溃后的完整旧状态、
/// 完整新状态、孤儿和临时文件。断电与硬件持久化语义仍需目标环境证据。
package enum FileBlobStoreSwitchPoint: String, CaseIterable, Sendable {
    case afterBlobDataWritten
    case afterBlobFileSynced
    case afterBlobRenamed
    case afterBlobDirectorySynced
    case afterBlobFilePublished
    case beforeManifestPublished
    case afterManifestDataWritten
    case afterManifestFileSynced
    case afterManifestRenamed
    case afterManifestDirectorySynced
    case afterManifestPublished
}

package typealias FileBlobStoreFaultInjector =
    @Sendable (FileBlobStoreSwitchPoint) throws -> Void
