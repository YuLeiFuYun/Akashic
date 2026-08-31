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
    ("candidate-verified-root-old", "old"),
    ("root-pre-rename", "old"),
    ("root-post-rename", "new"),
    ("root-post-directory-sync", "new"),
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
        with tempfile.TemporaryDirectory(prefix="akashic-segment-rebase-crash-") as temporary:
            root = Path(temporary) / "store"
            seeded = invoke(
                binary,
                "segmented-manifest-rebase-crash-seed",
                "--root",
                str(root),
            )
            if seeded.returncode != 0:
                errors.append(
                    f"{point}: seed failed {seeded.returncode}; stderr={seeded.stderr[-800:]}"
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
                "segmented-manifest-rebase-crash",
                "--root",
                str(root),
                "--point",
                point,
            )
            crash_elapsed = time.monotonic_ns() - started
            if crashed.returncode != CRASH_EXIT:
                errors.append(
                    f"{point}: expected exit {CRASH_EXIT}, got {crashed.returncode}; "
                    f"stderr={crashed.stderr[-800:]}"
                )
                continue

            inspect_started = time.monotonic_ns()
            inspected = invoke(
                binary,
                "segmented-manifest-rebase-crash-inspect",
                "--root",
                str(root),
            )
            inspect_elapsed = time.monotonic_ns() - inspect_started
            if inspected.returncode != 0:
                errors.append(
                    f"{point}: inspect failed {inspected.returncode}; stderr={inspected.stderr[-800:]}"
                )
                continue
            try:
                observation = json.loads(inspected.stdout)
            except json.JSONDecodeError as error:
                errors.append(f"{point}: invalid inspect JSON: {error}")
                continue

            if observation.get("stateCommitment") != seed.get("expectedStateCommitment"):
                errors.append(f"{point}: semantic state changed across rebase publication")

            if expected_topology == "old":
                expected_generation = seed.get("oldGeneration")
                expected_base = seed.get("originalBaseSHA256")
                expected_runs = [seed.get("frozenRunSHA256"), seed.get("suffixRunSHA256")]
                expected_seal = seed.get("oldRootSeal")
            else:
                expected_generation = seed.get("newGeneration")
                expected_base = seed.get("candidateBaseSHA256")
                expected_runs = [seed.get("suffixRunSHA256")]
                expected_seal = seed.get("newRootSeal")

            checks = {
                "generation": observation.get("generation") == expected_generation,
                "base": observation.get("baseSHA256") == expected_base,
                "runs": observation.get("runSHA256") == expected_runs,
                "runCount": observation.get("runCount") == len(expected_runs),
                "rootSeal": observation.get("rootSeal") == expected_seal,
            }
            for name, passed in checks.items():
                if not passed:
                    errors.append(f"{point}: {name} topology mismatch")

            cases.append(
                {
                    "switchPoint": point,
                    "expectedTopology": expected_topology,
                    "observedGeneration": observation.get("generation"),
                    "observedRunCount": observation.get("runCount"),
                    "stateCommitment": observation.get("stateCommitment"),
                    "crashExitCode": crashed.returncode,
                    "crashElapsedNanoseconds": crash_elapsed,
                    "inspectElapsedNanoseconds": inspect_elapsed,
                }
            )

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-SEGMENTED-REBASE-NONEMPTY-SUFFIX-PROCESS-CRASH-V1",
        "binarySHA256": sha256(binary),
        "caseCount": len(cases),
        "nonEmptySuffix": True,
        "candidateRevalidatedInChildProcess": True,
        "processCrashClaim": len(cases) == len(POINTS) and not errors,
        "powerLossClaim": False,
        "formalPerformanceClaim": False,
        "productionFormatClaim": False,
        "status": "failed" if errors else "passed",
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic segmented rebase non-empty-suffix process crash matrix: "
        f"cases={len(cases)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
