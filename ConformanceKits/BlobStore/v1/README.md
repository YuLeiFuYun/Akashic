# BlobStore Conformance v1

该 kit 是 Akashic 对公开 blob-store 合同的可复用独立消费者资格门。它验证 `BlobStoreMaintaining & TransactionalBlobStoring` 的逻辑隔离、阶段发布、删除/回收、重开语义，以及 `StoreGenerationDirectory` 的兼容代际边界；运行器在临时 SwiftPM 测试包中装配被测 backend，不导入 backend 的私有测试支持。

backend 仓库提供一个 factory source：

```swift
import AkashicCore
import YourBlobStoreProduct

enum BlobStoreUnderTest {
    static func open(
        root: URL,
        softTotalBytes: Int,
        maximumBlobBytes: Int
    ) async throws -> any BlobStoreMaintaining & TransactionalBlobStoring {
        try await YourBlobStore.open(
            root: root,
            softTotalBytes: softTotalBytes,
            maximumBlobBytes: maximumBlobBytes
        )
    }

    static func openGeneration(
        root: URL,
        compatibilityFingerprint: String
    ) async throws -> StoreGenerationDescriptor {
        try await YourGenerationManager.open(
            root: root,
            compatibilityFingerprint: compatibilityFingerprint
        )
    }
}
```

运行：

```sh
python3 ConformanceKits/BlobStore/v1/run.py \
  --backend-package-path /path/to/backend \
  --backend-product BlobStoreProduct \
  --factory-source /path/to/BlobStoreUnderTest.swift
```

v1 固定 12 条义务：partition 可见性/删除隔离、stage 在 publish 前不可见、publish 单终态、discard 幂等终态、同 partition 物理复用、跨 partition 禁止物理去重、digest 独立重算、remove/removeAll 权限边界、引用驱动的有界 GC、成功发布后的 clean reopen、compatibility fingerprint 的 generation 身份，以及单 writer 根目录所有权。输出遵循 `observation-schema.json`，并绑定当前 Akashic source identity、backend source、factory、harness、工具链与日志。

该 kit 只证明公开组件合同的有限本地行为，固定 `releaseQualified=false`。它不替代 Akashic 已有的进程崩溃矩阵、随机 kill、真实 ENOSPC/APFS quota、permission/owner/ACL、真实 `fsync`/close、物理断电或稳定设备资源证据；也不替代 Fovea 对 revoke、record publication、跨存储事务与宿主 composition 的独立资格证据。
