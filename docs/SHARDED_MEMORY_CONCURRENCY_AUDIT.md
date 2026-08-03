# ShardedMemoryCache concurrency audit

Reviewed: 2026-08-02

`ShardedMemoryCache` is synchronously callable and intentionally conforms to `Sendable` through an
explicit lock discipline rather than actor isolation. This file records the proof obligations behind
that boundary.

## Mutable-state ownership

Each shard owns its hash buckets, collision links, FIFO/SIEVE links, hand, cost limit, resident count
and total cost. Every access to those fields is performed while that shard's `os_unfair_lock` is
held. A key's value and visit bit never move between shards during an ordinary operation.

Global configuration consists of the exact total cost limit and the immutable shard topology. The
configuration lock is acquired before all shard locks for limit changes, filtered purge, clear,
aggregate snapshots and the large-entry budget-redistribution slow path. Shard locks are always
acquired in ascending array order and released in reverse order. No ordinary single-shard operation
attempts to acquire the configuration lock, so the lock graph has no reverse edge.

## Global budget semantics

Ordinary inserts are accepted only when they fit the current shard budget. A value that exceeds that
budget but fits the global budget enters the all-shard slow path. That path accounts for the replaced
value, preserves every shard's current resident cost when the aggregate fits, and shrinks other
shards only when the aggregate demand exceeds the global limit. A value larger than the global
limit removes an existing value for the same key and leaves a miss, matching `MemoryCache`.

The sum of active shard limits is always exactly the public global limit after initialization,
explicit resizing, clear, or redistribution. All aggregate observations are made with every shard
locked, so `currentCost <= costLimit` is observed atomically.

## Hash and node safety

The key hash is computed once per public operation. Low bits select a power-of-two shard and the next
bits select a power-of-two bucket. Buckets use explicit collision chains and compare both the stored
raw hash and the key. Victim-node recycling first removes the node from its old collision chain and
FIFO links, then overwrites identity fields and reinserts it; no published chain can contain the
node under two identities.

## Evidence

- `AKASHIC-CT-035`: exact aggregate budget and concurrent unit-cost traffic.
- `AKASHIC-CT-036`: atomic global resizing and exact removal accounting.
- `AKASHIC-CT-037`: scan-resistant hot-set retention.
- `AKASHIC-CT-038`: large-entry global-budget borrowing, global oversize rejection, and `Int.max` overflow-safe replacement.
- `AKASHIC-CT-039`: one-shard differential against classic SIEVE over 4,000 operations.
- `AKASHIC-CT-040`: equal-hash collision chains across deletion and victim recycling.
- `AKASHIC-CT-041`: shrinking below a borrowed entry restores the global bound.
- `AKASHIC-CT-042`: concurrent shard traffic, redistribution, resizing and filtered purge.
- Temporary Fovea integration: 478/478 tests passed with the sharded memory candidate and disk v2;
  the production switch was then reverted until a public Akashic revision exists.
- Cache Lab V2 final tree-bound campaign: twenty clean process blocks and twelve of thirteen applicable
  comparisons above the dominance margin; hot throughput versus LRUCache missed the lower bound.
- Cache Lab V3 was archived after finding that the plan declared twenty hot rounds while the
  implementation executed one; its full campaign also had three dominance failures.
- Cache Lab V4 executes twenty fresh-cache rounds. Sixteen shards retained 619/640 hot probes and
  thirty-two shards retained only 21/32 per diagnostic round, so both configurations were rejected.
  Eight shards passed five independent diagnostic processes, then the V4 scope-all campaign accepted
  twenty clean process blocks and cleared all thirteen applicable dominance comparisons.

This audit establishes the local synchronization argument. The performance result remains research
evidence because the dependency is edited and the worktrees are dirty. It does not substitute for Thread
Sanitizer, formal linearizability checking of non-commuting shared-key histories, or independent
review; those remain release-strength follow-up evidence.
