import Foundation

extension MemoryCache {
    package func resourceProbeEvictionForecast(
        incomingCost: Int
    ) -> [MemoryCacheEvictionVictim<Key>] {
        atomic {
            resourceProbeEvictionTraceLocked(incomingCost: incomingCost).victims
        }
    }

    /// 研究探针使用：在不改变真实 visited、hand、FIFO 或 resident 状态的前提下，
    /// 精确模拟一次插入会消费哪些 visited second-chance，以及最终淘汰哪些对象。
    package func resourceProbeEvictionTrace(
        incomingCost: Int
    ) -> MemoryCacheEvictionTrace<Key> {
        atomic { resourceProbeEvictionTraceLocked(incomingCost: incomingCost) }
    }

    /// 研究探针使用：读取当前 visited/unvisited resident cost 分解，不改变任何状态。
    package func resourceProbeVisitState() -> MemoryCacheVisitState {
        atomic {
            var visitedCost = 0
            for node in entries.values where node.visitedEpoch == visitEpoch {
                visitedCost += node.cost
            }
            precondition(visitedCost <= totalCost)
            return MemoryCacheVisitState(
                residentCount: residentCount,
                visitedCount: visitedCount,
                residentCost: totalCost,
                visitedCost: visitedCost,
                unvisitedCost: totalCost - visitedCost
            )
        }
    }

    /// 研究探针使用：读取 SIEVE hand 在 FIFO resident ring 中的当前位置。
    /// `sieveHand == nil` 与 production 下一次 victim 搜索一致，视作 hand 位于 leastRecent。
    package func resourceProbeHandTopologyState() -> MemoryCacheHandTopologyState {
        atomic {
            guard let leastRecent else {
                return MemoryCacheHandTopologyState(
                    residentCount: 0,
                    residentCost: 0,
                    prefixBeforeHandCount: 0,
                    prefixBeforeHandCost: 0,
                    suffixFromHandCount: 0,
                    suffixFromHandCost: 0
                )
            }

            let effectiveHand = sieveHand ?? leastRecent
            var prefixCount = 0
            var prefixCost = 0
            var suffixCount = 0
            var suffixCost = 0
            var beforeHand = true
            var cursor: Node? = leastRecent
            while let node = cursor {
                if node === effectiveHand { beforeHand = false }
                if beforeHand {
                    prefixCount += 1
                    prefixCost += node.cost
                } else {
                    suffixCount += 1
                    suffixCost += node.cost
                }
                cursor = node.next
            }
            precondition(prefixCount + suffixCount == residentCount)
            precondition(prefixCost + suffixCost == totalCost)
            return MemoryCacheHandTopologyState(
                residentCount: residentCount,
                residentCost: totalCost,
                prefixBeforeHandCount: prefixCount,
                prefixBeforeHandCost: prefixCost,
                suffixFromHandCount: suffixCount,
                suffixFromHandCost: suffixCost
            )
        }
    }

    /// 研究探针使用：读取 resident value 但不授予 SIEVE visited second-chance。
    /// 该入口用于把“命中可返回”与“命中是否升级 retention protection”分开实验；
    /// package-only，不构成公共 cache policy contract。
    package func resourceProbeValueWithoutVisit(for key: Key) -> Value? {
        atomic { entries[key]?.value }
    }

    /// 研究探针使用：在不读取 value 的情况下，给仍 resident 的 key 授予与一次正常 hit
    /// 相同的 visited second-chance。用于研究延迟/批量 retention promotion；package-only。
    @discardableResult
    package func resourceProbeMarkVisited(for key: Key) -> Bool {
        atomic {
            guard let node = entries[key] else { return false }
            if node.visitedEpoch != visitEpoch {
                node.visitedEpoch = visitEpoch
                visitedCount += 1
                markEvictionStateChangedLocked()
            }
            return true
        }
    }

    /// 研究探针使用：主动撤销仍 resident key 的 SIEVE visited second-chance，便于验证
    /// speculation 到期后是否应释放 retention protection。package-only，不构成公共策略 API。
    @discardableResult
    package func resourceProbeClearVisited(for key: Key) -> Bool {
        atomic {
            guard let node = entries[key] else { return false }
            if node.visitedEpoch == visitEpoch {
                node.visitedEpoch = 0
                visitedCount -= 1
                precondition(visitedCount >= 0)
                markEvictionStateChangedLocked()
            }
            return true
        }
    }

    /// 研究探针使用：在真实 cache lock 下从当前有效 SIEVE hand 提取一次有界 shadow，
    /// 并计算 revocation-aware final eviction trace。`provisionalVisitedKeys` 只标记当前仍
    /// visited 的 speculative protection；未 visited key 不会被凭空提升为 provisional。
    /// 该入口只用于 package qualification，不改变真实 hand、visited 或 resident 状态。
    /// 返回值是持锁时刻的 snapshot diagnostic，不是跨锁边界可执行的 mutation plan：任意
    /// 后续 hit/insert/remove 都可能改变真实 victim。生产 admission 必须与最终 mutation
    /// 共享一个线性化边界，或在执行前验证完整 cache-state version。
    package func resourceProbeRevocationAwareEvictionPlan(
        provisionalVisitedKeys: Set<Key>,
        incomingCost: Int
    ) -> MemoryCacheRevocationAwareEvictionPlan<Key> {
        resourceProbeRevocationAwareEvictionSnapshot(
            provisionalVisitedKeys: provisionalVisitedKeys,
            incomingCost: incomingCost
        ).plan
    }

    /// Same diagnostic observation as `resourceProbeRevocationAwareEvictionPlan`, but binds the
    /// normalized pressure input and exact provisional resident incarnations for later optimistic
    /// validation. Only currently visited residents receive leases; stale provisional keys do not.
    package func resourceProbeRevocationAwareEvictionSnapshot(
        provisionalVisitedKeys: Set<Key>,
        incomingCost: Int
    ) -> MemoryCacheRevocationAwareEvictionSnapshot<Key> {
        atomic {
            let normalizedCost = max(1, incomingCost)
            var provisionalResidentLeases: [
                Key: MemoryCacheRevocationAwareResidentLease<Key>
            ] = [:]
            provisionalResidentLeases.reserveCapacity(
                min(provisionalVisitedKeys.count, residentCount)
            )
            for provisionalKey in provisionalVisitedKeys {
                guard let node = entries[provisionalKey], node.visitedEpoch == visitEpoch else {
                    continue
                }
                provisionalResidentLeases[provisionalKey] = .init(
                    key: provisionalKey,
                    identity: node,
                    incarnation: node.incarnation
                )
            }
            let plan = resourceProbeRevocationAwareEvictionPlanLocked(
                provisionalResidentLeases: provisionalResidentLeases,
                incomingCost: normalizedCost
            )
            return MemoryCacheRevocationAwareEvictionSnapshot(
                normalizedIncomingCost: normalizedCost,
                evictionStateVersion: currentEvictionStateVersionLocked(),
                provisionalResidentLeases: provisionalResidentLeases,
                plan: plan
            )
        }
    }

    /// Resource-bounded package-only observation for admission research. All three limits are hard:
    /// the method never returns a truncated executable plan. Provisional input is conservatively
    /// bounded before entering the cache mutex, so a huge stale key set cannot itself create an
    /// unbounded lock hold merely because few keys still happen to be resident.
}
