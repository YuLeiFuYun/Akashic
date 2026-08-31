# Fault-injection evidence

Akashic separates five non-equivalent failure layers. A passing mock or
process-termination test is never promoted into a physical power-loss claim.

## 1. System-call behavior

`DurableFileWriter` owns a package-only synchronous syscall table. Production
always binds it to Darwin `open(2)`, `write(2)`, `fsync(2)`, `close(2)` and
same-directory `rename(2)`; external consumers cannot supply replacements.

Eleven retained tests establish these local properties:

1. repeated partial positive `write` returns are consumed until every byte is
   written;
2. `write` returning `EINTR` is retried;
3. file and parent-directory `fsync` returning `EINTR` are retried;
4. failure to open the unique temporary file preserves the old destination and
   leaves no durable temporary file;
5. `ENOSPC` after a successful prefix write preserves the old destination and
   removes the temporary file;
6. file-`fsync` failure preserves the old destination and removes the
   temporary file;
7. a failing `close` is not retried on the same descriptor, because descriptor
   state after an error must not be guessed; the old destination is preserved;
8. rename `ENOSPC` preserves the old destination and removes the temporary
   file;
9. failure to open the parent directory is reported after rename. The
   replacement may already be visible, but directory-entry durability is not
   established;
10. directory-`fsync` failure has the same visible-but-not-proven-durable
    boundary after rename;
11. the package-only deferred-directory-sync variant still performs the full file
    write/fsync/close/rename sequence but intentionally emits no parent-directory
    sync switch point, so only a surrounding same-directory transaction may use
    it and must establish that directory durability before returning success.

Cases 9–10 are intentionally not normalized into “old value
preserved”. `DurableFileWriter` exposes a package-only rename observer that is
false when rename itself fails and true before either post-rename directory
failure can surface. FileBlobStore uses that phase fact—not the errno—to mark a
writer `reopen-required` whenever logical authority may already be visible but
the actor has not adopted the matching manifest/generation/sequence. The stale
writer then rejects stateful access until it is released and a new instance
replays disk authority. CT-075–077 exercise fast xattr, fast sidecar fallback,
explicit sidecar, after-publication, full-checkpoint, tombstone and same-key
replacement variants. These remain process-visible recovery claims, not
power-loss proofs.

The seam does not replace ownership/mode validation, metadata writes or
security checks. Injected `open(2)` errors prove local control-flow semantics,
not real ACL, different-owner or mounted-filesystem behavior.

## 2. Permission transition

The retained permission test uses a real `chmod(2)` transition after the new
manifest temporary file has been written and synchronized but before rename.
The parent directory becomes read/search-only, so Darwin `rename(2)` fails with
`EACCES` or `EPERM`. The test then restores 0700 permissions, releases the old
writer and reopens the store. Reopen must observe a miss and remove both the
unpublished blob and durable temporary manifest.

Akashic does not claim that cleanup can succeed while the process lacks the
required parent-directory write permission. The claim is convergence after the
administrator or operating environment restores the declared private mode.

## 3. Real mounted-filesystem exhaustion

The retained full-volume matrix creates three independent 64 MiB APFS sparse
disk images, mounts each as a normal user, and writes a calibration filler until
the kernel returns `ENOSPC`. It then exercises the release `AkashicCrashProbe`
through production `DurableFileWriter` and `FileBlobStore` paths:

1. durable replacement has less free space than its 8 MiB payload, reports
   underlying POSIX `ENOSPC`, preserves the old destination and leaves no
   durable temporary file;
2. blob staging reports POSIX `ENOSPC`; after deleting the external filler and
   reopening, the baseline remains a verified hit, the attempted target is a
   miss, one published blob remains and temporary-file count is zero;
3. a target blob is fully staged before an external filler consumes the
   remaining volume. Manifest publication reports POSIX `ENOSPC`; after process
   exit, filler removal and reopen, bootstrap removes the unpublished blob and
   any manifest temporary file while preserving the baseline.

The images use the real APFS implementation and real kernel allocation errors,
not a mocked write function. They remain sparse disk images on the local host,
so the report fixes `quotaExhaustionClaim=false`,
`physicalDeviceQualification=false` and `powerLossClaim=false`.


## 4. Real APFS quota exhaustion

The quota matrix creates three independent 1 GiB APFS sparse-image containers
and adds a 64 MiB quota volume to each with `diskutil apfs addVolume -quota`.
Every operation is performed as the ordinary user that owns the disk image. At
each failure boundary the verifier requires the APFS container itself to retain
at least eight payloads of free capacity, distinguishing quota exhaustion from
a full container.

The retained cases establish three separate failure boundaries:

1. durable replacement, blob staging and manifest publication each preserve
   direct POSIX `ENOSPC` (`errno=28`);
2. the old destination or baseline entry remains intact and temporary files are
   absent after recovery;
3. after removing the external quota filler and reopening in a new process, the
   baseline is a verified hit, the attempted target is a miss, exactly one
   published blob remains and temporary-file count is zero.

Quota matrix schema 2 requires all three cases to expose kernel `ENOSPC`; fault
aggregate V6 binds that contract. The report fixes `wholeContainerFullClaim=false`,
`physicalDeviceQualification=false` and `powerLossClaim=false`.

## 5. Process termination

Six process-level evidence families use the same release `AkashicCrashProbe` executable:

1. The explicit stage/publish matrix exercises eleven exact switch points and
   terminates with `_exit(91)` after blob/manifest write, file sync, rename,
   directory sync and logical publication boundaries.
2. A separate schema3 fast-commit matrix reuses the same eleven named switch points but
   runs the payload-xattr transaction: payload and create authority share one inode/fsync,
   and the UUID blob rename publishes both. The aggregate requires this matrix to
   identify `blob inode manifest xattr` as its authority carrier and to use the
   exact same crash-probe binary as the stage/publish matrix.
3. The package-internal schema4 directory-head matrix exercises four physical
   boundaries of the normal single-key candidate transaction: payload rename,
   record-xattr write, checksummed head replacement and the coalesced `blobs`
   directory sync. Reopen must produce miss / miss / hit / hit respectively. This
   matrix is intentionally separate from both schema3 matrices so their evidence
   cannot be reused after a carrier/commit-point change.
4. A separate schema4 **distinct-key checkpoint** matrix seeds 511 delta keys and
   crashes the 512th mutation at seven boundaries: snapshot data write, snapshot
   file sync, snapshot rename, snapshot parent-directory sync, first empty-head
   write, second empty-head write and head-directory sync. The first two recover
   the old state; snapshot rename and every later point recover the complete new
   512-entry state. This proves the full-snapshot commit point separately from the
   single-key head transaction.
5. The schema4 recovery-of-recovery case starts from a checkpoint snapshot that is
   already authoritative but has zero current-generation heads. Recovery is then
   killed after writing the first repair head and again after writing the second.
   Raw inspection must show the monotonic physical progression 0 -> 1 -> 2 heads,
   with no current-generation delta records, and a final normal reopen must recover
   every entry. A crash while repairing recovery metadata therefore cannot turn a
   committed snapshot into a partial logical state.
6. The random-kill campaign runs three deterministic rounds. Each round starts
   an 8 MiB stage/publish transaction after a ready handshake, then contains
   one strict pre-write miss anchor, one strict committed-hit anchor and 24
   fixed-seed delays in the 0–10 ms window.

The campaign therefore retains 78 process terminations, of which 72 are random
timing samples. Anchors must recover to their declared state, and the random
samples themselves must include at least one complete hit and one complete
miss.

After every termination, a new process reopens the store. Corruption, residual
`.durable-tmp-*`/`.tmp-*` files, mismatched physical-blob counts, or any state
other than a verified complete hit or complete miss fails the campaign.

## Evidence boundary

The local macOS manuals state that `write(2)` may return fewer bytes than
requested, `fsync(2)` may return `EINTR`, and `rename(2)` requires search and
parent-directory write permission. The `fsync(2)` manual also explicitly warns
that drive caches, write reordering, OS crash and physical power loss can still
leave some or no data durable; stricter Apple environments may require
`F_FULLFSYNC`.

Every generated report therefore fixes these fields:

```text
processCrashClaim = true only when all retained cases pass
powerLossClaim = false
physicalDeviceQualification = false
```

Still outside the proven domain:

- real filesystem-induced `fsync`, rename and close errors;
- real filesystem-induced `open`, ACL and different-owner transition failures;
- multi-hour/high-iteration random-kill campaigns;
- controller-cache loss, physical power removal and `F_FULLFSYNC` comparison;
- stable physical-device I/O, energy and thermal qualification.

Run the complete retained gate with:

```bash
scripts/verify-fault-injection.sh
```
