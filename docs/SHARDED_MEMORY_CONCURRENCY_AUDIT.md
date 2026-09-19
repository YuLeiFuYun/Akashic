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
  consumers, the 146-symbol public API baseline and two identical Git-free source-identity passes.
  The concrete identity is intentionally recorded outside this hashed source tree to avoid a
  self-referential documentation/hash cycle.
- `AkashicMemory` builds for `arm64-apple-ios15.0` with the internal atomic target.

The pending-read stress coverage also has a separate test-governance liveness fix. A real stuck test
process showed that CT-141's historical `2,000 * Task.yield()` polling loop was a scheduler-iteration
budget rather than a time budget, and that a failed observation could reach `churn.value` before the
blocked first read was released. The test-only patch uses a two-second `ContinuousClock` deadline,
fail-fast `#require`, unconditional first-read release, and postpones cancelled-task result validation
until after the blocking read is released. On a clean `16ec0e7c588068b062b53dff56211139f6de0b0f`
worktree with only that test file changed, `FileBlobStoreConcurrentReadTests` ran as a nine-test suite
twenty times; CT-141 actually started and passed in every invocation. The same isolated tree then
passed full `scripts/verify.sh`. This is test liveness hardening only and is deliberately excluded from
the four-file alpha.7 memory fast-path release candidate.

## Performance evidence boundary

The published Akashic revision `2715f23d50b5a17b7328be41608eaf1b1c99b0d6` remains the source bound
to the historical Cache Lab V4 formal campaign. That campaign used the previous static per-shard
budget implementation and passed all thirteen applicable dominance comparisons in twenty clean
process blocks; it must not be silently rebound to this working tree.

The dynamic-unassigned-budget implementation first shipped as `0.1.0-alpha.6`
(`2846d4715cc5917711ffa2f100ee310c2290de40`). The current `0.1.0-alpha.7`
(`0376b960ec8abe54f2d4a9d7d66e97f395215eaf`) preserves that budget model and adds exact
eviction-reporting variants for hosts that must mirror resident identity. A fresh governed Cache Lab
run against the exact published alpha.7 checkout accepted all twenty clean process blocks with no
correctness, inferior or inconclusive result, but the hot-scan throughput comparison against LRUCache
reached only about 1.162x (95% interval about 1.156x--1.171x). It therefore failed the preregistered
1.20x dominance floor even though it remained statistically superior. This is the current published
revision's result; the older alpha.5 thirteen-of-thirteen campaign is not rebound to alpha.7.

The regression was then isolated rather than tuned against the threshold. A same-host, fixed-hash
revision A/B showed the large alpha.6 sharded-budget refactor accounting for roughly 2--3% of the old
hot-scan delta, while the later eviction-reporting change added a further repeatable roughly 5--6%
cost to ordinary non-reporting `insert`. The cause was not victim-array allocation: ordinary insert
still carried a nil optional collector and its `inout`/conditional reporting path through every local
SIEVE eviction. A generic no-op sink made the path slower and was rejected. The retained candidate
physically separates ordinary insertion from reporting insertion while sharing only the post-eviction
node-install tail; exact reporting semantics remain covered by the public-behavior tests.

Fovea first edited Cache Lab to the broader verified development candidate without changing the V4
workload or statistics. Five memory blocks cleared every dominance comparison, and the subsequent
governed twenty-block scope-all campaign accepted 20/20 clean blocks with zero rejected attempts,
zero correctness failures, zero inferior/inconclusive endpoints and zero dominance failures. That
broader candidate's hot-scan throughput versus LRUCache was about 1.241x with a 95% interval about
1.227x--1.254x.

The implementation was then reduced further to an exact-alpha.7 four-file release candidate with
Git-free source identity `117ae5fb9aae74a43a326ba0ab27d177ed4fe6890d3f575a7328b49e339636a3`
across 411 files. It independently passes full Akashic verification and, together with the published
ImageCraft alpha.8 candidate, passes Fovea's isolated Seatbelt production-component composition at
965/965. After the Fovea source tree was frozen, a final governed edited-dependency Cache Lab campaign
for this exact four-file candidate again accepted 20/20 clean blocks, with zero rejected attempts,
zero correctness failures, zero inferior/inconclusive endpoints and zero dominance failures. All
thirteen primary comparisons passed dominance; hot-scan throughput versus LRUCache had a median ratio
about 1.249x and a 95% ratio interval about 1.240x--1.263x, clearing the locked 1.20x floor.

These runs prove host-visible recovery for the edited candidate, not a release certificate: the final
run reports `sourceIdentityBound=true`, `quiescentHostBound=true`, and both statistical gates true, but
`sourceResolutionBound=false` and `bestClaimEligible=false` because Akashic was an edited dependency.
Concrete source and host receipts remain outside this hashed source tree to avoid a self-referential
evidence cycle.

## Downstream adoption boundary

Fovea `develop` now pins `0.1.0-alpha.7` exactly at
`0376b960ec8abe54f2d4a9d7d66e97f395215eaf`, and its rendered-memory path constructs
`ShardedMemoryCache` and consumes the exact eviction report to keep its host-side cardinality governor
synchronized with byte-driven residency; Akashic's protected `core` check is green for that revision.
This closes publication and exact-pin adoption for alpha.7, but it does not promote the local fast-path
repair. The published alpha.7 twenty-block rerun has one locked dominance failure, while the exact
four-file edited candidate has complete Akashic verification, Fovea 965/965 composition, and a
source-bound/quiescent twenty-block thirteen-of-thirteen research result. The next lifecycle step is
therefore an immutable Akashic revision containing only the repair, followed by an exact Fovea pin and
a clean source-control-resolved twenty-block rerun. Protected release evidence and stable-device
resource qualification remain independent gates before any stable ranking claim.
