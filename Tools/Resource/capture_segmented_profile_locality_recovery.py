#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BINARY = ROOT / ".build" / "release" / "AkashicResourceProbe"
IDENTITY_TOOL = ROOT / "Tools" / "Identity" / "capture_source_identity.py"
PROFILES = ("v1-json", "v2-binary", "v3-binary-compact", "v4-compound")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def capture_identity(path: Path, compare: Path | None = None) -> dict[str, Any]:
    command = ["python3", str(IDENTITY_TOOL), "--output", str(path)]
    if compare is not None:
        command.extend(["--compare", str(compare)])
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout + completed.stderr)
    return json.loads(path.read_text())


def run_probe(binary: Path, command: str, root: Path, profile: str) -> dict[str, Any]:
    completed = subprocess.run(
        [str(binary), command, "--root", str(root), "--profile", profile],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=420,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"{command} profile={profile} failed ({completed.returncode})\n"
            + completed.stdout
            + completed.stderr
        )
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"{command} profile={profile} produced invalid JSON: {error}\n{completed.stdout}"
        ) from error
    if report.get("profile") != profile:
        raise RuntimeError(
            f"{command} profile mismatch: expected {profile!r}, observed {report.get('profile')!r}"
        )
    return report


def validate_locality(report: dict[str, Any]) -> None:
    checks = report.get("checks")
    if not isinstance(checks, dict) or not checks or not all(checks.values()):
        raise RuntimeError(f"locality checks failed: {checks!r}")
    claims = report.get("claims") or {}
    if claims.get("writeAmplificationMechanism") is not True:
        raise RuntimeError("locality report lost mechanism claim")
    if claims.get("formalPerformance") is not False or claims.get("physicalDeviceIO") is not False:
        raise RuntimeError("locality report overclaims performance or physical I/O")
    cases = report.get("cases")
    if not isinstance(cases, list) or not cases:
        raise RuntimeError("locality report has no cases")
    for row in cases:
        if row.get("logicalAuthorityExactBeforeReopen") is not True:
            raise RuntimeError("locality authority mismatch before reopen")
        if row.get("logicalReopenExact") is not True:
            raise RuntimeError("locality authority mismatch after reopen")


def validate_recovery(report: dict[str, Any]) -> None:
    if report.get("allExact") is not True:
        raise RuntimeError("recovery report is not exact")
    for key in (
        "unaffectedOwnershipConflictRejected",
        "sameRunOwnershipSwapAccepted",
        "corruptRunRejectedBeforeIndexedApply",
    ):
        if report.get(key) is not True:
            raise RuntimeError(f"recovery control failed: {key}")
    claims = report.get("claims") or {}
    if claims.get("formalPerformance") is not False or claims.get("physicalIOBytes") is not False:
        raise RuntimeError("recovery report overclaims performance or physical I/O")
    samples = report.get("samples")
    if not isinstance(samples, list) or not samples or not all(row.get("exactState") for row in samples):
        raise RuntimeError("recovery samples are incomplete or inexact")


def locality_comparisons(reports: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    by_profile = {
        profile: {int(row["workingSet"]): row for row in report["cases"]}
        for profile, report in reports.items()
    }
    baseline = by_profile["v1-json"]
    result: list[dict[str, Any]] = []
    for working_set in sorted(baseline):
        v1 = baseline[working_set]
        for profile in reports:
            if profile == "v1-json":
                continue
            candidate = by_profile[profile][working_set]
            result.append(
                {
                    "workingSet": working_set,
                    "candidateProfile": profile,
                    "v1LogicalMetadataWriteBytes": v1["logicalMetadataWriteBytes"],
                    "candidateLogicalMetadataWriteBytes": candidate["logicalMetadataWriteBytes"],
                    "candidateToV1LogicalMetadataWriteRatio": (
                        candidate["logicalMetadataWriteBytes"] / v1["logicalMetadataWriteBytes"]
                        if v1["logicalMetadataWriteBytes"] > 0
                        else None
                    ),
                    "v1RegularMetadataWriteBytes": v1["logicalRegularMetadataWriteBytes"],
                    "candidateRegularMetadataWriteBytes": candidate["logicalRegularMetadataWriteBytes"],
                    "v1RootPublicationCount": v1["rootPublicationCount"],
                    "candidateRootPublicationCount": candidate["rootPublicationCount"],
                    "v1SegmentPublicationCount": v1["segmentPublicationCount"],
                    "candidateSegmentPublicationCount": candidate["segmentPublicationCount"],
                    "v1FinalRunCount": v1["finalRootRunCount"],
                    "candidateFinalRunCount": candidate["finalRootRunCount"],
                    "logicalAuthorityExact": (
                        v1["logicalReopenExact"] is True
                        and candidate["logicalReopenExact"] is True
                    ),
                }
            )
    return result


def recovery_comparisons(reports: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    def sample(report: dict[str, Any], depth: int) -> dict[str, Any]:
        return next(row for row in report["samples"] if int(row["depth"]) == depth)

    v1_report = reports["v1-json"]
    result: list[dict[str, Any]] = []
    for depth in v1_report["depths"]:
        depth = int(depth)
        v1_sample = sample(v1_report, depth)
        v1_ns = int(v1_report["medians"][f"depth-{depth}-segmented"])
        for profile, report in reports.items():
            if profile == "v1-json":
                continue
            candidate = sample(report, depth)
            candidate_ns = int(report["medians"][f"depth-{depth}-segmented"])
            result.append(
                {
                    "depth": depth,
                    "candidateProfile": profile,
                    "v1BaseBytes": v1_sample["baseBytes"],
                    "candidateBaseBytes": candidate["baseBytes"],
                    "candidateToV1BaseByteRatio": (
                        candidate["baseBytes"] / v1_sample["baseBytes"]
                        if v1_sample["baseBytes"] > 0
                        else None
                    ),
                    "v1ReferencedBytes": v1_sample["referencedBytes"],
                    "candidateReferencedBytes": candidate["referencedBytes"],
                    "candidateToV1ReferencedByteRatio": (
                        candidate["referencedBytes"] / v1_sample["referencedBytes"]
                        if v1_sample["referencedBytes"] > 0
                        else None
                    ),
                    "v1MedianRecoverNanoseconds": v1_ns,
                    "candidateMedianRecoverNanoseconds": candidate_ns,
                    "candidateToV1MedianRecoverRatio": candidate_ns / v1_ns if v1_ns > 0 else None,
                    "exactState": candidate["exactState"] is True,
                }
            )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", action="append", choices=PROFILES, default=[])
    args = parser.parse_args()

    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    profiles = list(dict.fromkeys(args.profile)) if args.profile else list(PROFILES)
    if "v1-json" not in profiles:
        raise ValueError("v1-json is required as the comparison baseline")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    source_before_path = args.output.with_suffix(".source-before.json")
    source_after_path = args.output.with_suffix(".source-after.json")
    source_before = capture_identity(source_before_path)

    locality: dict[str, dict[str, Any]] = {}
    recovery: dict[str, dict[str, Any]] = {}
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="akashic-profile-locality-recovery-") as temporary:
        temporary_root = Path(temporary)
        for profile in profiles:
            try:
                locality_report = run_probe(
                    binary,
                    "segmented-schema5-locality-io-current",
                    temporary_root / f"locality-{profile}",
                    profile,
                )
                validate_locality(locality_report)
                locality[profile] = locality_report
            except Exception as error:
                errors.append(f"locality profile={profile}: {error}")
                continue
            try:
                recovery_report = run_probe(
                    binary,
                    "segmented-schema5-reopen-depth",
                    temporary_root / f"recovery-{profile}",
                    profile,
                )
                validate_recovery(recovery_report)
                recovery[profile] = recovery_report
            except Exception as error:
                errors.append(f"recovery profile={profile}: {error}")

    source_after = capture_identity(source_after_path, compare=source_before_path)
    source_stable = source_before == source_after
    complete = not errors and set(locality) == set(profiles) and set(recovery) == set(profiles)
    comparisons_ready = complete and "v1-json" in locality and "v1-json" in recovery
    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-SCHEMA5-PROFILE-LOCALITY-RECOVERY-MECHANISM-V1",
        "status": "passed" if complete and source_stable else "failed",
        "profiles": profiles,
        "sourceIdentitySHA256": source_before["sourceIdentitySHA256"],
        "sourceIdentityFileCount": source_before["fileCount"],
        "sourceIdentityStableAcrossCampaign": source_stable,
        "binarySHA256": sha256(binary),
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "localityReports": locality,
        "recoveryReports": recovery,
        "localityComparisons": locality_comparisons(locality) if comparisons_ready else [],
        "recoveryComparisons": recovery_comparisons(recovery) if comparisons_ready else [],
        "errors": errors,
        "claims": {
            "mechanismMeasurement": True,
            "formalPerformance": False,
            "physicalIOBytes": False,
            "physicalDevice": False,
            "energy": False,
            "powerLoss": False,
            "profilePromotionDecision": False,
        },
    }
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic schema5 profile locality/recovery mechanism: "
        f"status={result['status']} profiles={','.join(profiles)} "
        f"source={source_before['sourceIdentitySHA256']}"
    )
    for error in errors:
        print(f"error: {error}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
