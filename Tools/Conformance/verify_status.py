#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

from verify_fovea_host_receipt import DEFAULT_RECEIPT, validate_receipt

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
    "retired",
}
REQUIRED_RULES = (
    "componentEvidenceDoesNotReplaceFoveaHostEvidence",
    "processCrashDoesNotImplyPowerLoss",
    "partialIsNotComplete",
    "candidateDoesNotImplyDefault",
    "directoryHeadCandidateDoesNotImplyAutomaticMigration",
    "snapshotCorruptionSealDoesNotImplyAuthenticatedStorage",
)
IMPLEMENTED_WITHOUT_NAMED_TEST = {
    "AKASHIC-CT-013",
    "AKASHIC-CT-111",
    "AKASHIC-CT-124",
    "AKASHIC-CT-125",
}


def validate_document_header(document: dict[str, object], errors: list[str]) -> None:
    if document.get("schemaVersion") != 1:
        errors.append("unexpected schemaVersion")
    if document.get("statusID") != "AKASHIC-CONFORMANCE-STATUS-V1":
        errors.append("unexpected statusID")
    rules = document.get("rules", {})
    if not isinstance(rules, dict):
        errors.append("rules must be an object")
        return
    for key in REQUIRED_RULES:
        if rules.get(key) is not True:
            errors.append(f"rule {key} must remain true")
    if rules.get("releaseQualified") is not False:
        errors.append("releaseQualified must remain false")


def validate_host_receipt(errors: list[str]) -> None:
    for error in validate_receipt(DEFAULT_RECEIPT):
        errors.append(f"Fovea host receipt: {error}")


def validate_obligation_metadata(
    identifier: object,
    status: object,
    summary: object,
    errors: list[str],
) -> None:
    if status not in ALLOWED:
        errors.append(f"{identifier}: invalid status {status}")
    if not isinstance(summary, str) or len(summary.strip()) < 24:
        errors.append(f"{identifier}: summary is missing")
    if status == "retired" and isinstance(summary, str) and "retir" not in summary.lower():
        errors.append(f"{identifier}: retired status must explain retirement")


def validate_evidence_policy(
    identifier: object,
    status: object,
    paths: list[object],
    errors: list[str],
) -> None:
    no_current_evidence = status in {"planned", "retired"}
    if not no_current_evidence and not paths:
        errors.append(f"{identifier}: evidentiary status needs evidence paths")
    if no_current_evidence and paths:
        errors.append(f"{identifier}: {status} status must not imply current evidence")
    validate_evidence_paths(identifier, paths, errors)


def validate_obligation(item: object, errors: list[str]) -> tuple[object, object]:
    if not isinstance(item, dict):
        errors.append("conformance obligation must be an object")
        return None, None
    identifier = item.get("id")
    status = item.get("status")
    validate_obligation_metadata(identifier, status, item.get("summary"), errors)
    paths = item.get("evidencePaths")
    if not isinstance(paths, list):
        errors.append(f"{identifier}: evidencePaths must be a list")
        return identifier, status
    validate_evidence_policy(identifier, status, paths, errors)
    return identifier, status


def validate_evidence_paths(identifier: object, paths: list[object], errors: list[str]) -> None:
    for relative in paths:
        if not isinstance(relative, str) or not (ROOT / relative).is_file():
            errors.append(f"{identifier}: missing evidence path {relative}")


def collect_obligations(
    document: dict[str, object], errors: list[str]
) -> tuple[list[dict[str, object]], list[object], list[object]]:
    raw = document.get("obligations", [])
    if not isinstance(raw, list):
        errors.append("obligations must be a list")
        return [], [], []
    obligations: list[dict[str, object]] = []
    actual_ids: list[object] = []
    statuses: list[object] = []
    for item in raw:
        identifier, status = validate_obligation(item, errors)
        actual_ids.append(identifier)
        statuses.append(status)
        if isinstance(item, dict):
            obligations.append(item)
    return obligations, actual_ids, statuses


def expected_obligation_ids(actual_ids: list[object], errors: list[str]) -> list[str]:
    parsed_indices: list[int] = []
    for identifier in actual_ids:
        if not isinstance(identifier, str):
            errors.append(f"invalid obligation id {identifier}")
            continue
        match = re.fullmatch(r"AKASHIC-CT-(\d{3})", identifier)
        if match is None:
            errors.append(f"invalid obligation id {identifier}")
            continue
        parsed_indices.append(int(match.group(1)))
    maximum_index = max(parsed_indices, default=0)
    expected = [f"AKASHIC-CT-{index:03d}" for index in range(1, maximum_index + 1)]
    if actual_ids != expected:
        errors.append(f"obligation sequence drifted: expected={expected} actual={actual_ids}")
    return expected


def validate_named_tests(
    obligations: list[dict[str, object]],
    actual_ids: list[object],
    expected_ids: list[str],
    errors: list[str],
) -> None:
    tests = "\n".join(path.read_text() for path in (ROOT / "Tests").rglob("*.swift"))
    test_ids = set(re.findall(r"AKASHIC-CT-\d{3}", tests))
    obligation_ids = set(actual_ids)
    for identifier in sorted(test_ids - obligation_ids):
        errors.append(f"{identifier}: named test occurrence has no conformance obligation")
    named_test_ids = expected_ids[:21] + expected_ids[29:]
    for identifier in named_test_ids:
        status = obligations[int(identifier[-3:]) - 1]["status"]
        missing_named_test = identifier not in tests and identifier not in IMPLEMENTED_WITHOUT_NAMED_TEST
        if isinstance(status, str) and status.startswith("implemented") and missing_named_test:
            errors.append(f"{identifier}: implemented status has no named test occurrence")


def validate_crash_matrix(errors: list[str]) -> None:
    crash_tool = (ROOT / "Tools/Crash/verify_process_crash_matrix.py").read_text()
    switch_points = re.findall(r'"after(?:Blob|Manifest)[A-Za-z]+"', crash_tool)
    if len(switch_points) < 11:
        errors.append("process crash matrix does not retain eleven switch points")


def write_report(
    document: dict[str, object],
    obligations: list[dict[str, object]],
    statuses: list[object],
    errors: list[str],
) -> None:
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


def main() -> int:
    document = json.loads(STATUS.read_text())
    errors: list[str] = []
    validate_document_header(document, errors)
    validate_host_receipt(errors)
    obligations, actual_ids, statuses = collect_obligations(document, errors)
    expected_ids = expected_obligation_ids(actual_ids, errors)
    validate_named_tests(obligations, actual_ids, expected_ids, errors)
    validate_crash_matrix(errors)
    write_report(document, obligations, statuses, errors)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
