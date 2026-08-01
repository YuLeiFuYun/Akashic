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
    parser.add_argument("--switch-matrix", type=Path, required=True)
    parser.add_argument("--random-matrix", type=Path, required=True)
    parser.add_argument("--full-volume-matrix", type=Path, required=True)
    parser.add_argument("--quota-matrix", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    errors: list[str] = []
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

    switch = read_json(args.switch_matrix)
    random_matrix = read_json(args.random_matrix)
    full_volume = read_json(args.full_volume_matrix)
    quota = read_json(args.quota_matrix)
    if durable_count != 8:
        errors.append(f"expected 8 durable syscall tests, observed {durable_count}")
    if permission_count != 1:
        errors.append(f"expected 1 permission-transition test, observed {permission_count}")
    if switch.get("status") != "passed" or switch.get("caseCount") != 11:
        errors.append("exact process-crash matrix must pass all 11 switch points")
    if switch.get("powerLossClaim") is not False:
        errors.append("exact process-crash matrix must not claim power-loss safety")
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
    if quota.get("schemaVersion") != 1:
        errors.append("real APFS quota matrix must use schema version 1")
    if quota.get("caseCount") != 3 or quota.get("expectedCaseCount") != 3:
        errors.append("real APFS quota matrix must pass all 3 cases")
    if quota.get("realAPFSQuotaExhaustionClaim") is not True:
        errors.append("real APFS quota matrix must establish quota exhaustion")
    if quota.get("kernelENOSPCCaseCount") != 2:
        errors.append("real APFS quota matrix must retain 2 kernel ENOSPC cases")
    if quota.get("foundationMetadataPrewriteFailureCaseCount") != 1:
        errors.append(
            "real APFS quota matrix must retain 1 Foundation metadata prewrite failure"
        )
    if quota.get("wholeContainerFullClaim") is not False:
        errors.append("real APFS quota matrix must not claim whole-container exhaustion")
    if quota.get("physicalDeviceQualification") is not False:
        errors.append("real APFS quota matrix must not claim physical-device qualification")
    if quota.get("powerLossClaim") is not False:
        errors.append("real APFS quota matrix must not claim power-loss safety")

    head = git("rev-parse", "HEAD")
    status = git("status", "--porcelain")
    report = {
        "schemaVersion": 4,
        "reportID": "AKASHIC-FAULT-INJECTION-EVIDENCE-V4",
        "status": "failed" if errors else "passed",
        "verifiedCommit": head.stdout.strip() if head.returncode == 0 else "unverified-local",
        "includesWorkingTreeChanges": status.returncode != 0 or bool(status.stdout.strip()),
        "syscallFaults": {
            "testCount": durable_count,
            "behaviors": [
                "partial-write-retry",
                "write-eintr-retry",
                "file-and-directory-fsync-eintr-retry",
                "enospc-after-partial-write-preserves-old-destination",
                "file-fsync-failure-preserves-old-destination",
                "close-failure-is-not-retried-and-preserves-old-destination",
                "rename-enospc-preserves-old-destination",
                "directory-fsync-failure-reports-visible-but-not-proven-durable-replacement",
            ],
            "logSHA256": sha256(args.durable_log),
        },
        "permissionTransition": {
            "testCount": permission_count,
            "behavior": "manifest-rename-denial-preserves-miss-and-bootstrap-cleans-leftovers",
            "logSHA256": sha256(args.permission_log),
        },
        "exactProcessCrash": {
            "caseCount": switch.get("caseCount"),
            "artifactSHA256": sha256(args.switch_matrix),
            "processCrashClaim": switch.get("processCrashClaim"),
            "powerLossClaim": switch.get("powerLossClaim"),
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
            "foundationMetadataPrewriteFailureCaseCount": quota.get(
                "foundationMetadataPrewriteFailureCaseCount"
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
            "writeENOSPCPreservesPublishedDestination": not errors,
            "fileFsyncFailurePreservesPublishedDestination": not errors,
            "closeFailureIsNotRetried": not errors,
            "renameENOSPCPreservesPublishedDestination": not errors,
            "directoryFsyncFailureHasVisibleButUnprovenDurability": not errors,
            "permissionRestorationAllowsBootstrapConvergence": not errors,
            "realAPFSFullVolumeENOSPCRecovery": not errors,
            "realAPFSQuotaExhaustionRecovery": not errors,
            "processCrashRecovery": not errors,
            "powerLossSafety": False,
            "physicalDeviceQualification": False,
        },
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic fault injection evidence: "
        f"syscall={durable_count} permission={permission_count} "
        f"switch={switch.get('caseCount')} random={random_matrix.get('caseCount')} "
        f"fullVolume={full_volume.get('caseCount')} quota={quota.get('caseCount')} "
        f"errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
