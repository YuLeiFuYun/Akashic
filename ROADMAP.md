# Akashic Roadmap

Akashic is an actively developed pre-1.0 cache and durable blob-store package. The repository contains only the current contracts, implementation, tests, and evidence required to validate the present storage model.

## Current baseline

- Independent SwiftPM products: `AkashicCore`, `AkashicMemory`, and `AkashicDisk`.
- Typed digest, partition, physical-blob, generation, stage, publication, and maintenance contracts.
- SIEVE memory cache with bounded cost and reference-model differential tests.
- Partition-scoped disk deduplication, stage/publish/discard, one active writer, generation switching, corruption quarantine, and bounded recovery.
- Syscall fault injection, permission-transition, APFS full-volume/quota, process-crash, random-kill, multi-process contention, platform, API, privacy, and clean-copy gates.

## Active priorities

1. Replace full-manifest rewrites with a design that reduces small-object write amplification without weakening recovery or schema guarantees.
2. Extend filesystem evidence to real `open`, ACL, owner, directory-`fsync`, rename, and close failures.
3. Add long-duration kill-at-random and independent physical power-loss qualification.
4. Measure physical I/O, metadata write amplification, RSS, file descriptors, reopen latency, and energy on stable macOS and iOS devices.
5. Specify multi-process reader snapshot and lease semantics before exposing them.
6. Extract a versioned storage conformance kit and current/previous host compatibility matrix.
7. Keep host authorization, HTTP semantics, namespace revocation, and cross-store commit coordination outside Akashic.

## Release policy

- `main` may contain breaking changes before 1.0.
- Every published development tag is immutable.
- Stable claims require clean-clone CI, API review, crash/recovery evidence, and source-identity-bound results.
- Process termination evidence is not described as physical power-loss proof.
