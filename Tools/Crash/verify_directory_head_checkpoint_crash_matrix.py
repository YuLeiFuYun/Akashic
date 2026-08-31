#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

POINTS = [
    ("afterSnapshotDataWritten", False),
    ("afterSnapshotFileSynced", False),
    ("afterSnapshotRenamed", True),
    ("afterSnapshotDirectorySynced", True),
    ("afterFirstHeadSet", True),
    ("afterSecondHeadSet", True),
    ("afterHeadDirectorySynced", True),
]
CRASH_EXIT = 91
EXPECTED_ENTRY_COUNT = 512


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tail(text: str, count: int = 800) -> str:
    return text[-count:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)

    errors: list[str] = []
    cases: list[dict[str, object]] = []
    for point, expects_new_authority in POINTS:
        with tempfile.TemporaryDirectory(prefix="akashic-directory-head-checkpoint-crash-") as temporary:
            root = Path(temporary) / "store"
            seed_started = time.monotonic_ns()
            seeded = subprocess.run(
                [str(binary), "directory-head-checkpoint-seed", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            seed_elapsed = time.monotonic_ns() - seed_started
            if seeded.returncode != 0:
                errors.append(
                    f"{point}: checkpoint seed failed {seeded.returncode}; stderr={tail(seeded.stderr)}"
                )
                continue

            crash_started = time.monotonic_ns()
            crashed = subprocess.run(
                [str(binary), "directory-head-checkpoint-crash", str(root), point],
                capture_output=True,
                text=True,
                check=False,
            )
            crash_elapsed = time.monotonic_ns() - crash_started
            if crashed.returncode != CRASH_EXIT:
                errors.append(
                    f"{point}: expected crash exit {CRASH_EXIT}, got {crashed.returncode}; "
                    f"stderr={tail(crashed.stderr)}"
                )
                continue

            inspect_started = time.monotonic_ns()
            inspected = subprocess.run(
                [str(binary), "directory-head-checkpoint-inspect", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            inspect_elapsed = time.monotonic_ns() - inspect_started
            if inspected.returncode != 0:
                errors.append(
                    f"{point}: recovery inspect failed {inspected.returncode}; "
                    f"stderr={tail(inspected.stderr)}"
                )
                continue
            try:
                observation = json.loads(inspected.stdout)
            except json.JSONDecodeError as error:
                errors.append(f"{point}: invalid inspect JSON: {error}")
                continue

            if expects_new_authority:
                expected_missing_indices: list[int] = []
                expected_sentinel_failures: list[int] = []
                expected_blob_count = EXPECTED_ENTRY_COUNT
            else:
                expected_missing_indices = [EXPECTED_ENTRY_COUNT - 1]
                expected_sentinel_failures = [EXPECTED_ENTRY_COUNT - 1]
                expected_blob_count = EXPECTED_ENTRY_COUNT - 1
            checks = {
                "expectedEntryCount": observation.get("expectedEntryCount") == EXPECTED_ENTRY_COUNT,
                "missingIndices": observation.get("missingIndices") == expected_missing_indices,
                "sentinelFailures": observation.get("sentinelFailures") == expected_sentinel_failures,
                "blobCount": observation.get("blobCount") == expected_blob_count,
                "temporaryCount": observation.get("temporaryCount") == 0,
                "manifestExists": observation.get("manifestExists") is True,
            }
            failed_checks = [name for name, passed in checks.items() if not passed]
            if failed_checks:
                errors.append(
                    f"{point}: failed checks {failed_checks}; observation={observation}"
                )

            cases.append(
                {
                    "switchPoint": point,
                    "expectsNewAuthority": expects_new_authority,
                    "crashExitCode": crashed.returncode,
                    "seedElapsedNanoseconds": seed_elapsed,
                    "crashElapsedNanoseconds": crash_elapsed,
                    "reopenElapsedNanoseconds": inspect_elapsed,
                    "checks": checks,
                    "observation": observation,
                }
            )

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-DIRECTORY-HEAD-CHECKPOINT-PROCESS-CRASH-MATRIX-V1",
        "binarySHA256": sha256(binary),
        "caseCount": len(cases),
        "expectedCaseCount": len(POINTS),
        "checkpointSeedDistinctKeyCount": EXPECTED_ENTRY_COUNT - 1,
        "checkpointTriggerKeyIndex": EXPECTED_ENTRY_COUNT - 1,
        "transaction": {
            "mode": "schema4 directory-head checkpoint at distinct-key limit",
            "snapshotThenHeadInitialization": True,
            "recoveryRule": "zero/one empty current-generation head may be repaired only when no current-generation delta record exists",
        },
        "claimBoundary": {
            "processCrash": True,
            "powerLoss": False,
            "performance": False,
            "physicalDevice": False,
        },
        "status": "passed" if len(cases) == len(POINTS) and not errors else "failed",
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic directory-head checkpoint process crash matrix: "
        f"cases={len(cases)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
