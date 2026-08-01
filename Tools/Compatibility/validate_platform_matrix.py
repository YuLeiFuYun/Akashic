#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DERIVED = ROOT / ".build/platform-matrix"
OUTPUT = ROOT / ".build/platform-matrix-report.json"
CASES = {
    ("AkashicDisk", "macos"): ("Release", {"arm64", "x86_64"}, "-apple-macos12.0"),
    ("AkashicDisk", "ios-simulator"): (
        "Release-iphonesimulator",
        {"arm64", "x86_64"},
        "-apple-ios15.0-simulator",
    ),
    ("AkashicDisk", "ios-device"): ("Release-iphoneos", {"arm64"}, "-apple-ios15.0"),
    ("AkashicMemory", "macos"): ("Release", {"arm64", "x86_64"}, "-apple-macos12.0"),
    ("AkashicMemory", "ios-simulator"): (
        "Release-iphonesimulator",
        {"arm64", "x86_64"},
        "-apple-ios15.0-simulator",
    ),
    ("AkashicMemory", "ios-device"): ("Release-iphoneos", {"arm64"}, "-apple-ios15.0"),
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def architectures(path: Path) -> set[str]:
    result = subprocess.run(
        ["xcrun", "lipo", "-archs", str(path)],
        check=True,
        text=True,
        capture_output=True,
    )
    return set(result.stdout.split())


def main() -> int:
    errors: list[str] = []
    reports: list[dict[str, object]] = []
    for (product, label), (products_dir, expected_arches, target_fragment) in CASES.items():
        log = DERIVED / f"{product}-{label}.log"
        artifact = (
            DERIVED
            / f"{product}-{label}"
            / "Build"
            / "Products"
            / products_dir
            / f"{product}.o"
        )
        if not log.is_file():
            errors.append(f"missing log: {log}")
            continue
        text = log.read_text(errors="replace")
        if "** BUILD SUCCEEDED **" not in text:
            errors.append(f"build did not succeed: {product}/{label}")
        if target_fragment not in text:
            errors.append(f"deployment target missing: {product}/{label} {target_fragment}")
        if not artifact.is_file():
            errors.append(f"missing artifact: {artifact}")
            continue
        actual_arches = architectures(artifact)
        if actual_arches != expected_arches:
            errors.append(
                f"architecture mismatch {product}/{label}: "
                f"expected={sorted(expected_arches)} actual={sorted(actual_arches)}"
            )
        reports.append(
            {
                "product": product,
                "platform": label,
                "architectures": sorted(actual_arches),
                "artifactSHA256": sha256(artifact),
                "logSHA256": sha256(log),
                "deploymentTargetFragment": target_fragment,
            }
        )

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-APPLE-PLATFORM-MATRIX-V1",
        "caseCount": len(reports),
        "status": "failed" if errors else "passed",
        "cases": reports,
        "errors": errors,
    }
    OUTPUT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"Akashic platform matrix: cases={len(reports)} errors={len(errors)}")
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
