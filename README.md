# Akashic

Akashic 是面向 Swift/Apple 平台的技术中立缓存与 durable blob store。它不解释图片、网络请求、HTTP、账户、授权或 UI；宿主负责把自己的业务身份和策略投影为 Akashic 的 typed contract。

## 产品

- `AkashicCore`：`BlobDigest`、`CachePartitionID`、`PhysicalBlobID`、`StoreGenerationID`、stage/publication、维护上限与通用协议；
- `AkashicMemory`：同步、线程安全、按成本设限的 SIEVE 内存缓存；
- `AkashicDisk`：partition 隔离、stage/publish/discard、单 writer、generation、损坏隔离、文件系统防御与有界恢复；
- `AkashicCrashProbe`：仅用于独立进程崩溃验证，不属于库 API；
- `AkashicResourceProbe`：仅用于本地资源包络采样，不属于库 API。

当前仓库是公开、可编译、可消费、可执行验证的 pre-1.0 垂直切片。核心 CI、不可变开发标签和精确提交集成已经建立；真机资源、物理断电与长期运行证据仍未完成，因此不构成稳定发布。

## 合同边界

```text
host semantic identity / authority / policy
                    |
                    | typed projection
                    v
BlobDigest + CachePartitionID
                    |
          +---------+---------+
          |                   |
  AkashicMemory          AkashicDisk
```

- `BlobDigest` 只绑定准确字节域的算法、摘要和 byte count；
- `CachePartitionID` 是宿主选择的不透明逻辑存储分区；
- `PhysicalBlobID` 只在一个 store generation 内定位物理 blob；
- `StoreGenerationID` 表示磁盘格式兼容代际；
- 上述值都不是授权凭证。

首版磁盘规则固定为：

- 物理去重只发生在同一个 partition 内；
- 每个 store root 只有一个活动 writer；
- 只承诺同一 store 实例内的并发 reader；
- future schema fail closed，不由旧实现改写；
- cache 可重建；当前磁盘格式与早期嵌入式实现不兼容，宿主必须使用新的 `StoreGeneration`。

## 使用

```swift
import AkashicCore
import AkashicDisk
import AkashicMemory
import Foundation

let payload = Data("payload".utf8)
let digest = BlobDigest.sha256(of: payload)
let partition = try CachePartitionID.derive(
    domain: "example-cache",
    material: Data([0x01])
)

let memory = MemoryCache<BlobDigest, Data>(costLimit: 1024)
memory.insert(payload, for: digest, cost: payload.count)

let generation = try await StoreGenerationDirectory.open(
    root: cacheRoot,
    compatibilityFingerprint: "example-v1"
)
let disk = try await FileBlobStore.open(
    root: generation.root.appendingPathComponent("blob-store", isDirectory: true)
)
_ = try await disk.commit(
    data: payload,
    digest: digest,
    partition: partition
)
let restored = try await disk.read(digest: digest, partition: partition)
```

## 本地证据

当前本地证据包括：

- 41 项 Swift Testing 测试：Core 12、Memory 7、Disk 22；
- 8 项 `write/fsync/close/rename` syscall 行为测试、1 项真实权限迁移、3 项真实挂载 APFS 满卷恢复和 3 项真实 APFS quota 恢复案例；
- 11 个精确子进程 crash switch points，以及 3 轮共 78 个固定种子的随机 `SIGKILL` 案例；
- 12 个并发进程竞争同一 store generation，必须收敛到唯一 generation ID；
- 6 个 Release 平台案例：Disk/Memory × macOS 12、iOS 15 Simulator、iOS 15 device；
- 3 个本地 macOS 资源 workload：峰值 RSS、采样 FD、逻辑读写、manifest 重写、footprint 与 reopen latency；
- 三产品外部 SwiftPM consumer；
- 128 个库公共符号 baseline、领域词汇门与 package-only crash hook 负向编译门；
- Privacy Manifest、源码结构、稳定 source identity 与无 Git/无构建缓存的 clean-copy 重放门。

故障报告明确写入 `powerLossClaim=false`。真实满卷门使用普通用户可挂载的 64 MiB APFS 稀疏磁盘映像，并确认底层替换、blob stage 与 manifest publication 均真实观察到内核 `ENOSPC`。独立 quota 门在 1 GiB APFS 容器中创建 64 MiB 配额卷，要求失败时容器仍保有远大于 payload 的自由空间；durable replacement 与 blob stage 返回内核 `ENOSPC`，manifest publication 在当前 Foundation 上先返回 `NSCocoaErrorDomain` 512，随后重开仍必须清除未发布状态。两类门都不是物理设备或断电资格。精确 `_exit` 与随机 `SIGKILL` 同样不能证明设备断电、文件系统控制器持久化或 APFS 在所有硬件上的 power-loss 行为。资源报告固定 `physicalIOBytes=false`、`physicalDevice=false` 和 `energy=false`；它测量的是当前 macOS 进程与应用层逻辑字节，不是物理 I/O 或真机资格。

## 验证

快速本地门：

```sh
scripts/verify.sh
```

更完整的本地发布机制门：

```sh
scripts/verify-release-readiness.sh
# 单独重放 syscall、权限迁移、真实 APFS 满卷、quota 和进程崩溃证据：
scripts/verify-fault-injection.sh
# 单独重放跨进程 generation 竞争：
scripts/verify-store-generation-contention.py
```

平台矩阵支持分片：

```sh
scripts/verify-platform-matrix.sh AkashicDisk ios-device
```

验证脚本显式选择完整 Xcode。仅使用 Command Line Tools 运行 Swift Testing 可能因 `Testing.framework` 运行时路径不完整而失败。

## 未完成

- 真实 `open`、ACL、owner 迁移，以及由真实文件系统触发的 `fsync`/rename/close 错误；
- 目标设备 RSS、FD、I/O bytes、metadata write amplification、reopen latency 和 energy；
- 真正的断电、`F_FULLFSYNC` 对照和数小时级高迭代 kill-at-random 实验；
- 多进程 reader snapshot/lease；
- 稳定版本、远端 clean-clone 完整复验与 current/previous 兼容矩阵；
- Fovea 差分 trace、W3/W8/W13 组合验证和 rollback。

详见 `ROADMAP.md`、`docs/ARCHITECTURE.md`、`docs/FAULT_INJECTION.md` 与 `docs/CONFORMANCE.md`。

## 许可

本项目采用 MIT License。详见 `LICENSE`。
