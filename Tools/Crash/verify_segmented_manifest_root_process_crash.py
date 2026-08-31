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
    ("run-durable-root-old", "old"),
    ("root-pre-rename", "old"),
    ("root-post-rename", "new"),
    ("root-post-directory-sync", "new"),
]
CRASH_EXIT = 91


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_json(command: list[str]) -> tuple[subprocess.CompletedProcess[str], dict[str, object] | None]:
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        return completed, None
    try:
        return completed, json.loads(completed.stdout)
    except json.JSONDecodeError:
        return completed, None


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
    for point, expected_state in POINTS:
        with tempfile.TemporaryDirectory(prefix="akashic-segment-root-crash-") as temporary:
            root = Path(temporary) / "store"
            seeded, seed = run_json(
                [str(binary), "segmented-manifest-process-seed", "--root", str(root)]
            )
            if seed is None:
                errors.append(
                    f"{point}: seed failed {seeded.returncode}; "
                    f"stdout={seeded.stdout[-500:]} stderr={seeded.stderr[-500:]}"
                )
                continue

            pre_inspected, pre = run_json(
                [str(binary), "segmented-manifest-process-inspect", "--root", str(root)]
            )
            if pre is None:
                errors.append(
                    f"{point}: pre-crash inspect failed {pre_inspected.returncode}; "
                    f"stderr={pre_inspected.stderr[-500:]}"
                )
                continue
            if pre.get("stateSHA256") != seed.get("oldStateSHA256"):
                errors.append(f"{point}: seeded old state did not round-trip before crash")
                continue

            started = time.monotonic_ns()
            crashed = subprocess.run(
                [
                    str(binary),
                    "segmented-manifest-process-crash",
                    "--root",
                    str(root),
                    "--point",
                    point,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            crash_elapsed = time.monotonic_ns() - started
            if crashed.returncode != CRASH_EXIT:
                errors.append(
                    f"{point}: expected crash exit {CRASH_EXIT}, got {crashed.returncode}; "
                    f"stderr={crashed.stderr[-500:]}"
                )
                continue

            inspect_started = time.monotonic_ns()
            inspected, observation = run_json(
                [str(binary), "segmented-manifest-process-inspect", "--root", str(root)]
            )
            inspect_elapsed = time.monotonic_ns() - inspect_started
            if observation is None:
                errors.append(
                    f"{point}: post-crash inspect failed {inspected.returncode}; "
                    f"stdout={inspected.stdout[-500:]} stderr={inspected.stderr[-500:]}"
                )
                continue

            expected_digest = seed.get(f"{expected_state}StateSHA256")
            expected_generation = seed.get(
                "oldGeneration" if expected_state == "old" else "newGeneration"
            )
            expected_records = seed.get(
                "oldRecordCount" if expected_state == "old" else "newRecordCount"
            )
            if observation.get("stateSHA256") != expected_digest:
                errors.append(
                    f"{point}: expected {expected_state} state digest, "
                    f"got {observation.get('stateSHA256')}"
                )
            if observation.get("generation") != expected_generation:
                errors.append(
                    f"{point}: expected generation={expected_generation}, "
                    f"got {observation.get('generation')}"
                )
            if observation.get("recordCount") != expected_records:
                errors.append(
                    f"{point}: expected recordCount={expected_records}, "
                    f"got {observation.get('recordCount')}"
                )
            if observation.get("stateSHA256") not in {
                seed.get("oldStateSHA256"),
                seed.get("newStateSHA256"),
            }:
                errors.append(f"{point}: recovered a third/intermediate logical state")

            cases.append(
                {
                    "switchPoint": point,
                    "expectedState": expected_state,
                    "observedGeneration": observation.get("generation"),
                    "observedRecordCount": observation.get("recordCount"),
                    "observedStateSHA256": observation.get("stateSHA256"),
                    "oldStateSHA256": seed.get("oldStateSHA256"),
                    "newStateSHA256": seed.get("newStateSHA256"),
                    "crashExitCode": crashed.returncode,
                    "crashElapsedNanoseconds": crash_elapsed,
                    "reopenElapsedNanoseconds": inspect_elapsed,
                }
            )

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-SEGMENTED-MANIFEST-ROOT-PROCESS-CRASH-MATRIX-V1",
        "binarySHA256": sha256(binary),
        "caseCount": len(cases),
        "transaction": {
            "mode": "research-only segmented manifest root publication shadow",
            "physicalRunAuthority": False,
            "logicalCommitPoint": "durable root replacement",
            "directoryDurabilityBoundary": "root parent directory fsync",
        },
        "productionFormatClaim": False,
        "fileBlobStoreAuthorityClaim": False,
        "formalPerformanceClaim": False,
        "physicalDeviceClaim": False,
        "powerLossClaim": False,
        "processCrashClaim": len(cases) == len(POINTS) and not errors,
        "status": "failed" if errors else "passed",
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic segmented-manifest root process crash matrix: "
        f"cases={len(cases)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
