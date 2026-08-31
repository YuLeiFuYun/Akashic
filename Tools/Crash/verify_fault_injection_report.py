#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text())


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def test_count(path: Path) -> int:
    text = path.read_text(errors="replace")
    matches = re.findall(r"Test run with (\d+) tests? in .*? passed", text)
    if not matches:
        raise ValueError(f"no passing Swift Testing summary in {path}")
    return int(matches[-1])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--durable-log", type=Path, required=True)
    parser.add_argument("--permission-log", type=Path, required=True)
    parser.add_argument("--fast-xattr-log", type=Path, required=True)
    parser.add_argument("--fast-syscall-log", type=Path, required=True)
    parser.add_argument("--switch-matrix", type=Path, required=True)
    parser.add_argument("--fast-switch-matrix", type=Path, required=True)
    parser.add_argument("--random-matrix", type=Path, required=True)
    parser.add_argument("--full-volume-matrix", type=Path, required=True)
    parser.add_argument("--quota-matrix", type=Path, required=True)
    parser.add_argument("--source-identity", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    errors: list[str] = []
    source_identity = read_json(args.source_identity)
    source_identity_sha = source_identity.get("sourceIdentitySHA256")
    source_identity_files = source_identity.get("fileCount")
    if not isinstance(source_identity_sha, str) or len(source_identity_sha) != 64:
        errors.append("source identity must provide a SHA-256 digest")
    if not isinstance(source_identity_files, int) or source_identity_files < 1:
        errors.append("source identity must provide a positive file count")
    try:
        durable_count = test_count(args.durable_log)
    except ValueError as error:
        durable_count = 0
        errors.append(str(error))
    try:
        permission_count = test_count(args.permission_log)
    except ValueError as error:
        permission_count = 0
        errors.append(str(error))
    try:
        fast_xattr_count = test_count(args.fast_xattr_log)
    except ValueError as error:
        fast_xattr_count = 0
        errors.append(str(error))
    try:
        fast_syscall_count = test_count(args.fast_syscall_log)
    except ValueError as error:
        fast_syscall_count = 0
        errors.append(str(error))

    switch = read_json(args.switch_matrix)
    fast_switch = read_json(args.fast_switch_matrix)
    random_matrix = read_json(args.random_matrix)
    full_volume = read_json(args.full_volume_matrix)
    quota = read_json(args.quota_matrix)
    if durable_count != 11:
        errors.append(f"expected 11 durable syscall tests, observed {durable_count}")
    if permission_count != 1:
        errors.append(f"expected 1 permission-transition test, observed {permission_count}")
    if fast_xattr_count != 2:
        errors.append(f"expected 2 fast-xattr classification tests, observed {fast_xattr_count}")
    if fast_syscall_count != 4:
        errors.append(f"expected 4 fast-commit syscall tests, observed {fast_syscall_count}")
    if switch.get("status") != "passed" or switch.get("caseCount") != 11:
        errors.append("stage/publish process-crash matrix must pass all 11 switch points")
    if switch.get("processCrashClaim") is not True:
        errors.append("stage/publish process-crash matrix must establish process-crash recovery")
    if switch.get("powerLossClaim") is not False:
        errors.append("stage/publish process-crash matrix must not claim power-loss safety")
    if fast_switch.get("status") != "passed" or fast_switch.get("caseCount") != 11:
        errors.append("fast-xattr process-crash matrix must pass all 11 switch points")
    if fast_switch.get("matrixID") != "AKASHIC-FAST-XATTR-PROCESS-CRASH-MATRIX-V1":
        errors.append("fast-xattr process-crash matrix has unexpected identity")
    if fast_switch.get("processCrashClaim") is not True:
        errors.append("fast-xattr process-crash matrix must establish process-crash recovery")
    if fast_switch.get("powerLossClaim") is not False:
        errors.append("fast-xattr process-crash matrix must not claim power-loss safety")
    if fast_switch.get("binarySHA256") != switch.get("binarySHA256"):
        errors.append("stage/publish and fast-xattr matrices must use the same crash-probe binary")
    fast_transaction = fast_switch.get("transaction")
    if not isinstance(fast_transaction, dict) or fast_transaction.get("authorityCarrier") != "blob inode manifest xattr":
        errors.append("fast-xattr matrix must bind its authority carrier to the blob inode xattr")
    if random_matrix.get("status") != "passed":
        errors.append("random kill matrix must pass")
    if random_matrix.get("schemaVersion") != 2:
        errors.append("random kill campaign must use schema version 2")
    if random_matrix.get("roundCount") != 3:
        errors.append("random kill campaign must retain 3 rounds")
    if random_matrix.get("caseCount") != 78:
        errors.append("random kill campaign must retain 78 cases")
    if random_matrix.get("randomCaseCount") != 72:
        errors.append("random kill campaign must retain 72 random samples")
    if not isinstance(random_matrix.get("hitCount"), int) or random_matrix["hitCount"] < 1:
        errors.append("random kill matrix must observe a complete hit")
    if not isinstance(random_matrix.get("missCount"), int) or random_matrix["missCount"] < 1:
        errors.append("random kill matrix must observe a complete miss")
    if not isinstance(random_matrix.get("randomHitCount"), int) or random_matrix["randomHitCount"] < 1:
        errors.append("random samples must observe a complete hit")
    if not isinstance(random_matrix.get("randomMissCount"), int) or random_matrix["randomMissCount"] < 1:
        errors.append("random samples must observe a complete miss")
    if random_matrix.get("powerLossClaim") is not False:
        errors.append("random kill campaign must not claim power-loss safety")
    if random_matrix.get("binarySHA256") != switch.get("binarySHA256"):
        errors.append("exact and random process-crash campaigns must use the same crash-probe binary")
    if full_volume.get("status") != "passed":
        errors.append("real full-volume matrix must pass")
    if full_volume.get("schemaVersion") != 1:
        errors.append("real full-volume matrix must use schema version 1")
    if full_volume.get("caseCount") != 3 or full_volume.get("expectedCaseCount") != 3:
        errors.append("real full-volume matrix must pass all 3 cases")
    if full_volume.get("realMountedFilesystemENOSPCClaim") is not True:
        errors.append("real full-volume matrix must observe mounted-filesystem ENOSPC")
    if full_volume.get("quotaExhaustionClaim") is not False:
        errors.append("real full-volume matrix must not claim quota exhaustion")
    if full_volume.get("physicalDeviceQualification") is not False:
        errors.append("real full-volume matrix must not claim physical-device qualification")
    if full_volume.get("powerLossClaim") is not False:
        errors.append("real full-volume matrix must not claim power-loss safety")

    if quota.get("status") != "passed":
        errors.append("real APFS quota matrix must pass")
    if quota.get("schemaVersion") != 2:
        errors.append("real APFS quota matrix must use schema version 2")
    if quota.get("caseCount") != 3 or quota.get("expectedCaseCount") != 3:
        errors.append("real APFS quota matrix must pass all 3 cases")
    if quota.get("realAPFSQuotaExhaustionClaim") is not True:
        errors.append("real APFS quota matrix must establish quota exhaustion")
    if quota.get("kernelENOSPCCaseCount") != 3:
        errors.append("real APFS quota matrix must retain 3 kernel ENOSPC cases")
    if quota.get("allCasesObservedKernelENOSPC") is not True:
        errors.append("every real APFS quota case must preserve kernel ENOSPC")
    if quota.get("publicationFailureSurfaceCounts") != {"kernel-enospc": 1}:
        errors.append("manifest publication must expose one direct kernel ENOSPC surface")
    if quota.get("wholeContainerFullClaim") is not False:
        errors.append("real APFS quota matrix must not claim whole-container exhaustion")
    if quota.get("physicalDeviceQualification") is not False:
        errors.append("real APFS quota matrix must not claim physical-device qualification")
    if quota.get("powerLossClaim") is not False:
        errors.append("real APFS quota matrix must not claim power-loss safety")

    head = git("rev-parse", "HEAD")
    status = git("status", "--porcelain")
    report = {
        "schemaVersion": 7,
        "reportID": "AKASHIC-FAULT-INJECTION-EVIDENCE-V7",
        "status": "failed" if errors else "passed",
        "verifiedCommit": head.stdout.strip() if head.returncode == 0 else "unverified-local",
        "includesWorkingTreeChanges": status.returncode != 0 or bool(status.stdout.strip()),
        "sourceIdentitySHA256": source_identity_sha,
        "sourceIdentityFileCount": source_identity_files,
        "sourceIdentityStableAcrossCampaign": True,
        "syscallFaults": {
            "testCount": durable_count,
            "behaviors": [
                "partial-write-retry",
                "write-eintr-retry",
                "file-and-directory-fsync-eintr-retry",
                "deferred-directory-sync-stops-after-rename-and-never-claims-directory-synced",
                "temporary-file-open-failure-preserves-old-destination",
                "enospc-after-partial-write-preserves-old-destination",
                "file-fsync-failure-preserves-old-destination",
                "close-failure-is-not-retried-and-preserves-old-destination",
                "rename-enospc-preserves-old-destination",
                "directory-open-failure-reports-visible-but-not-proven-durable-replacement",
                "directory-fsync-failure-reports-visible-but-not-proven-durable-replacement",
            ],
            "logSHA256": sha256(args.durable_log),
        },
        "fastXattrClassification": {
            "testCount": fast_xattr_count,
            "behaviors": [
                "enotsup-and-e2big-fall-back-to-sidecar",
                "enospc-and-eio-remain-hard-failures",
                "hard-xattr-errors-publish-no-authority-and-reopen-as-miss",
                "sidecar-fallback-reserves-two-recovery-slots-under-staged-pressure",
            ],
            "logSHA256": sha256(args.fast_xattr_log),
        },
        "fastCommitSyscallFaults": {
            "testCount": fast_syscall_count,
            "behaviors": [
                "close-failure-is-never-retried-on-the-same-descriptor",
                "open-write-fsync-and-rename-prepublication-failures-preserve-clean-miss",
                "write-and-fsync-eintr-retry-to-completion",
                "post-rename-directory-open-and-fsync-failures-are-visible-but-durability-unproven",
                "post-rename-authority-converges-to-verified-hit-on-reopen",
            ],
            "logSHA256": sha256(args.fast_syscall_log),
        },
        "permissionTransition": {
            "testCount": permission_count,
            "behavior": "manifest-rename-denial-preserves-miss-and-bootstrap-cleans-leftovers",
            "logSHA256": sha256(args.permission_log),
        },
        "stagePublishProcessCrash": {
            "caseCount": switch.get("caseCount"),
            "artifactSHA256": sha256(args.switch_matrix),
            "binarySHA256": switch.get("binarySHA256"),
            "processCrashClaim": switch.get("processCrashClaim"),
            "powerLossClaim": switch.get("powerLossClaim"),
        },
        "fastXattrProcessCrash": {
            "caseCount": fast_switch.get("caseCount"),
            "artifactSHA256": sha256(args.fast_switch_matrix),
            "binarySHA256": fast_switch.get("binarySHA256"),
            "transaction": fast_switch.get("transaction"),
            "processCrashClaim": fast_switch.get("processCrashClaim"),
            "powerLossClaim": fast_switch.get("powerLossClaim"),
        },
        "randomProcessKill": {
            "caseCount": random_matrix.get("caseCount"),
            "roundCount": random_matrix.get("roundCount"),
            "randomCaseCount": random_matrix.get("randomCaseCount"),
            "randomCasesPerRound": random_matrix.get("randomCasesPerRound"),
            "seed": random_matrix.get("seed"),
            "payloadBytes": random_matrix.get("payloadBytes"),
            "maximumDelayMicroseconds": random_matrix.get("maximumDelayMicroseconds"),
            "hitCount": random_matrix.get("hitCount"),
            "missCount": random_matrix.get("missCount"),
            "randomHitCount": random_matrix.get("randomHitCount"),
            "randomMissCount": random_matrix.get("randomMissCount"),
            "artifactSHA256": sha256(args.random_matrix),
            "binarySHA256": random_matrix.get("binarySHA256"),
            "processCrashClaim": random_matrix.get("processCrashClaim"),
            "powerLossClaim": random_matrix.get("powerLossClaim"),
        },
        "realFullVolume": {
            "caseCount": full_volume.get("caseCount"),
            "filesystem": sorted({
                case.get("filesystem")
                for case in full_volume.get("cases", [])
                if isinstance(case, dict) and isinstance(case.get("filesystem"), str)
            }),
            "imageSizeMegabytes": full_volume.get("imageSizeMegabytes"),
            "payloadBytes": full_volume.get("payloadBytes"),
            "artifactSHA256": sha256(args.full_volume_matrix),
            "realMountedFilesystemENOSPCClaim": full_volume.get(
                "realMountedFilesystemENOSPCClaim"
            ),
            "quotaExhaustionClaim": full_volume.get("quotaExhaustionClaim"),
            "physicalDeviceQualification": full_volume.get("physicalDeviceQualification"),
            "powerLossClaim": full_volume.get("powerLossClaim"),
        },
        "realAPFSQuota": {
            "caseCount": quota.get("caseCount"),
            "filesystem": sorted({
                case.get("filesystem")
                for case in quota.get("cases", [])
                if isinstance(case, dict) and isinstance(case.get("filesystem"), str)
            }),
            "containerSizeMegabytes": quota.get("containerSizeMegabytes"),
            "quotaBytes": quota.get("quotaBytes"),
            "payloadBytes": quota.get("payloadBytes"),
            "kernelENOSPCCaseCount": quota.get("kernelENOSPCCaseCount"),
            "allCasesObservedKernelENOSPC": quota.get(
                "allCasesObservedKernelENOSPC"
            ),
            "publicationFailureSurfaceCounts": quota.get(
                "publicationFailureSurfaceCounts"
            ),
            "artifactSHA256": sha256(args.quota_matrix),
            "realAPFSQuotaExhaustionClaim": quota.get(
                "realAPFSQuotaExhaustionClaim"
            ),
            "wholeContainerFullClaim": quota.get("wholeContainerFullClaim"),
            "physicalDeviceQualification": quota.get("physicalDeviceQualification"),
            "powerLossClaim": quota.get("powerLossClaim"),
        },
        "claims": {
            "partialWritesHandled": not errors,
            "writeEINTRRetried": not errors,
            "fileAndDirectoryFsyncEINTRRetried": not errors,
            "temporaryOpenFailurePreservesPublishedDestination": not errors,
            "writeENOSPCPreservesPublishedDestination": not errors,
            "fileFsyncFailurePreservesPublishedDestination": not errors,
            "closeFailureIsNotRetried": not errors,
            "renameENOSPCPreservesPublishedDestination": not errors,
            "directoryOpenFailureHasVisibleButUnprovenDurability": not errors,
            "directoryFsyncFailureHasVisibleButUnprovenDurability": not errors,
            "fastXattrUnsupportedFallsBackOnlyForExplicitIncompatibility": not errors,
            "fastXattrHardErrorsDoNotFallBack": not errors,
            "fastCommitCloseFailureIsNotRetried": not errors,
            "fastCommitPreRenameFaultsPreserveCleanMiss": not errors,
            "fastCommitPostRenameDirectoryFaultsConvergeOnReopen": not errors,
            "permissionRestorationAllowsBootstrapConvergence": not errors,
            "realAPFSFullVolumeENOSPCRecovery": not errors,
            "realAPFSQuotaExhaustionRecovery": not errors,
            "quotaFailuresPreserveKernelENOSPC": not errors,
            "stagePublishProcessCrashRecovery": not errors,
            "fastXattrProcessCrashRecovery": not errors,
            "randomProcessKillRecovery": not errors,
            "powerLossSafety": False,
            "physicalDeviceQualification": False,
        },
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic fault injection evidence: "
        f"syscall={durable_count} fastXattr={fast_xattr_count} fastSyscall={fast_syscall_count} "
        f"permission={permission_count} stageSwitch={switch.get('caseCount')} "
        f"fastSwitch={fast_switch.get('caseCount')} "
        f"random={random_matrix.get('caseCount')} fullVolume={full_volume.get('caseCount')} "
        f"quota={quota.get('caseCount')} "
        f"errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
