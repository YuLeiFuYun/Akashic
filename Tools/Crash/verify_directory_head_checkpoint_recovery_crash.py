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

CRASH_EXIT = 91


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), *args], capture_output=True, text=True, check=False
    )


def parse_json(result: subprocess.CompletedProcess[str], label: str, errors: list[str]) -> dict | None:
    if result.returncode != 0:
        errors.append(
            f"{label}: exit={result.returncode}; stderr={result.stderr[-800:]}"
        )
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        errors.append(f"{label}: invalid JSON: {error}; stdout={result.stdout[-800:]}")
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)

    errors: list[str] = []
    observations: list[dict[str, object]] = []
    timings: dict[str, int] = {}

    with tempfile.TemporaryDirectory(prefix="akashic-directory-head-recovery-crash-") as temporary:
        root = Path(temporary) / "store"

        started = time.monotonic_ns()
        seeded = run(binary, "directory-head-checkpoint-seed", str(root))
        timings["seedNanoseconds"] = time.monotonic_ns() - started
        if seeded.returncode != 0:
            errors.append(
                f"seed: exit={seeded.returncode}; stderr={seeded.stderr[-800:]}"
            )
        else:
            started = time.monotonic_ns()
            primary = run(
                binary,
                "directory-head-checkpoint-crash",
                str(root),
                "afterSnapshotDirectorySynced",
            )
            timings["primaryCrashNanoseconds"] = time.monotonic_ns() - started
            if primary.returncode != CRASH_EXIT:
                errors.append(
                    f"primary crash: expected={CRASH_EXIT} got={primary.returncode}; "
                    f"stderr={primary.stderr[-800:]}"
                )

        if not errors:
            raw0 = parse_json(
                run(binary, "directory-head-checkpoint-raw-inspect", str(root)),
                "raw after primary crash",
                errors,
            )
            if raw0 is not None:
                observations.append({"stage": "afterPrimaryCrash", **raw0})
                if raw0.get("currentHeadCount") != 0:
                    errors.append(f"after primary crash expected 0 heads, got {raw0}")
                if raw0.get("currentRecordCount") != 0:
                    errors.append(f"after primary crash expected 0 current records, got {raw0}")

        for repair_index, expected_head_count in [(1, 1), (2, 2)]:
            if errors:
                break
            started = time.monotonic_ns()
            crashed = run(
                binary,
                "directory-head-checkpoint-recovery-crash",
                str(root),
            )
            timings[f"recoveryCrash{repair_index}Nanoseconds"] = time.monotonic_ns() - started
            if crashed.returncode != CRASH_EXIT:
                errors.append(
                    f"recovery crash {repair_index}: expected={CRASH_EXIT} got={crashed.returncode}; "
                    f"stderr={crashed.stderr[-800:]}"
                )
                break
            raw = parse_json(
                run(binary, "directory-head-checkpoint-raw-inspect", str(root)),
                f"raw after recovery crash {repair_index}",
                errors,
            )
            if raw is None:
                break
            observations.append({"stage": f"afterRecoveryCrash{repair_index}", **raw})
            if raw.get("currentHeadCount") != expected_head_count:
                errors.append(
                    f"after recovery crash {repair_index} expected {expected_head_count} heads, got {raw}"
                )
            if raw.get("currentRecordCount") != 0:
                errors.append(
                    f"after recovery crash {repair_index} expected 0 current records, got {raw}"
                )

        final_observation = None
        if not errors:
            started = time.monotonic_ns()
            inspected = run(binary, "directory-head-checkpoint-inspect", str(root))
            timings["finalReopenNanoseconds"] = time.monotonic_ns() - started
            final_observation = parse_json(inspected, "final reopen", errors)
            if final_observation is not None:
                checks = {
                    "missingEntryCount": final_observation.get("missingEntryCount") == 0,
                    "sentinelFailureCount": final_observation.get("sentinelFailureCount") == 0,
                    "temporaryCount": final_observation.get("temporaryCount") == 0,
                    "blobCountMatchesExpected": final_observation.get("blobCount")
                    == final_observation.get("expectedEntryCount"),
                    "manifestExists": final_observation.get("manifestExists") is True,
                }
                failed = [name for name, passed in checks.items() if not passed]
                if failed:
                    errors.append(
                        f"final reopen failed checks {failed}; observation={final_observation}"
                    )

        result = {
            "schemaVersion": 1,
            "matrixID": "AKASHIC-DIRECTORY-HEAD-RECOVERY-OF-RECOVERY-V1",
            "binarySHA256": sha256(binary),
            "status": "passed" if not errors else "failed",
            "claimBoundary": {
                "processCrash": True,
                "powerLoss": False,
                "performance": False,
                "physicalDevice": False,
            },
            "scenario": [
                "seed checkpointLimit-1 distinct schema4 keys",
                "crash after checkpoint snapshot directory sync before empty-head initialization",
                "crash after first recovery head set",
                "crash after second recovery head set",
                "reopen normally and verify complete authority/data convergence",
            ],
            "requiredPhysicalProgression": [0, 1, 2],
            "rawObservations": observations,
            "finalObservation": final_observation,
            "timings": timings,
            "errors": errors,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")

    print(
        "Akashic directory-head recovery-of-recovery: "
        f"status={result['status']} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
