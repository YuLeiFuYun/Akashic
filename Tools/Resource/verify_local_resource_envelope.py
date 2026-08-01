#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import os
import platform
import subprocess
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / ".build" / "release" / "AkashicResourceProbe"
OUTPUT = ROOT / ".build" / "local-resource-envelope.json"
IDENTITY_OUTPUT = ROOT / ".build" / "resource-source-identity.json"

CASES = (
    {"blobCount": 64, "blobBytes": 4 * 1024, "readPasses": 2},
    {"blobCount": 32, "blobBytes": 64 * 1024, "readPasses": 2},
    {"blobCount": 8, "blobBytes": 1024 * 1024, "readPasses": 1},
)

MAXIMUM_RSS_BYTES = 256 * 1024 * 1024
MAXIMUM_OPEN_FILE_DESCRIPTORS = 64
MAXIMUM_STAGE_NANOSECONDS = 30 * 1_000_000_000
MAXIMUM_REOPEN_NANOSECONDS = 5 * 1_000_000_000


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_probe(case: dict[str, int], root: Path) -> dict[str, Any]:
    command = [
        str(BINARY),
        "--root",
        str(root),
        "--blob-count",
        str(case["blobCount"]),
        "--blob-bytes",
        str(case["blobBytes"]),
        "--read-passes",
        str(case["readPasses"]),
    ]
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"resource probe failed ({completed.returncode}): {completed.stderr.strip()}"
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid resource probe JSON: {completed.stdout!r}") from error


def validate(case: dict[str, int], report: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    label = report.get("workloadID", "unknown")
    payload = case["blobCount"] * case["blobBytes"]
    expected_read = payload * case["readPasses"]

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(f"{label}: {message}")

    require(report.get("schemaVersion") == 1, "unexpected schemaVersion")
    require(report.get("blobCount") == case["blobCount"], "blob count drifted")
    require(report.get("blobBytes") == case["blobBytes"], "blob size drifted")
    require(report.get("readPasses") == case["readPasses"], "read passes drifted")
    require(report.get("logicalPayloadBytes") == payload, "logical payload bytes drifted")
    require(report.get("logicalReadBytes") == expected_read, "logical read bytes drifted")

    footprint = report.get("footprint", {})
    require(footprint.get("blobBytes") == payload, "final blob footprint differs from payload")
    require(footprint.get("metadataBytes", -1) >= 0, "metadata footprint is invalid")
    require(footprint.get("fileCount", 0) >= case["blobCount"] + 1, "file count is incomplete")
    require(
        footprint.get("totalBytes")
        == footprint.get("blobBytes", 0) + footprint.get("metadataBytes", 0),
        "total footprint accounting is inconsistent",
    )

    metadata_rewrite = report.get("logicalMetadataRewriteBytes", -1)
    require(metadata_rewrite >= footprint.get("metadataBytes", 0), "metadata rewrite accounting is too small")
    amplification = report.get("metadataWriteAmplificationUpperBound")
    expected_amplification = (payload + metadata_rewrite) / payload
    require(
        isinstance(amplification, (int, float))
        and math.isfinite(amplification)
        and abs(amplification - expected_amplification) < 1e-9,
        "metadata write amplification is invalid",
    )

    usage = report.get("usage", {})
    maximum_rss = usage.get("maximumResidentBytes", -1)
    descriptors = usage.get("sampledOpenFileDescriptors", -1)
    require(0 < maximum_rss <= MAXIMUM_RSS_BYTES, f"maximum RSS outside local envelope: {maximum_rss}")
    require(
        0 < descriptors <= MAXIMUM_OPEN_FILE_DESCRIPTORS,
        f"sampled descriptor count outside local envelope: {descriptors}",
    )
    require(report.get("commitNanoseconds", 0) <= MAXIMUM_STAGE_NANOSECONDS, "commit stage exceeded local time bound")
    require(report.get("readNanoseconds", 0) <= MAXIMUM_STAGE_NANOSECONDS, "read stage exceeded local time bound")
    require(report.get("reopenNanoseconds", 0) <= MAXIMUM_REOPEN_NANOSECONDS, "reopen exceeded local time bound")

    claims = report.get("claims", {})
    for key in ("energy", "physicalDevice", "physicalIOBytes", "powerLoss"):
        require(claims.get(key) is False, f"unsupported claim became true: {key}")
    return errors


def capture_source_identity() -> dict[str, Any]:
    subprocess.run(
        [
            "python3",
            str(ROOT / "Tools" / "Identity" / "capture_source_identity.py"),
            "--output",
            str(IDENTITY_OUTPUT),
        ],
        cwd=ROOT,
        check=True,
    )
    return json.loads(IDENTITY_OUTPUT.read_text())


def main() -> int:
    if not BINARY.is_file():
        raise FileNotFoundError(f"missing resource probe binary: {BINARY}")

    reports: list[dict[str, Any]] = []
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="akashic-resource-envelope-") as temporary:
        temporary_root = Path(temporary)
        for index, case in enumerate(CASES):
            report = load_probe(case, temporary_root / f"case-{index}")
            reports.append(report)
            errors.extend(validate(case, report))

    identity = capture_source_identity()
    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-LOCAL-RESOURCE-ENVELOPE-V1",
        "status": "failed" if errors else "passed",
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
        "binarySHA256": sha256(BINARY),
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "developerDirectory": os.environ.get("DEVELOPER_DIR"),
        },
        "localBounds": {
            "maximumResidentBytes": MAXIMUM_RSS_BYTES,
            "maximumSampledOpenFileDescriptors": MAXIMUM_OPEN_FILE_DESCRIPTORS,
            "maximumStageNanoseconds": MAXIMUM_STAGE_NANOSECONDS,
            "maximumReopenNanoseconds": MAXIMUM_REOPEN_NANOSECONDS,
        },
        "claims": {
            "energy": False,
            "physicalDevice": False,
            "physicalIOBytes": False,
            "powerLoss": False,
        },
        "cases": reports,
        "errors": errors,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Akashic local resource envelope: cases={len(reports)} errors={len(errors)}")
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
