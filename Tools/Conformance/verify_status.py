#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STATUS = ROOT / "docs/CONFORMANCE_STATUS.json"
ALLOWED = {
    "implemented-local",
    "implemented-local-process-crash",
    "implemented-local-cross-process-lock",
    "implemented-local-scope-limited",
    "partial-static-and-local",
    "partial-local",
    "planned",
}


def main() -> int:
    document = json.loads(STATUS.read_text())
    errors: list[str] = []
    if document.get("schemaVersion") != 1:
        errors.append("unexpected schemaVersion")
    if document.get("statusID") != "AKASHIC-CONFORMANCE-STATUS-V1":
        errors.append("unexpected statusID")
    rules = document.get("rules", {})
    for key in (
        "componentEvidenceDoesNotReplaceFoveaHostEvidence",
        "processCrashDoesNotImplyPowerLoss",
        "partialIsNotComplete",
        "candidateDoesNotImplyDefault",
    ):
        if rules.get(key) is not True:
            errors.append(f"rule {key} must remain true")
    if rules.get("releaseQualified") is not False:
        errors.append("releaseQualified must remain false")

    obligations = document.get("obligations", [])
    expected_ids = [f"AKASHIC-CT-{index:03d}" for index in range(1, 45)]
    actual_ids: list[str] = []
    statuses: list[str] = []
    for item in obligations:
        identifier = item.get("id") if isinstance(item, dict) else None
        actual_ids.append(identifier)
        status = item.get("status") if isinstance(item, dict) else None
        statuses.append(status)
        if status not in ALLOWED:
            errors.append(f"{identifier}: invalid status {status}")
        if not isinstance(item.get("summary"), str) or len(item["summary"].strip()) < 24:
            errors.append(f"{identifier}: summary is missing")
        paths = item.get("evidencePaths")
        if not isinstance(paths, list):
            errors.append(f"{identifier}: evidencePaths must be a list")
            continue
        if status != "planned" and not paths:
            errors.append(f"{identifier}: non-planned status needs evidence paths")
        if status == "planned" and paths:
            errors.append(f"{identifier}: planned status must not imply evidence")
        for relative in paths:
            if not isinstance(relative, str) or not (ROOT / relative).is_file():
                errors.append(f"{identifier}: missing evidence path {relative}")

    if actual_ids != expected_ids:
        errors.append(
            f"obligation sequence drifted: expected={expected_ids} actual={actual_ids}"
        )

    tests = "\n".join(path.read_text() for path in (ROOT / "Tests").rglob("*.swift"))
    named_test_ids = expected_ids[:21] + expected_ids[30:]
    for identifier in named_test_ids:
        status = obligations[int(identifier[-3:]) - 1]["status"]
        if status.startswith("implemented") and identifier not in tests:
            if identifier not in {"AKASHIC-CT-013"}:
                errors.append(f"{identifier}: implemented status has no named test occurrence")

    crash_tool = (ROOT / "Tools/Crash/verify_process_crash_matrix.py").read_text()
    if len(re.findall(r'"after(?:Blob|Manifest)[A-Za-z]+"', crash_tool)) < 11:
        errors.append("process crash matrix does not retain eleven switch points")

    counts = Counter(statuses)
    report = {
        "schemaVersion": 1,
        "statusID": document.get("statusID"),
        "obligationCount": len(obligations),
        "statusCounts": dict(sorted(counts.items())),
        "status": "failed" if errors else "passed",
        "errors": errors,
    }
    output = ROOT / ".build/conformance-status-verification.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic conformance status: "
        f"obligations={len(obligations)} statuses={dict(counts)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
