# Akashic Roadmap

## 当前状态：P4 本地独立垂直切片与故障证据加固

已经本地实现并验证：

- 中立 typed Core contract；
- SIEVE MemoryCache；
- typed FileBlobStore；
- partition-scoped physical deduplication；
- stage/publish/discard；
- 单活动 writer 与跨进程内核锁；
- StoreGeneration 创建、切换和恢复；
- future-schema fail-closed；
- corruption quarantine、orphan/temp reconciliation；
- symlink、hardlink、file type、owner 和 permission-mode 检查；
- 有界维护输入与 POSIX 目录读取；
- 41 项测试、8 项 syscall 故障、1 项真实权限迁移、3 项真实挂载 APFS 满卷恢复、3 项真实 APFS quota 恢复、11 点精确 crash matrix、3 轮 78 案例随机 `SIGKILL` campaign、6 案例平台矩阵和 3 个本地资源 workload；
- 正向与负向外部 consumer、128 符号 public API、privacy、structure、source-identity 和 clean-copy 门。

公开 remote 与核心 CI workflow 已建立；现有结果仍缺少稳定 tag、required check、真机和断电资格，因此不是 release candidate。

## 下一里程碑：P4 证据加固

1. 扩展到真实 `open`、ACL、owner 迁移，以及由真实文件系统触发的 `fsync`、directory `fsync`、rename 和 close 故障；
2. 将当前 3 轮 78 案例固定种子 campaign 扩展为数小时级、高迭代 kill-at-random 恢复；
3. 将当前本地进程 RSS、采样 FD、逻辑 I/O 与 manifest 重写证据扩展到稳定 macOS/iOS 设备，并测量物理 I/O、write amplification 和 energy；
4. 对比 `fsync` 与 `F_FULLFSYNC`，并设计独立于进程终止的物理断电/文件系统持久化实验；
5. 增加非可交换共享键并发历史的线性化分析或等价独立验证；
6. 在受保护 CI 的真正 clean clone 中重放完整门。

## P4 发行治理

在下列条件确定前不创建版本：

- resolvable remote 与所有者（已建立）；
- 核心 CI workflow（已建立）与 required checks（待启用）；
- API/compatibility/version policy；
- exact first tag 或 commit pin；
- clean source identity；
- rollback artifact；
- 独立审查和新 clone 复验。

## P5 Fovea 集成

独立组件门通过后：

1. 在隔离 Fovea worktree 通过 local path dependency 接入；
2. 由 Fovea adapter 映射 `ContentID -> BlobDigest`；
3. 由 Fovea composition 映射 security namespace/generation -> `CachePartitionID`；
4. 保留 HTTP records、authorization、revoke barrier 和 cross-store commit 在 Fovea；
5. 使用新 StoreGeneration，不做同步全量迁移；
6. 对嵌入实现与独立实现重放同一 storage trace；
7. 运行 W3、W8、W13、故障、revoke 和 rollback；
8. 等价门通过后才删除 Fovea 内嵌 Akashic production source；
9. 最终依赖固定到 exact release identity。

## P6 兼容性治理

建立：

- current/previous Fovea × current/previous Akashic 矩阵；
- API refinement 与 breaking-change 分类；
- StoreGeneration compatibility/new-generation/inconclusive 分类；
- consumer、crash、resource 和 host-composition evidence 分层；
- 不把组件通过等同于 Fovea 组合通过。
