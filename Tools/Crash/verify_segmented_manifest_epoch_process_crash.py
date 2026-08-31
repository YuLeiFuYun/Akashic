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
    ("one-new-head", "new"),
    ("both-new-heads", "new"),
]
CRASH_EXIT = 91


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def invoke(binary: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), *args],
        capture_output=True,
        text=True,
        check=False,
    )


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
    for point, expected_topology in POINTS:
        with tempfile.TemporaryDirectory(prefix="akashic-epoch-crash-") as temporary:
            root = Path(temporary) / "store"
            seeded = invoke(
                binary,
                "segmented-manifest-epoch-crash-seed",
                "--root",
                str(root),
            )
            if seeded.returncode != 0:
                errors.append(
                    f"{point}: seed failed {seeded.returncode}; stderr={seeded.stderr[-1000:]}"
                )
                continue
            try:
                seed = json.loads(seeded.stdout)
            except json.JSONDecodeError as error:
                errors.append(f"{point}: invalid seed JSON: {error}")
                continue

            started = time.monotonic_ns()
            crashed = invoke(
                binary,
                "segmented-manifest-epoch-crash",
                "--root",
                str(root),
                "--point",
                point,
            )
            crash_elapsed = time.monotonic_ns() - started
            if crashed.returncode != CRASH_EXIT:
                errors.append(
                    f"{point}: expected exit {CRASH_EXIT}, got {crashed.returncode}; "
                    f"stderr={crashed.stderr[-1000:]}"
                )
                continue

            inspect_started = time.monotonic_ns()
            inspected = invoke(
                binary,
                "segmented-manifest-epoch-crash-inspect",
                "--root",
                str(root),
            )
            inspect_elapsed = time.monotonic_ns() - inspect_started
            if inspected.returncode != 0:
                errors.append(
                    f"{point}: inspect failed {inspected.returncode}; "
                    f"stderr={inspected.stderr[-1000:]}"
                )
                continue
            try:
                observation = json.loads(inspected.stdout)
            except json.JSONDecodeError as error:
                errors.append(f"{point}: invalid inspect JSON: {error}")
                continue

            if observation.get("stateCommitment") != seed.get("expectedStateCommitment"):
                errors.append(f"{point}: logical/physical state commitment changed")

            if expected_topology == "old":
                expected_generation = seed.get("oldGeneration")
                expected_runs: list[str] = []
                expected_seal = seed.get("oldRootSeal")
            else:
                expected_generation = seed.get("newGeneration")
                expected_runs = [seed.get("runSHA256")]
                expected_seal = seed.get("newRootSeal")

            checks = {
                "generation": observation.get("generation") == expected_generation,
                "runCount": observation.get("runCount") == len(expected_runs),
                "runs": observation.get("runSHA256") == expected_runs,
                "rootSeal": observation.get("rootSeal") == expected_seal,
                "currentHeadCount": observation.get("currentHeadCount") == 2,
            }
            for name, passed in checks.items():
                if not passed:
                    errors.append(f"{point}: {name} mismatch")

            cases.append(
                {
                    "switchPoint": point,
                    "expectedTopology": expected_topology,
                    "observedGeneration": observation.get("generation"),
                    "observedRunCount": observation.get("runCount"),
                    "currentHeadCountAfterRecovery": observation.get("currentHeadCount"),
                    "stateCommitment": observation.get("stateCommitment"),
                    "crashExitCode": crashed.returncode,
                    "crashElapsedNanoseconds": crash_elapsed,
                    "inspectElapsedNanoseconds": inspect_elapsed,
                }
            )

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-DIRECTORY-EPOCH-TO-SEGMENT-RUN-PROCESS-CRASH-V1",
        "binarySHA256": sha256(binary),
        "caseCount": len(cases),
        "epochRunRevalidatedInChildProcess": True,
        "parentRepairsMissingEmptyHeads": True,
        "processCrashClaim": len(cases) == len(POINTS) and not errors,
        "powerLossClaim": False,
        "physicalDeviceClaim": False,
        "formalPerformanceClaim": False,
        "productionFormatClaim": False,
        "status": "failed" if errors else "passed",
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic directory-epoch segmented handoff process crash matrix: "
        f"cases={len(cases)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
