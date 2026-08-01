#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_PRODUCTION_LINES = 500
MAX_TEST_LINES = 600
EXPECTED_PRODUCTS = {"AkashicCore", "AkashicMemory", "AkashicDisk"}


def swift_line_counts(root: Path) -> list[tuple[str, int]]:
    return [
        (str(path.relative_to(ROOT)), len(path.read_text().splitlines()))
        for path in sorted(root.rglob("*.swift"))
    ]


def main() -> int:
    errors: list[str] = []
    production = swift_line_counts(ROOT / "Sources")
    tests = swift_line_counts(ROOT / "Tests")

    for path, count in production:
        if count > MAX_PRODUCTION_LINES:
            errors.append(
                f"production source exceeds {MAX_PRODUCTION_LINES} lines: {path}={count}"
            )
    for path, count in tests:
        if count > MAX_TEST_LINES:
            errors.append(f"test source exceeds {MAX_TEST_LINES} lines: {path}={count}")

    package = (ROOT / "Package.swift").read_text()
    products = {
        name
        for name in EXPECTED_PRODUCTS
        if f'.library(name: "{name}", targets: ["{name}"])' in package
    }
    if products != EXPECTED_PRODUCTS:
        errors.append(
            f"library product set drifted: expected={sorted(EXPECTED_PRODUCTS)} "
            f"actual={sorted(products)}"
        )

    empty_targets = []
    for target in EXPECTED_PRODUCTS:
        source_root = ROOT / "Sources" / target
        if not source_root.is_dir() or not any(source_root.rglob("*.swift")):
            empty_targets.append(target)
    if empty_targets:
        errors.append(f"empty production targets: {sorted(empty_targets)}")

    report = {
        "schemaVersion": 1,
        "qualityGateID": "AKASHIC-STRUCTURE-GATE-V1",
        "productionFileCount": len(production),
        "testFileCount": len(tests),
        "maximumProductionLines": max((count for _, count in production), default=0),
        "maximumTestLines": max((count for _, count in tests), default=0),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    output = ROOT / ".build/structure-verification.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic structure: "
        f"production={len(production)} tests={len(tests)} "
        f"maxProduction={report['maximumProductionLines']} "
        f"maxTest={report['maximumTestLines']} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
