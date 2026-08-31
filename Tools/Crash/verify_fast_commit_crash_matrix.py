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

# This matrix is intentionally separate from the stage/publish crash matrix. The same switch-point
# enum is reused for comparability, but the xattr fast path coalesces data + manifest durability on
# one inode and publishes both through one rename.
POINTS = [
    "afterBlobDataWritten",
    "afterManifestDataWritten",
    "afterBlobFileSynced",
    "afterManifestFileSynced",
    "beforeManifestPublished",
    "afterBlobRenamed",
    "afterBlobFilePublished",
    "afterManifestRenamed",
    "afterBlobDirectorySynced",
    "afterManifestDirectorySynced",
    "afterManifestPublished",
]
HIT_POINTS = {
    "afterBlobRenamed",
    "afterBlobFilePublished",
    "afterManifestRenamed",
    "afterBlobDirectorySynced",
    "afterManifestDirectorySynced",
    "afterManifestPublished",
}
CRASH_EXIT = 91


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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
    for point in POINTS:
        with tempfile.TemporaryDirectory(prefix="akashic-fast-process-crash-") as temporary:
            root = Path(temporary) / "store"
            started = time.monotonic_ns()
            crashed = subprocess.run(
                [str(binary), "fast-crash", str(root), point],
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
            inspected = subprocess.run(
                [str(binary), "inspect", str(root)],
                capture_output=True,
                text=True,
                check=False,
            )
            inspect_elapsed = time.monotonic_ns() - inspect_started
            if inspected.returncode != 0:
                errors.append(
                    f"{point}: recovery inspect failed {inspected.returncode}; "
                    f"stderr={inspected.stderr[-500:]}"
                )
                continue
            try:
                observation = json.loads(inspected.stdout)
            except json.JSONDecodeError as error:
                errors.append(f"{point}: invalid inspect JSON: {error}")
                continue

            expected = "hit" if point in HIT_POINTS else "miss"
            if observation.get("disposition") != expected:
                errors.append(
                    f"{point}: expected {expected}, got {observation.get('disposition')}"
                )
            expected_blob_count = 1 if expected == "hit" else 0
            if observation.get("blobCount") != expected_blob_count:
                errors.append(
                    f"{point}: expected blobCount={expected_blob_count}, "
                    f"got {observation.get('blobCount')}"
                )
            if observation.get("temporaryCount") != 0:
                errors.append(
                    f"{point}: temporary files remained after recovery: "
                    f"{observation.get('temporaryCount')}"
                )

            cases.append(
                {
                    "switchPoint": point,
                    "expectedDisposition": expected,
                    "observedDisposition": observation.get("disposition"),
                    "blobCount": observation.get("blobCount"),
                    "temporaryCount": observation.get("temporaryCount"),
                    "manifestExists": observation.get("manifestExists"),
                    "crashExitCode": crashed.returncode,
                    "crashElapsedNanoseconds": crash_elapsed,
                    "reopenElapsedNanoseconds": inspect_elapsed,
                }
            )

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-FAST-XATTR-PROCESS-CRASH-MATRIX-V1",
        "binarySHA256": sha256(binary),
        "caseCount": len(cases),
        "transaction": {
            "mode": "FileBlobStore.commit fast path",
            "authorityCarrier": "blob inode manifest xattr",
            "publicationSwitch": "UUID blob rename",
            "fileAndAttributeFsyncCoalesced": True,
        },
        "powerLossClaim": False,
        "processCrashClaim": len(cases) == len(POINTS) and not errors,
        "status": "failed" if errors else "passed",
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Akashic fast xattr process crash matrix: cases={len(cases)} errors={len(errors)}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
