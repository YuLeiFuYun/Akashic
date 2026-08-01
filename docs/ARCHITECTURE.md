# Architecture

## 边界

Akashic 拥有缓存与 blob 存储机制，不拥有应用授权、网络缓存语义或媒体解释。

```text
Host policy and semantic identity
        |
        | typed projection
        v
AkashicCore
  BlobDigest
  CachePartitionID
  PhysicalBlobID
  StoreGenerationID
  transaction and maintenance protocols
        |
        +----------> AkashicMemory
        |
        +----------> AkashicDisk
```

## 身份分离

- `BlobDigest`：准确字节及长度的完整性身份；
- `CachePartitionID`：宿主选择的不透明逻辑隔离域；
- `PhysicalBlobID`：store-local 物理定位符；
- `StoreGenerationID`：磁盘格式兼容代际；
- `BlobStage`：尚未进入逻辑索引的事务令牌。

任何一项都不授予授权或持久化资格。

## AkashicCore

Core 提供有限、typed、`Sendable` 的身份与协议。首版只接受 SHA-256 `BlobDigest`，并绑定精确 byte count。维护 API 同时限制 reference count 与累计 bytes。目录恢复通过 POSIX 目录流在追加名称前执行硬数量上限，且包含隐藏临时文件。

Core 不公开从账户、URL 或业务 namespace 字符串直接创建 partition 的接口。宿主可以用中立 domain 与 opaque material 派生 `CachePartitionID`。

## AkashicMemory

`MemoryCache` 是同步、锁线性化的 SIEVE cache：

- hit 只设置 epoch bit，不移动链表节点；
- 插入和淘汰在一个短临界区内完成；
- cost 超限值直接拒绝；
- purge 返回准确 item/cost summary。

当前证据包含 32 个种子 × 800 步的独立 SIEVE reference-model differential、动态 limit change，以及 16-worker 可交换并发历史。非可交换共享键的完整线性化分析仍未完成。

## AkashicDisk

### 逻辑与物理模型

`FileBlobStore` 的逻辑 key 是：

```text
CachePartitionID + BlobDigest
```

物理文件名只来自随机 `PhysicalBlobID`。同 partition、同 digest 可以复用同一个物理 blob；不同 partition 即使 digest 相同也创建不同物理 blob。

### 发布事务

```text
stage bytes
  -> durable temporary file
  -> rename + directory fsync
  -> unpublished BlobStage
  -> manifest durable replace
  -> logical visibility
```

stage 在 publish 前不能通过 read 或 physicalID 观察。publish/discard 都是终态。调用方提供的 digest 会由 store 重算。

### Writer 与 reader

- 每个 store root 只有一个活动 writer；
- 同进程 registry 防止 POSIX record-lock 的同进程多描述符缺口；
- `lockf` 提供跨进程 writer exclusion；
- writer 退出后内核释放锁，后续进程可重开；
- 首版只声明同一 actor/store instance 内的并发 reader，不声明多进程 reader snapshot。

### StoreGeneration

`StoreGenerationDirectory` 将兼容 fingerprint 绑定到 typed `StoreGenerationID`，通过 descriptor 与 CURRENT pointer 原子切换。未知 schema fail closed 并保留原文件。首次从 Fovea 提取使用新 generation，不复用旧嵌入格式。

### 恢复与安全

启动恢复会：

- 清理根目录和 blob 目录的耐久写入临时文件；
- 删除 manifest 未引用的孤儿 blob；
- 移除缺失或超限逻辑条目；
- 验证 regular-file、单 hardlink、owner、权限和 O_NOFOLLOW；
- 对读取时的删除、截断或 digest mismatch 做 quarantine。

恢复枚举有硬目录项上限。当前实现不把 process-crash 结果描述为 power-loss 证明。

### 故障注入与进程恢复

`DurableFileWriter` 的 package-only syscall table 可替换同步 `write(2)`、`fsync(2)`、`close(2)` 和同目录 `rename(2)`；生产入口始终绑定真实 Darwin 调用，外部消费者不可访问。8 项测试覆盖部分写入、write/fsync `EINTR`、前缀写入后的 `ENOSPC`、file-fsync 失败、close 失败、rename `ENOSPC` 和 directory-fsync 失败。rename 前的失败必须保留旧 destination 并清除临时文件；directory-fsync 失败发生在 rename 后，因此新 destination 可能已经可见，但其目录项耐久性未被证明，调用仍返回错误。

权限迁移测试在 manifest 临时文件完成 file `fsync` 后真实执行 `chmod(0500)`，使父目录 rename 因 `EACCES`/`EPERM` 失败。恢复 0700、释放 writer 并重开后，逻辑状态必须为 miss，未发布 blob 与临时 manifest 必须被 bootstrap 清理。

真实满卷矩阵创建并挂载三个独立的 64 MiB APFS 稀疏磁盘映像。验证器先把卷写到内核返回 `ENOSPC`，再分别验证：底层 durable replacement 保留旧 destination；blob stage 失败不破坏既有 entry；blob 已 stage 后在 manifest publication 期间耗尽空间，退出并释放 writer 后重开会删除 orphan 与临时文件。三个案例均要求底层 `errno=28`、既有 baseline hit、目标 miss 和精确物理 blob 数量。该证据只覆盖真实挂载 APFS 的容量耗尽，不覆盖 quota、物理设备或断电。

真实 quota 矩阵在三个独立的 1 GiB APFS 稀疏容器中创建 64 MiB 配额卷。每个失败点都要求容器本身仍有至少 payload 八倍的自由空间，从而排除整卷容量耗尽。durable replacement 与 blob stage 直接返回内核 `ENOSPC`；manifest publication 在当前 Foundation 上于临时文件元数据预写阶段返回 `NSCocoaErrorDomain` 512，未暴露底层 POSIX 链。释放外部 filler 并重开后，三项均要求 baseline hit、target miss、精确 blob 数量和零临时文件。该证据不等于物理设备或断电资格。

进程级证据包含 11 个精确 `_exit` switch points，以及 3 轮固定种子的随机 `SIGKILL` campaign。每轮在 child 完成 store open 后同步启动 8 MiB stage/publish，保留一个严格 miss 锚点、一个严格 hit 锚点和 24 个 0–10 ms 随机延迟；总计 78 个终止案例，其中 72 个是真正的随机时序样本。重开只接受完整 hit 或完整 miss，并要求随机样本本身同时覆盖两种状态。详见 `docs/FAULT_INJECTION.md`。

### 本地资源包络

`AkashicResourceProbe` 在独立进程中执行三个保留 workload。它将 payload bytes、read bytes 和每次 manifest 全量替换大小作为应用层逻辑计量，并采集 Darwin `ru_maxrss`、`/dev/fd` 快照、最终文件 footprint 与 reopen latency。验证器施加宽松的本地 fail-closed 上限，用于发现无界增长和数量级退化。

该证据不等于物理磁盘 I/O：page cache、APFS copy-on-write、控制器写放大和 fsync 的硬件持久化均不在逻辑字节计数中。报告因此固定 `physicalIOBytes=false`、`physicalDevice=false`、`energy=false` 和 `powerLoss=false`。

## 证据边界

当前已验证：

- 41 项单元/并发/故障测试；
- 8 项 syscall 故障、1 项真实权限迁移、3 项真实 APFS 满卷恢复、3 项真实 APFS quota 恢复、11 个精确 `_exit` switch points 和 3 轮 78 个随机 `SIGKILL` 案例；
- 6 个 Apple Release 编译案例；
- 正向/负向外部 consumer、API、privacy、structure、source identity 和 clean-copy replay；
- 3 个本地 macOS 资源 workload，记录峰值 RSS、采样 FD、逻辑 I/O、manifest 重写、最终 footprint 与 reopen latency。

尚未验证：

- 真正设备断电；
- 真实 `open`、ACL、owner 迁移，以及由真实文件系统触发的 `fsync`、directory `fsync`、rename 和 close 错误；
- 多进程 reader；
- 稳定真机的物理 I/O、RSS/FD 复核、能耗和长期资源包络；
- Fovea host transaction、revoke 与 HTTP 组合性质。
