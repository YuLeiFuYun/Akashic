# ShardedMemoryCache concurrency audit

Reviewed: 2026-08-12

`ShardedMemoryCache` is synchronously callable and intentionally conforms to `Sendable` through an
explicit lock/atomic discipline rather than actor isolation. This document records the proof
obligations for the current implementation only.

## Mutable-state ownership

Each shard owns its hash buckets, collision links, FIFO/SIEVE links, hand, assigned cost limit,
resident count and resident cost. Every access to those fields is performed while that shard's
`os_unfair_lock` is held. Ordinary lookup and steady-state eviction never acquire another shard.

Global configuration consists of the exact total cost limit and immutable shard topology.
`configurationLock` is acquired before all shard locks for total-limit changes, filtered purge,
clear, aggregate snapshots and the rare cross-shard redistribution path. Shard locks are acquired in
ascending array order and released in reverse order. Ordinary single-shard operations never acquire
`configurationLock`, so the lock graph has no reverse edge.

Unassigned global cost is stored in an internal `CAkashicAtomics` 64-bit atomic. Its Clang
`__atomic_*` operations are available at Akashic's existing iOS 15 / macOS 12 deployment floor; the
public Swift API and deployment targets do not change.

## Global budget invariant

At every completed cache operation:

- each shard's assigned limit equals that shard's actual resident cost;
- the atomic unassigned-cost pool equals `totalCostLimit - sum(shard resident costs)`; and
- therefore aggregate resident cost never exceeds the public total limit.

An insert locks only its target shard and atomically takes up to the incoming cost from the global
pool. The temporary assigned limit may expand while that shard lock is held. The insert then runs the
same local SIEVE machinery as the classic cache, shrinks the shard limit back to actual resident
cost, and returns any unused assignment to the atomic pool before releasing the shard lock.
Replacement inserts deliberately do not pre-read the bucket merely to calculate replacement cost;
claiming at most the incoming cost and returning any surplus avoids a duplicate hot-path key lookup.

A remove similarly mutates and normalizes its shard, then returns released cost to the global pool
before releasing the shard lock. This ordering is required: returning cost after unlocking would let
a concurrent total-limit change rebuild the pool from a new snapshot and then receive stale budget
from the old operation.

Because every pool claim/return that corresponds to a shard mutation occurs while that shard is
locked, an operation holding all shard locks observes a stable resident/pool state. The all-shard
path recomputes the pool from resident ground truth before it releases those locks.

## Cross-shard slow path

Hash skew is not allowed to reduce effective capacity. If a target shard can fit an incoming object
using its resident assignment plus currently unassigned global cost, no other shard is touched. The
target may use all relevant spare first and perform any remaining victim selection locally.

Only when the single incoming object itself cannot fit in the target's resident assignment plus all
currently unassigned cost does Akashic enter the all-shard slow path. The required cross-shard deficit
is computed exactly. Each donor shard initially exposes only its **current legal SIEVE victim**.
Different immediate victim costs use the same greedy rule: largest cost below the remaining deficit,
otherwise smallest immediate overshoot; the first victim exactly equal to the deficit returns
immediately because zero overshoot is already globally optimal. Equal-cost under-deficit ties normally
retain target-relative ring order. Only then does a cold helper ask the tied shards for a nonmutating
one-successor forecast; a shard whose successor exactly equals the post-first-step deficit may win the
tie. This is non-regressing because the next greedy step can release exactly the original deficit, and
it does not perform general multi-step optimization.

`updateCostLimit` locks all shards. Growth preserves all residents. Shrinkage caches only each shard's
immediate victim and refreshes only the shard actually mutated by a removal. Successor state has no
standing cache or allocation: it is scanned directly only inside the rare exact-successor tie helper.
This keeps ordinary all-shard slow paths close to the immediate-only selector while retaining the
safe tie improvement. The operation then canonicalizes every shard limit to resident cost and sets
the atomic unassigned pool from the new ground truth. Clear and filtered purge use the same
canonicalization rule.

## Hash and node safety

The key hash is computed once per public operation. Low bits select a power-of-two shard and the next
bits select a power-of-two bucket. Buckets use explicit collision chains and compare both the stored
raw hash and the key. Victim-node recycling first removes the node from its old collision chain and
FIFO links, then overwrites identity fields and reinserts it; no published chain can contain the node
under two identities.

Bucket sizing still uses the initial even partition as a sizing hint even though runtime capacity is
dynamic. Empty shards start with zero assigned cost, so the sizing hint cannot become a capacity
reservation.

## Current correctness evidence

- `AKASHIC-CT-035`: exact aggregate bound under concurrent unit-cost traffic.
- `AKASHIC-CT-036`: dynamic limit changes preserve the aggregate bound and exact removal accounting.
- `AKASHIC-CT-037`: scan-resistant hot-set retention.
- `AKASHIC-CT-038`: large-entry global-budget borrowing, global oversize rejection and `Int.max`
  replacement safety.
- `AKASHIC-CT-039`: one-shard differential against classic SIEVE over 4,000 generated operations.
- `AKASHIC-CT-040`: equal-hash collision chains across deletion and victim recycling.
- `AKASHIC-CT-041`: shrinking below a borrowed entry restores the global bound.
- `AKASHIC-CT-042`: concurrent shard traffic, redistribution, resizing and filtered purge.
- `AKASHIC-CT-043`: global spare prevents shard-local premature eviction under intentionally skewed
  routing.
- `AKASHIC-CT-044`: cost released by one shard is reusable by another without an avoidable local
  eviction.
- `AKASHIC-CT-050`: a 99/100-cost skewed fixture with a one-unit cross-shard deficit retains 97/98
  unit-cost donor entries instead of evenly repartitioning the donor capacity.
- `AKASHIC-CT-051`: an intentionally skewed 60-cost resident survives a 75→60 exact global shrink
  and a subsequent 60→75 expansion with zero removals, fixing the no-op/equal-cost resize boundary.
- `AKASHIC-CT-052`: global shrink compares each shard's current legal SIEVE victim and, for a
  102→101 limit change, releases one 1-cost resident instead of an avoidable 100-cost resident from
  a later shard.
- `AKASHIC-CT-053`: cross-shard insert reclamation applies the same immediate best-fit rule to donor
  shards, so a one-unit deficit uses an available 1-cost donor instead of the first ring donor's
  100-cost resident.
- `AKASHIC-CT-068`: a 24-seed × 600-step shard-local differential checks the two-victim forecast
  against the actual next two SIEVE removals after randomized insert, hit and remove transitions.
- `AKASHIC-CT-069`: global resize fixes the retained `[1,6]` versus `[1,8]`, deficit-9 topology tie by
  releasing exactly `1+8=9` instead of 16 while preserving the immediate greedy victim-cost class.
- `AKASHIC-CT-070`: cross-shard insert exercises the same tie rule with a 9-cost incoming object and
  preserves the competing `[1,6]` donor chain.
- Before implementation, bounded exhaustive research over 4,194,304 two-shard, three-victim states
  rejected both general two-step look-ahead and unrestricted tie-only look-ahead because each created
  new regressions. The retained exact-successor rule produced zero regressions and 46,153 improvements
  versus immediate greedy in that model; this supports, but does not replace, the Swift state-machine
  and public-behavior tests above.
- The current source-bound scratch run contains 84 passing Swift Testing cases: 25 memory/concurrency
  and reference-model cases, 45 disk/generation/manifest cases, and 14 core identity/durable-syscall
  fault cases.
- Full `scripts/verify.sh` must pass structure, warnings-as-errors Debug/Release, positive/negative
  consumers, the 140-symbol public API baseline and two identical Git-free source-identity passes.
  The concrete identity is intentionally recorded outside this hashed source tree to avoid a
  self-referential documentation/hash cycle.
- `AkashicMemory` builds for `arm64-apple-ios15.0` with the internal atomic target.

## Performance evidence boundary

The published Akashic revision `2715f23d50b5a17b7328be41608eaf1b1c99b0d6` remains the source bound
to the historical Cache Lab V4 formal campaign. That campaign used the previous static per-shard
budget implementation and passed all thirteen applicable dominance comparisons in twenty clean
process blocks; it must not be silently rebound to this working tree.

For the current dynamic-unassigned-budget candidate, Fovea Cache Lab was temporarily placed in
SwiftPM edited-dependency mode against the local Akashic working tree. A five-block memory
calibration reported zero Fovea correctness failures, zero inferior endpoints, zero inconclusive
endpoints and zero dominance failures. The post-refactor five-block rerun against the verified source
reported directional median ratios versus LRUCache of approximately 1.298x hot-scan throughput,
1.624x lower hot-scan p99 latency, 3.257x concurrent throughput and 2.583x lower concurrent p99
latency. These runs are mechanism evidence only: the dependency is unpublished,
the host run is not a replacement for the governed twenty-block campaign, and no release/formal
claim is authorized from them.

## Downstream adoption boundary

Fovea's production package still pins the previously published Akashic revision. Local SwiftPM edit
mode may be used to verify this candidate against Fovea before publication, but that does not change
the production pin or establish release readiness. A new Akashic revision, source-bound Fovea
requalification and governed performance evidence are required before the production dependency can
move.
