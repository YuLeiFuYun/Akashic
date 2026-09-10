# Akashic Roadmap

Akashic is an actively developed pre-1.0 cache and durable blob-store package. The repository contains only the current contracts, implementation, tests, and evidence required to validate the present storage model.

## Current baseline

- Independent SwiftPM products: `AkashicCore`, `AkashicMemory`, and `AkashicDisk`.
- Typed digest, partition, physical-blob, generation, stage, publication, and maintenance contracts.
- SIEVE memory cache with bounded cost and reference-model differential tests.
- Partition-scoped disk deduplication, stage/publish/discard, one active writer, generation switching, corruption quarantine, and bounded recovery. Incremental compact manifest records and segmented checkpoint/base candidates replace the historical full-manifest-per-mutation design while preserving fail-closed replay and ownership checks.
- Reusable `BlobStore` v1 component conformance kit: twelve independent-consumer obligations cover public partition, transaction, integrity, maintenance, reopen, generation, and writer-ownership semantics without claiming host composition or crash/power-loss qualification.
- Syscall fault injection, permission-transition, APFS full-volume/quota, process-crash, random-kill, multi-process contention, platform, API, privacy, and clean-copy gates.

## Active priorities

1. Continue qualifying the existing incremental-record plus bounded checkpoint/compaction design. Source-bound locality/recovery evidence shows that changing the base/run profile alone does not materially reduce ordinary foreground small-object metadata writes, while binary-base profiles reduce recovery footprint/replay work. The completed V1/V2/V3 full compaction mechanism matrix further shows repeatable maintenance-byte/instruction/base-size reductions for V2/V3; a five-repetition falsification of the worst single-run latency outliers did not reproduce the earlier multi-x p95 spikes, but remains non-formal wall-time evidence. Existing V2/V3 crash/fault convergence stays green. Therefore judge profile promotion by foreground non-regression plus net maintenance/recovery benefit, not by demanding that an encoding-only change magically improve the unrelated mutation-write path. Keep promotion blocked on stable-device physical I/O, latency/energy evidence and the remaining V4 scheduling/rollout decision; do not reintroduce full-manifest rewrite as the default design.
2. Preserve the `ShardedMemoryCache` non-reporting insertion fast path independently from exact eviction reporting. The published alpha.7 rerun exposed a hot-scan dominance regression; revision A/B isolated most of that delta to carrying a nil reporting collector through every ordinary insert. The repair has now been reduced to an exact-alpha.7 four-file candidate with Git-free source identity `117ae5fb9aae74a43a326ba0ab27d177ed4fe6890d3f575a7328b49e339636a3`: it physically separates ordinary and reporting insertion, passes the complete Akashic verification surface, and passes Fovea's isolated production-component composition at 965/965. A final frozen-Fovea, edited-dependency Cache Lab campaign accepted 20/20 clean blocks with all thirteen primary dominance comparisons passing; hot-scan throughput versus LRUCache had a median ratio about 1.249x and a 95% ratio interval about 1.240x--1.263x. This remains local source-bound research evidence, not release evidence, because the dependency resolution is edited/untrusted (`sourceResolutionBound=false`). Publish an immutable Akashic revision first, update Fovea's exact pin, and rerun the governed campaign with clean source-control resolution before activating a current-stack performance certificate. Separately, the CT-141 pending-read stress test has a test-only liveness hardening that replaces scheduler-iteration waiting with a real deadline and guarantees first-read release on failure; an isolated clean-HEAD campaign executed the nine-test concurrent-read suite twenty times with CT-141 actually starting and passing in every run, then passed full `verify.sh`. That test-governance patch is not part of the four-file alpha.7 release candidate.
3. Extend real-filesystem evidence beyond the qualified parent-mode and ACL create/rename denials plus post-rename directory-open denial to different-owner transitions, real directory-`fsync`, and real close failures. The ACL witnesses now require exact pre/post ordered ACL-entry snapshot equality with unchanged POSIX mode, rather than treating successful rule removal as sufficient restoration proof. The syscall matrix separately covers injected directory-`fsync` and post-`fsync` directory-close failures, so do not treat those injections as kernel/filesystem witnesses.
4. Add long-duration kill-at-random and independent physical power-loss qualification.
5. Measure physical I/O, metadata write amplification, RSS, file descriptors, reopen latency, and energy on stable macOS and iOS devices.
6. Specify multi-process reader snapshot and lease semantics before exposing them.
7. Keep the completed component-level `BlobStore` kit separate from host evidence; run Fovea's persistent-store provider conformance against a real independent provider and bind revoke/record/cross-store composition receipts.
8. Keep host authorization, HTTP semantics, namespace revocation, and cross-store commit coordination outside Akashic.

## Release policy

- `main` may contain breaking changes before 1.0.
- Every published development tag is immutable.
- Stable claims require clean-clone CI, API review, crash/recovery evidence, and source-identity-bound results.
- Process termination evidence is not described as physical power-loss proof.
