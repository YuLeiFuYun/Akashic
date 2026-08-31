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

`MemoryCache` 是同步、单锁线性化的经典 SIEVE 参考实现：

- hit 只设置访问状态，不移动 FIFO 链表节点；
- 插入和淘汰在一个短临界区内完成；
- 超过全局 cost limit 的值直接拒绝；
- purge 返回准确 item/cost summary。

`ShardedMemoryCache` 是可选的并发候选。Fovea 曾在可逆本地 edit 中将其用于渲染
缓存与 alias 缓存，并与磁盘 v2 一起通过 478/478 回归；该源码切换随后撤回，使主包
继续对公开 Akashic 精确 revision 可独立构建。最终 V2 tree-bound campaign 在 13 个适用比较中通过 12 个，随后发现计时边界不一致。Cache Lab V3 预生成 corpus，但声明 20 rounds、实际执行 1 round，最终仍有三个支配失败。V4 真正执行 20 个 fresh-cache rounds，并把磁盘 p99 扩展为 8 轮采样。16 分片在该 workload 中只保留 619/640 热探测，32 分片此前每轮只保留 21/32；两者均拒绝。Fovea V4 固定 8 分片，并在 20 个独立 clean process block 的 scope-all 正式 campaign 中通过全部 13 个适用支配比较。公开 revision、Fovea 精确 pin 与 clean trusted CI 仍未完成，因此不得把本地接入描述为已发布默认。当前工作树不再把 global cost limit 静态切给 shard。每个 shard 在公开操作边界的 assigned limit 等于真实 resident cost，未分配成本保存在内部 `CAkashicAtomics` 64-bit 原子池；普通 lookup、insert、remove 与稳态 SIEVE eviction 仍只锁目标 shard。insert 在 shard lock 内从全局池领取至多 incoming cost，完成替换/淘汰后把未使用预算在解锁前归还，因此 hash routing 不再决定有效容量。只有当单个对象无法由目标 shard 当前 resident assignment 加全部 unassigned cost 容纳时，才按固定锁序进入 all-shard slow path；该路径只释放真实 cross-shard deficit，不再把剩余容量均分给非目标 shard。不同 immediate victim cost 仍用 greedy best-fit；只有 equal-cost tie 中某 shard 的合法 successor 恰好等于第一步后的剩余 deficit 时，才允许偏离原 ring tie。该规则不是一般 look-ahead：4194304 个有界研究状态中，一般 two-step 与 unrestricted tie-lookahead 都出现新回归，而 exact-successor 规则相对 immediate greedy 为 0 regression / 46153 improvement。`AKASHIC-CT-068` 再用真实 Swift shard 状态机验证 two-victim forecast，`CT-069/070` 分别固定 resize 与 cross-shard insert 的 `[1,6]` / `[1,8]`, deficit=9 反例。全局 limit change、filtered purge、clear 与 aggregate snapshot 继续使用 configuration lock → ascending shard locks 的唯一锁序。历史 V4 正式 campaign 仍绑定公开 revision 的旧实现，当前 unpublished working tree 的 CacheLab 只属于方向性机制证据；公开 revision、Fovea 精确 pin 与 clean trusted CI 未完成前，不得把当前候选描述为发布级默认或正式排名结论。

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
  -> durable blob publication
  -> unpublished BlobStage
  -> durable sidecar manifest record or full checkpoint
  -> logical visibility
```

stage 在 publish 前不能通过 read 或 physicalID 观察。publish/discard 都是终态。调用方提供的 digest 会由 store 重算。显式 `stage` / `publish` 继续使用独立 sidecar record，因此原有两阶段事务和 crash fault surface 不被 fast-path 优化偷换。

常见 `commit` 的 create/replacement fast path 则把紧凑 create record 放进临时 blob inode 的 manifest xattr：raw blob bytes 与 authority xattr 在同一 descriptor 上完成一次 file `fsync`，随后 UUID rename 同时发布物理 blob 与 logical create authority，最后一次 blob-directory `fsync` 固化 rename。xattr 名称独立携带 format version、generation 与 256-bit manifest key；value 继续使用紧凑 `ManifestRecord` create payload，并在 recovery 时反算 partition + digest、核对 carrier `PhysicalBlobID` 与 sequence。只有文件系统明确返回 `ENOTSUP` / `E2BIG` 且尚未发布 authority 时，fast path 才安全回退到旧 sidecar transaction；空间、I/O、fsync 等失败不被 fallback 掩盖。

remove/tombstone 刻意仍使用小 sidecar，再删除 payload；不把已删除的大 blob 留作 tombstone carrier，因此 checkpoint 前最多 511 个 delta key 的上界不会放大成大 payload physical debt。checkpoint cardinality 现在由当前 generation 的 distinct logical delta keys 计数，不再依赖具体 carrier 是 sidecar 还是 xattr。多-key maintenance、distinct delta key 达到 checkpoint 上限或序列溢出时原子替换完整 snapshot。

逻辑删除/revoke 的成功边界是 tombstone 或 checkpoint authority 已持久化，不再由随后 payload unlink 的成败倒推逻辑事务。真实 macOS `UF_IMMUTABLE`/`EPERM` witness 证明物理删除可以在逻辑 authority 已完成后独立失败：`remove` / `removeAll` 此时保持 miss，replacement 保持新的 `PhysicalBlobID`。bootstrap 只允许**已经重新验证为 Akashic 私有 payload identity** 的无引用文件作为 physical cleanup debt：文件名必须是 canonical lowercase UUID，inode 必须仍是当前用户拥有、single-link、private regular file；foreign / `.tmp-*` / symlink / hardlink / unsafe-mode identity 的删除失败继续 fail closed 为 `storageUnavailable`，删除失败后验证时若已并发消失（`ENOENT`）则视为 debt 已偿还。显式 `garbageCollect` 仍严格报告合法 payload 的 cleanup failure，外部条件修复后可偿还 exact orphan file/bytes。

schema 3 的增量 carrier 没有独立 commit-head / set commitment，因此物理 cleanup debt 还有一个额外 rollback 风险：高 sequence tombstone/replacement carrier 若后来丢失，而低 sequence payload xattr 因 cleanup debt 仍存在，单靠“最高现存 sequence”会把 logical authority 回滚。当前 schema 3 的安全补丁是 **debt-triggered generation seal**：remove/removeAll/GC/quarantine/trim/replacement 等 logical mutation 已提交后，只要旧 payload carrier 无法物理删除，就在 API 成功返回前把最终 logical manifest 原子 checkpoint 到下一 generation，令旧 generation 的所有 delta carriers 同时失去 authority；seal 自身若失败，writer 立即进入 reopen-required 并返回 `storageUnavailable`。正常 cleanup 成功时不额外 checkpoint。CT-082–087 覆盖 tombstone 丢失、replacement rollback、single-key removeAll、single-victim GC、quarantine 以及 protective seal 的 pre/post-rename failure。这个补丁只封闭“已知 physical debt 形成时的 rollback”；普通 current-generation carrier 被外部删除仍缺少通用 set-level deletion detector，属于下一代 manifest carrier 协议的 correctness frontier。

当前 limits 尚未定义独立 debt byte/count budget，因此现状只闭合“小规模 debt 不回滚 authority + debt 不弱化 filesystem identity defense”的 correctness，不宣称 unbounded debt 已有完整资源策略。

任何 logical-authority carrier 一旦跨过自己的 rename 可见性点、但调用在 actor 采用对应 manifest/generation/sequence 前返回错误，该 `FileBlobStore` instance 就进入 reopen-required 状态。此后 read/commit/stage/publish/remove/removeAll/garbageCollect fail closed 为 `storageUnavailable`，非 throwing `physicalID` 返回 nil；`discard` 也不得 unlink 可能已经被 process-visible sidecar 引用的 stage blob。调用方必须释放旧 writer instance 并重新 `open`，让 bootstrap 从磁盘 authority 收敛。该规则覆盖 fast xattr、xattr-unsupported sidecar fallback、显式 sidecar、`afterManifestPublished` 以及 full checkpoint generation advance；它解决的是同一进程可见状态与 actor state 分叉，不把 directory-fsync failure描述成 power-loss 已证明。

base `manifest.json` 当前默认仍为 compact schema 3：不再重复持久化可由 partition + digest 重算的 manifest key；verbose schema 2 继续可读并在后续 checkpoint 升级。单-key `ManifestRecord` 仍为紧凑 schema 2：sidecar create record 从 filename 获得 key，tombstone 因没有 entry 可反算而持久化 32-byte key verifier；fast xattr create record从 xattr name 获得 key。旧 record schema 1 继续可读。未知/future schema、错误 filename/xattr key、generation 不一致、carrier `PhysicalBlobID` 不一致、重复 sequence 与最终重复 physical ownership 全部 fail closed。

#### package-internal schema4 directory-head candidate

schema4 目前只通过 package-internal 显式 migration 进入，`open()` 不会自动把 schema2/3升级；它仍是 research candidate，不是默认格式。当前未发布 candidate 使用 `directoryHeadV2` carrier profile：迁移先把已完整 replay / reconcile 的 logical state写入 generation+1 compact snapshot，并在 snapshot 内持久化 profile 与 32-byte semantic SHA-256 corruption seal，再建立两个 checksummed empty heads。seal覆盖 schema/profile、generation 与 canonical compact entries，用于检测非协同的落盘字段/entry损坏；它不是 keyed authentication，不能被描述成对有能力同时改内容并重算摘要的本机攻击者提供认证存储。早期未 sealed `directoryHeadV1` research profile 已退役，当前 reader fail closed而不继续兼容该未发布 candidate。旧 schema reader看到 schema4仍必须 fail closed，不能把新 delta静默当成 schema3空增量。

schema4 把 current-generation delta authority从每个 payload inode移到 `blobs` directory xattr：record name携带 generation、全局 sequence与 canonical Base32 manifest key，record body仍复用紧凑 `ManifestRecord`；两个 generation-scoped head xattr以 inactive-slot replacement构成 commit point。head保存 latest sequence、distinct-key count与 latest-record set commitment。recovery要求两份 head都存在且 checksum / generation / slot一致，只解码 head选择的 latest bodies；current record丢失、回退旧 record、duplicate committed sequence或 commitment mismatch全部 fail closed，stale/uncommitted body则不重新获得 authority。

常见 schema4 single-key mutation在 payload inode已 file-fsync 后可把 payload rename的 parent-directory sync与 record/head publication合并为同一个 `blobs` directory sync；公开 `stage()` 仍保持原完整 durability。第512个 distinct delta或 sequence overflow会退回 full snapshot checkpoint，并明确保留 payload `blobs` sync，因为 root manifest-directory sync不能替代它。任何 record/head publication ambiguity仍触发 reopen-required writer poisoning。独立 Release process-crash matrix固定 `afterPayloadRenamed -> miss`、`afterRecordSet -> miss`、`afterHeadSet -> hit`、`afterDirectorySynced -> hit`，仅声明 process crash，不声明 power loss。

schema4 hot path还维护两个只作为 actor proof/cache 的索引：`PhysicalBlobID -> logical key` ownership index与 exact live-byte total。bootstrap/checkpoint从完整 manifest重建；single-key mutation在 authority publication前做局部 ownership transition proof，publication成功后才原地更新 manifest与缓存。generic/multi-key candidate仍走 full validation + checkpoint，因此缓存错误不能反向定义 logical authority。该拆分消除了早期 candidate 每 mutation full-manifest validation、Dictionary COW、delta-state全量重建与无条件 live-byte reduce的 O(live/delta)重复工作。

schema3→schema4 migration只切换 logical authority，不在 migration/open 临界路径逐个扫描 live payload inode。被新 snapshot退休的 legacy sidecar可以从 bounded delta key / 后续 physical reconciliation重建并摊销删除；历史 schema3 payload manifest xattr则不同：checkpoint不会从仍存活 payload上清除旧 create xattr，因此长期 store的 legacy payload-xattr debt上界接近 live entry count（当前最多100,000），不能误写成“最多511”。schema4 bootstrap刻意不读取这些 stale payload xattr，所以 reopen仍保持 directory-head的 bounded delta discovery；显式 `garbageCollect` 已经执行 full physical pass，因而成为唯一的 strict偿还 surface：它对每个仍 live的 payload carrier验证 legacy xattr name/generation、bounded `ManifestRecord` body、logical key与 `PhysicalBlobID`，验证后删除并 file-fsync；corrupt/foreign lookalike或不能持久清理时返回 `storageUnavailable`，逻辑 schema4 authority不回滚，外部条件修复后可幂等重试。CT-113–123固定 sidecar与payload-xattr debt的发现、清理、fail-closed与retry语义。该机制证明“债可严格偿还”，**尚未**使自动migration qualified。

package-only maintenance probe把这笔一次性资源债与正常 reopen/commit分开计时。64-byte live payload的单次方向性样本中，schema3→schema4后 legacy payload-xattr 数约为999 / 3993 / 15,969（1k / 4k / 16k entries；checkpoint-triggering commits不产生 fast-xattr），strict GC分别约0.17 / 0.33–1.11 / 1.72–2.08秒；同一16k store清零后再次执行 strict GC约0.64秒。主机/FS cache噪声明显，因此这些数字不是 formal performance claim，也不能线性外推100k；它们只证明 cleanup属于显式 O(live) maintenance，而不是应该同步塞进 migration/open的工作。当前选择保留每次 strict GC对 Akashic manifest-xattr namespace的发现能力，不增加“已清理”持久 marker；这样避免 marker把后续外部 namespace corruption隐藏在 maintenance之外。公开 `BlobMaintenanceResult` 不暴露 xattr/sidecar布局计数，schema-specific metadata work只进入 resource probe/conformance，防止物理布局反向成为宿主逻辑 contract。

root manifest缺失不再等价于“首次初始化”。bootstrap在准备目录后，只有当 `blobs` 目录确实没有任何物理条目、且没有可识别的 schema4 `md1/mh1` directory-head family metadata时，才允许创建初始空 manifest；否则必须在 reconciliation之前 `invalidManifest` fail closed。这样外部删除 `manifest.json` 不会先生成一个空 authority再把仍存 payload当 orphan清掉。logical-empty schema4 也由双 head证明“这是 established store”而不会被重置；malformed Akashic head-family metadata同样阻止初始化。为保留 schema3 sidecar fallback，physically fresh root若底层明确返回 `ENOTSUP/EOPNOTSUPP` 则仍可初始化，因为这种介质无法携带 schema4 directory-head authority。CT-126–129固定该 freshness边界。

### Writer 与 reader

- 每个 store root 只有一个活动 writer；
- 同进程 registry 防止 POSIX record-lock 的同进程多描述符缺口；
- `lockf` 提供跨进程 writer exclusion；
- writer 退出后内核释放锁，后续进程可重开；
- 首版只声明同一 actor/store instance 内的并发 reader，不声明多进程 reader snapshot。

### StoreGeneration

`StoreGenerationDirectory` 将兼容 fingerprint 绑定到 typed `StoreGenerationID`，通过 descriptor 与 CURRENT pointer 原子切换。未知 schema fail closed 并保留原文件。当前磁盘格式使用新 generation，不复用任何早期嵌入格式。

### 恢复与安全

启动恢复会：

- 清理根目录和 blob 目录的耐久写入临时文件；
- 删除 manifest 未引用的孤儿 blob；
- 移除缺失或超限逻辑条目；
- 验证 regular-file、单 hardlink、owner、权限和 O_NOFOLLOW；
- 对读取时的删除、截断或 digest mismatch 做 quarantine。

恢复枚举有硬目录项上限。当前实现不把 process-crash 结果描述为 power-loss 证明。

### 故障注入与进程恢复

`DurableFileWriter` 的 package-only syscall table 可替换同步 `open(2)`、`write(2)`、`fsync(2)`、`close(2)` 和同目录 `rename(2)`；生产入口始终绑定真实 Darwin 调用，外部消费者不可访问。10 项测试覆盖临时文件 open 失败、部分写入、write/fsync `EINTR`、前缀写入后的 `ENOSPC`、file-fsync 失败、close 失败、rename `ENOSPC`、rename 后父目录 open 失败和 directory-fsync 失败。package-only `renameObserver` 只在 rename 真正成功后触发：rename 自身失败时保持 false，而父目录 open/directory-fsync 的 post-rename 错误必须为 true。上层 manifest writer据此区分“尚未发布”与“磁盘 authority 已可能领先 actor”的错误边界；后一类错误冻结当前 writer instance，原始底层错误仍原样返回。

权限迁移测试在 manifest 临时文件完成 file `fsync` 后真实执行 `chmod(0500)`，使父目录 rename 因 `EACCES`/`EPERM` 失败。恢复 0700、释放 writer 并重开后，逻辑状态必须为 miss，未发布 blob 与临时 manifest 必须被 bootstrap 清理。

真实满卷矩阵创建并挂载三个独立的 64 MiB APFS 稀疏磁盘映像。验证器先把卷写到内核返回 `ENOSPC`，再分别验证：底层 durable replacement 保留旧 destination；blob stage 失败不破坏既有 entry；blob 已 stage 后在 manifest publication 期间耗尽空间，退出并释放 writer 后重开会删除 orphan 与临时文件。三个案例均要求底层 `errno=28`、既有 baseline hit、目标 miss 和精确物理 blob 数量。该证据只覆盖真实挂载 APFS 的容量耗尽，不覆盖 quota、物理设备或断电。

真实 quota 矩阵在三个独立的 1 GiB APFS 稀疏容器中创建 64 MiB 配额卷。每个失败点都要求容器本身仍有至少 payload 八倍的自由空间，从而排除整卷容量耗尽。durable replacement、blob stage 与 manifest publication 均直接保留内核 `ENOSPC`；quota V2 证据要求三个案例全部暴露 `errno=28`。释放外部 filler 并重开后，三项均要求 baseline hit、target miss、精确 blob 数量和零临时文件。该证据不等于物理设备或断电资格。

进程级证据把三套 transaction 明确分开：11-point 显式 stage/publish sidecar matrix、11-point schema3 fast-commit payload-xattr matrix，以及4-point package-internal schema4 directory-head matrix。schema4 matrix固定 payload rename / record xattr / head xattr / directory sync 四个真实 `_exit` 边界，对应 reopen 的 miss / miss / hit / hit；三者都由 Release `AkashicCrashProbe` binary执行并要求 `processCrashClaim=true`、`powerLossClaim=false`。此外保留 3 轮固定种子的随机 `SIGKILL` campaign：每轮在 child 完成 store open 后同步启动 8 MiB stage/publish，包含一个严格 miss 锚点、一个严格 hit 锚点和 24 个 0–10 ms 随机延迟；总计 78 个终止案例，其中 72 个是真正的随机时序样本。重开只接受完整 hit 或完整 miss，并要求随机样本本身同时覆盖两种状态。详见 `docs/FAULT_INJECTION.md`。

### 本地资源包络

`AkashicResourceProbe` 在独立进程中执行三个保留 workload。resource schema 3 分开记录 UUID payload regular files、metadata regular files 与 manifest xattr value bytes；xattr 只进入 logical metadata accounting，不伪装成 regular-file allocation。验证器保留 RSS/FD/时延边界，并固定 logical-write amplification 上限：64 × 4 KiB ≤ 1.06×、32 × 64 KiB ≤ 1.005×、8 × 1 MiB ≤ 1.001×。独立 parent 还用 `proc_pid_rusage/RUSAGE_INFO_V4` 在 population 前后采 `ri_diskio_byteswritten`：当前 xattr fast-create 的三个 workload 分别为 1.015625×、1.001953×、1.000488× process-visible filesystem write ratio；同源码 sidecar control 恰好多出每个 blob 一个 4 KiB write。该计数仍不是 NAND/controller 或断电持久化声明。

同一 source-bound candidate 的 reopen-scaling probe 还暴露了当前默认 schema3 **per-payload xattr discovery** 的规模边界：64-byte payload、已 checkpoint 无 active sidecar 的 1k / 4k / 16k resident stores会随着 physical blob 数增长；最新同-workload schema3/schema4 A/B 在 source-bound candidate 上测得完整 reopen约 **63.4 / 233.4 / 1215 ms → 22.7 / 88.8 / 327 ms**，其中 manifest-record replay段约 **48 / 163 / 909 ms → 2.35 / 8.59 / 37.7 ms**。这表明 directory-head把 delta-authority discovery从 O(total payload blobs)收敛到 bounded delta metadata；storage reconciliation本身仍随 live entries增长，没有被隐藏到其他 phase。16k 是实际方向性测量，100k entry上限仍只作为规模风险，不外推正式性能数字。

公平 steady-population ledger把初始化排除在 barrier外，并让 schema3预建空 store、schema4预建后显式迁移。当前 source-bound 64-byte / 1 KiB / 4 KiB / 64 KiB workload的 process-visible filesystem-write ratios两种 schema完全相同：64× / 4× / 1× / 1×；schema4不重新引入每对象额外 metadata page。64-object小对象 population的 commit wall约比 schema3多固定 5–6 ms，32×64KiB则基本持平；该差异只用于机制/复杂度方向判断，不是 formal host-performance claim。64/128/256/511 distinct-key scaling在当前 candidate上约为 schema3 20.8/44.5/101.7/121.0 ms，schema4 25.6/50.2/104.7/155.7 ms；256 keys已接近，511仍存在尾部/主机噪声与固定协议成本，不能描述为全面支配。

该证据不等于物理磁盘 I/O：page cache、APFS copy-on-write、控制器写放大和 fsync 的硬件持久化均不在逻辑字节计数中。报告因此固定 `physicalIOBytes=false`、`physicalDevice=false`、`energy=false` 和 `powerLoss=false`。

verified payload read 现显式实现为 `async throws`：这与 `BlobStoring` 原本的 async contract 一致，但把过去由 actor 隔离隐式适配的 concrete sync symbol升级成真正可 suspension 的 public witness，因此属于 pre-1.0 public-symbol演进。文件系统 read+digest在专用有界 scheduler上执行，最多4个 blocking workers并同时受 in-flight payload-byte budget约束；actor恢复后按 `PhysicalBlobID`重新核对 authority，旧 carrier失败不能 quarantine 已替换的新 carrier。严格 FIFO保留大请求不饥饿语义；pending cancellation以 token→slot索引定位，256个逆序取消的回归只允许 blocked first与唯一 survivor进入 blocking I/O，避免 cancellation storm在 scheduler lock内反复线性扫描队列。该 scheduler仍只声明同一 store instance内的并发 reader，不扩大到多进程 snapshot/lease。

## 证据边界

当前已验证：

- 当前 candidate 的本地全测试面为 Swift Testing 154/154（Memory 25、Disk 113、Core 16），CT-001–181 conformance verifier要求0 errors；CT-016已用本机只读 different-owner regular descriptor补齐 owner-only `fstat` gate，当前运行实际走的是非root/root-owned-system-file路径，root runner的temporary-chown fallback已编译但不宣称root-runtime qualification。schema4仍为 package-internal candidate；CT-112同时具备 current-source schema3-capability减法控制与 annotated historical tag `0.1.0-alpha.5` 的未修改源码重建 downgrade control，两者都对 committed schema4 fail closed，后者还验证拒绝前后 `manifest.json` 字节不变，但原始分发历史 binary artifact仍未 qualification，因此继续是 `partial-local` 且 `automaticMigrationQualified=false`。CT-050–070固定 sharded SIEVE预算、epoch与 exact-successor selector；CT-075–087固定 post-authority divergence、physical cleanup debt、schema3 debt-seal与 carrier-loss rollback；CT-088–111固定 schema4 directory-head identity/head commitment、recovery、O(1) hot-path proof与single-key独立 process-crash transaction；CT-113–123固定 migration后 legacy sidecar/payload-xattr physical metadata debt的发现、strict偿还、lookalike fail-closed与retry；CT-124/125分别固定 distinct-key full-checkpoint 7-point process-crash事务与 recovery-of-recovery 的0→1→2 head收敛；CT-126–132固定 bootstrap freshness、rollback与 schema4 snapshot semantic seal；CT-133–141固定有界并发 verified-read、旧 carrier race、worker/byte/pending budget、pending cancellation、O(1) token index，以及 blocked FIFO head 下 cancellation tombstone backing slots 的硬上界；CT-142–157固定 schema5 V2 binary-base 的 profile 分离、迁移、checkpoint、compaction 与 fault convergence；CT-158–167固定 V3/baseBinaryV2 的独立 profile、真实 FileBlobStore qualification seam 与 checkpoint/compaction rename-boundary convergence；CT-168–174固定默认 schema3 recovery-headroom、物理 debt 与失败后有界 recount；CT-175–181固定 V3 checkpoint tombstone/PhysicalBlobID transfer，以及 V4 compound-run、compound-preseal fallback 与 64-run hard-cap 前进性，且这些 segmented V3/V4 条目全部保持 scope-limited candidate 证据。任何“当前 source-frozen 综合基线”仍必须同时通过首尾 source identity compare，不能仅由测试计数推出；
- 11 项 durable-writer syscall行为、1 项真实权限迁移、3 项真实 APFS 满卷恢复、3 项真实 APFS quota 恢复、stage/publish 与 schema3 fast-xattr 各11个精确 `_exit` switch points、schema4独立4-point process-crash matrix，以及3轮78个随机 `SIGKILL` 案例；
- 6 个 Apple Release 编译案例；
- 正向/负向外部 consumer、API、privacy、structure、source identity v2 和 clean-copy replay；身份 v2 对 schema/identity ID 做域分离，区分仅顶层构建排除与任意层级临时文件排除，独立绑定完整覆盖范围、逐文件摘要与可执行位，clean-copy materializer 重新枚举来源树并直接写出已校验字节；
- 3 个本地 macOS 资源 workload，记录峰值 RSS、采样 FD、逻辑 I/O、增量 metadata 写入、分离的 payload/metadata footprint 与 reopen latency。

尚未验证：

- 真正设备断电；
- 真实 `open`、ACL、owner 迁移，以及由真实文件系统触发的 `fsync`、directory `fsync`、rename 和 close 错误；
- 多进程 reader；
- 稳定真机的物理 I/O、RSS/FD 复核、能耗和长期资源包络；
- Fovea host transaction、revoke 与 final-delivery 组合性质已有一次双端 source-bound temporary package-slice qualification，但 durable host-owned conformance receipt 尚未建立，因此 CT-022–026 仍不视为闭合。
