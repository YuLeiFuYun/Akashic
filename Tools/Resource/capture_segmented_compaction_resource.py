#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import platform
import select
import statistics
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from capture_filesystem_io_ledger import RUSAGE_INFO_V6, sample_rusage, sha256

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BINARY = ROOT / ".build" / "release" / "AkashicResourceProbe"
IDENTITY_TOOL = ROOT / "Tools" / "Identity" / "capture_source_identity.py"
MODES = ("baseline", "compaction")
PROFILES = ("v1-json", "v2-binary", "v3-binary-compact")
DEFAULT_PROFILES = ("v1-json", "v3-binary-compact")
WORKLOADS = ("hot", "checkpoint")


def case_spec(
    case_id: str,
    *,
    live: int,
    runs: int,
    records: int,
    history: str = "wide",
    workload: str,
    payload: int = 16,
) -> dict[str, Any]:
    return {
        "caseID": case_id,
        "liveEntries": live,
        "runCount": runs,
        "recordsPerRun": records,
        "history": history,
        "workload": workload,
        "foregroundPayloadBytes": payload,
    }


def smoke_cases() -> list[dict[str, Any]]:
    return [
        case_spec(
            f"live1024-r4x512-wide-{workload}",
            live=1024,
            runs=4,
            records=512,
            workload=workload,
        )
        for workload in WORKLOADS
    ]


def full_cases() -> list[dict[str, Any]]:
    geometries = [
        ("live1024-r4x512", 1024, 4, 512),
        ("live16384-r4x512", 16_384, 4, 512),
        ("live16384-r16x512", 16_384, 16, 512),
        ("live16384-r64x32", 16_384, 64, 32),
        ("live16384-r64x512", 16_384, 64, 512),
        ("live99488-r4x512", 99_488, 4, 512),
    ]
    cases: list[dict[str, Any]] = []
    for label, live, runs, records in geometries:
        for workload in WORKLOADS:
            cases.append(
                case_spec(
                    f"{label}-wide-{workload}",
                    live=live,
                    runs=runs,
                    records=records,
                    workload=workload,
                )
            )
    for history in ("hot", "tombstone-recreate"):
        for workload in WORKLOADS:
            cases.append(
                case_spec(
                    f"live16384-r16x512-{history}-{workload}",
                    live=16_384,
                    runs=16,
                    records=512,
                    history=history,
                    workload=workload,
                )
            )
    for workload in WORKLOADS:
        cases.append(
            case_spec(
                f"live16384-r16x512-wide-{workload}-payload64k",
                live=16_384,
                runs=16,
                records=512,
                workload=workload,
                payload=64 * 1024,
            )
        )
    return cases


def read_signal(descriptor: int, expected: bytes, timeout: float) -> None:
    readable, _, _ = select.select([descriptor], [], [], timeout)
    if not readable:
        raise TimeoutError(f"timed out waiting for child signal {expected!r}")
    value = os.read(descriptor, 1)
    if value != expected:
        raise RuntimeError(f"expected child signal {expected!r}, observed {value!r}")


def usage_values(usage: Any, flavor: int) -> dict[str, int | None]:
    return {
        "filesystemReadBytes": int(usage.ri_diskio_bytesread),
        "filesystemWriteBytes": int(usage.ri_diskio_byteswritten),
        "logicalWriteBytes": int(usage.ri_logical_writes),
        "userTimeNanoseconds": int(usage.ri_user_time),
        "systemTimeNanoseconds": int(usage.ri_system_time),
        "instructions": int(usage.ri_instructions),
        "cycles": int(usage.ri_cycles),
        "residentBytes": int(usage.ri_resident_size),
        "physicalFootprintBytes": int(usage.ri_phys_footprint),
        "lifetimeMaximumPhysicalFootprintBytes": int(usage.ri_lifetime_max_phys_footprint),
        "intervalMaximumPhysicalFootprintBytes": int(usage.ri_interval_max_phys_footprint),
        "energyNanojouleCounter": int(usage.ri_energy_nj) if flavor >= RUSAGE_INFO_V6 else None,
        "pEnergyNanojouleCounter": int(usage.ri_penergy_nj) if flavor >= RUSAGE_INFO_V6 else None,
    }


def usage_delta(
    before: Any,
    after: Any,
    flavor: int,
) -> dict[str, int | None]:
    before_values = usage_values(before, flavor)
    after_values = usage_values(after, flavor)
    monotonic = (
        "filesystemReadBytes",
        "filesystemWriteBytes",
        "logicalWriteBytes",
        "userTimeNanoseconds",
        "systemTimeNanoseconds",
        "instructions",
        "cycles",
        "energyNanojouleCounter",
        "pEnergyNanojouleCounter",
    )
    result: dict[str, int | None] = {}
    for key in monotonic:
        lhs = before_values[key]
        rhs = after_values[key]
        result[key] = None if lhs is None or rhs is None else int(rhs - lhs)
    result.update(
        {
            "residentBytesBefore": before_values["residentBytes"],
            "residentBytesAfter": after_values["residentBytes"],
            "physicalFootprintBytesBefore": before_values["physicalFootprintBytes"],
            "physicalFootprintBytesAfter": after_values["physicalFootprintBytes"],
            "lifetimeMaximumPhysicalFootprintBytesAfter": after_values[
                "lifetimeMaximumPhysicalFootprintBytes"
            ],
            "intervalMaximumPhysicalFootprintBytesAfter": after_values[
                "intervalMaximumPhysicalFootprintBytes"
            ],
        }
    )
    return result


def percentile(values: list[int], quantile: float) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * quantile) - 1))
    return int(ordered[index])


def run_case(
    binary: Path,
    temporary: Path,
    case: dict[str, Any],
    profile: str,
    mode: str,
    repetition: int,
) -> dict[str, Any]:
    root = temporary / f"{case['caseID']}-{profile}-{mode}-rep{repetition}"
    ready_read, ready_write = os.pipe()
    go_read, go_write = os.pipe()
    done_read, done_write = os.pipe()
    release_read, release_write = os.pipe()
    argv = [
        str(binary),
        "segmented-schema5-compaction-resource",
        "--root",
        str(root),
        "--profile",
        profile,
        "--mode",
        mode,
        "--live",
        str(case["liveEntries"]),
        "--runs",
        str(case["runCount"]),
        "--records-per-run",
        str(case["recordsPerRun"]),
        "--history",
        str(case["history"]),
        "--workload",
        str(case["workload"]),
        "--foreground-payload-bytes",
        str(case["foregroundPayloadBytes"]),
        "--ready-fd",
        str(ready_write),
        "--go-fd",
        str(go_read),
        "--done-fd",
        str(done_write),
        "--release-fd",
        str(release_read),
    ]
    process = subprocess.Popen(
        argv,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        pass_fds=(ready_write, go_read, done_write, release_read),
    )
    for descriptor in (ready_write, go_read, done_write, release_read):
        os.close(descriptor)
    released = False
    try:
        try:
            read_signal(ready_read, b"R", timeout=600)
        except Exception as error:
            if process.poll() is not None:
                stdout, stderr = process.communicate(timeout=30)
                raise RuntimeError(
                    f"child exited before ready signal exit={process.returncode}: "
                    f"stdout={stdout[-2000:]} stderr={stderr[-4000:]}"
                ) from error
            raise
        before, flavor = sample_rusage(process.pid)
        wall_start = time.monotonic_ns()
        os.write(go_write, b"G")
        read_signal(done_read, b"D", timeout=600)
        wall_elapsed = time.monotonic_ns() - wall_start
        after, after_flavor = sample_rusage(process.pid, flavor=flavor)
        if flavor != after_flavor:
            raise RuntimeError("rusage flavor changed within one case")
        os.write(release_write, b"X")
        released = True
        stdout, stderr = process.communicate(timeout=300)
    finally:
        for descriptor in (ready_read, go_write, done_read, release_write):
            try:
                os.close(descriptor)
            except OSError:
                pass
        if not released and process.poll() is None:
            process.kill()
            process.wait()
    if process.returncode != 0:
        raise RuntimeError(
            f"case {case['caseID']} mode={mode} repetition={repetition} "
            f"failed exit={process.returncode}: {stderr[-4000:]}"
        )
    child = json.loads(stdout)
    if child.get("freshReopenExact") is not True:
        raise RuntimeError(f"case {case['caseID']} failed fresh-reopen exactness")
    if mode == "compaction" and child.get("compactionPublished") is not True:
        raise RuntimeError(f"case {case['caseID']} did not publish compaction")
    operation_values = [int(value) for value in child["foregroundOperationNanoseconds"]]
    return {
        "caseID": case["caseID"],
        "profile": profile,
        "mode": mode,
        "repetition": repetition,
        "wallElapsedNanoseconds": wall_elapsed,
        "rusageFlavor": flavor,
        "rusageDelta": usage_delta(before, after, flavor),
        "foregroundP50Nanoseconds": percentile(operation_values, 0.50),
        "foregroundP95Nanoseconds": percentile(operation_values, 0.95),
        "foregroundP99Nanoseconds": percentile(operation_values, 0.99),
        "child": child,
    }


def capture_identity(path: Path, compare: Path | None = None) -> dict[str, Any]:
    command = ["python3", str(IDENTITY_TOOL), "--output", str(path)]
    if compare is not None:
        command.extend(["--compare", str(compare)])
    completed = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout + completed.stderr)
    return json.loads(path.read_text())


def paired_comparisons(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    index = {
        (sample["caseID"], sample["profile"], sample["repetition"], sample["mode"]): sample
        for sample in samples
    }
    result: list[dict[str, Any]] = []
    identities = sorted(
        {(sample["caseID"], sample["profile"], sample["repetition"]) for sample in samples}
    )
    for case_id, profile, repetition in identities:
        baseline = index[(case_id, profile, repetition, "baseline")]
        compacted = index[(case_id, profile, repetition, "compaction")]
        baseline_p95 = baseline["foregroundP95Nanoseconds"]
        compacted_p95 = compacted["foregroundP95Nanoseconds"]
        result.append(
            {
                "caseID": case_id,
                "profile": profile,
                "repetition": repetition,
                "foregroundP95Ratio": (
                    compacted_p95 / baseline_p95 if baseline_p95 > 0 else None
                ),
                "foregroundP99Ratio": (
                    compacted["foregroundP99Nanoseconds"]
                    / baseline["foregroundP99Nanoseconds"]
                    if baseline["foregroundP99Nanoseconds"] > 0
                    else None
                ),
                "filesystemWriteDeltaBytes": (
                    compacted["rusageDelta"]["filesystemWriteBytes"]
                    - baseline["rusageDelta"]["filesystemWriteBytes"]
                ),
                "filesystemReadDeltaBytes": (
                    compacted["rusageDelta"]["filesystemReadBytes"]
                    - baseline["rusageDelta"]["filesystemReadBytes"]
                ),
                "instructionDelta": (
                    compacted["rusageDelta"]["instructions"]
                    - baseline["rusageDelta"]["instructions"]
                ),
                "cycleDelta": (
                    compacted["rusageDelta"]["cycles"]
                    - baseline["rusageDelta"]["cycles"]
                ),
                "compactionPreparationNanoseconds": compacted["child"].get(
                    "compactionPreparationNanoseconds"
                ),
                "foregroundPreparationOverlapNanoseconds": compacted["child"].get(
                    "foregroundPreparationOverlapNanoseconds"
                ),
                "baselineBackpressure": baseline["child"].get(
                    "capacityBackpressureObserved"
                ),
                "compactionBackpressure": compacted["child"].get(
                    "capacityBackpressureObserved"
                ),
            }
        )
    return result


def cross_profile_comparisons(
    samples: list[dict[str, Any]],
    paired: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    sample_index = {
        (sample["caseID"], sample["profile"], sample["repetition"], sample["mode"]): sample
        for sample in samples
    }
    paired_index = {
        (item["caseID"], item["profile"], item["repetition"]): item for item in paired
    }
    identities = sorted({(sample["caseID"], sample["repetition"]) for sample in samples})
    available_profiles = {sample["profile"] for sample in samples}
    candidate_profiles = sorted(available_profiles - {"v1-json"})
    result: list[dict[str, Any]] = []
    for case_id, repetition in identities:
        if "v1-json" not in available_profiles:
            continue
        for candidate_profile in candidate_profiles:
            required_samples = [
                (case_id, profile, repetition, mode)
                for profile in ("v1-json", candidate_profile)
                for mode in MODES
            ]
            if not all(key in sample_index for key in required_samples):
                continue
            v1_compaction = sample_index[(case_id, "v1-json", repetition, "compaction")]
            candidate_compaction = sample_index[
                (case_id, candidate_profile, repetition, "compaction")
            ]
            v1_baseline = sample_index[(case_id, "v1-json", repetition, "baseline")]
            candidate_baseline = sample_index[
                (case_id, candidate_profile, repetition, "baseline")
            ]
            v1_pair = paired_index[(case_id, "v1-json", repetition)]
            candidate_pair = paired_index[(case_id, candidate_profile, repetition)]
            v1_write_extra = int(v1_pair["filesystemWriteDeltaBytes"])
            candidate_write_extra = int(candidate_pair["filesystemWriteDeltaBytes"])
            v1_instruction_extra = int(v1_pair["instructionDelta"])
            candidate_instruction_extra = int(candidate_pair["instructionDelta"])
            v1_base = int(v1_compaction["child"]["finalBaseBytes"])
            candidate_base = int(candidate_compaction["child"]["finalBaseBytes"])
            result.append(
                {
                    "caseID": case_id,
                    "candidateProfile": candidate_profile,
                    "repetition": repetition,
                    "frozenPhysicalIdentityCommitmentExact": (
                        v1_baseline["child"]["frozenIdentityCommitment"]
                        == candidate_baseline["child"]["frozenIdentityCommitment"]
                        == v1_compaction["child"]["frozenIdentityCommitment"]
                        == candidate_compaction["child"]["frozenIdentityCommitment"]
                    ),
                    "logicalAuthorityCommitmentExact": (
                        v1_baseline["child"]["actorLogicalAuthorityCommitment"]
                        == candidate_baseline["child"]["actorLogicalAuthorityCommitment"]
                        == v1_compaction["child"]["actorLogicalAuthorityCommitment"]
                        == candidate_compaction["child"]["actorLogicalAuthorityCommitment"]
                    ),
                    "v1FinalBaseBytes": v1_base,
                    "candidateFinalBaseBytes": candidate_base,
                    "candidateToV1FinalBaseByteRatio": (
                        candidate_base / v1_base if v1_base > 0 else None
                    ),
                    "v1CompactionExtraFilesystemWriteBytes": v1_write_extra,
                    "candidateCompactionExtraFilesystemWriteBytes": candidate_write_extra,
                    "candidateToV1CompactionExtraFilesystemWriteRatio": (
                        candidate_write_extra / v1_write_extra if v1_write_extra > 0 else None
                    ),
                    "v1CompactionInstructionDelta": v1_instruction_extra,
                    "candidateCompactionInstructionDelta": candidate_instruction_extra,
                    "candidateToV1CompactionInstructionRatio": (
                        candidate_instruction_extra / v1_instruction_extra
                        if v1_instruction_extra > 0
                        else None
                    ),
                    "candidateToV1CompactionForegroundP95Ratio": (
                        candidate_compaction["foregroundP95Nanoseconds"]
                        / v1_compaction["foregroundP95Nanoseconds"]
                        if v1_compaction["foregroundP95Nanoseconds"] > 0
                        else None
                    ),
                }
            )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=DEFAULT_BINARY)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--matrix", choices=("smoke", "full"), default="smoke")
    parser.add_argument("--case-id", action="append", default=[])
    parser.add_argument("--profile", action="append", choices=PROFILES, default=[])
    parser.add_argument("--repetitions", type=int, default=1)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    if args.repetitions <= 0 or args.repetitions > 5:
        raise ValueError("repetitions must be within 1...5")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    source_before_path = args.output.with_suffix(".source-before.json")
    source_after_path = args.output.with_suffix(".source-after.json")
    source_before = capture_identity(source_before_path)
    cases = smoke_cases() if args.matrix == "smoke" else full_cases()
    profiles = list(dict.fromkeys(args.profile)) if args.profile else list(DEFAULT_PROFILES)
    if args.case_id:
        requested = set(args.case_id)
        known = {case["caseID"] for case in cases}
        unknown = sorted(requested - known)
        if unknown:
            raise ValueError(f"unknown case IDs for {args.matrix}: {unknown}")
        cases = [case for case in cases if case["caseID"] in requested]
        if not cases:
            raise ValueError("case filter selected no cases")
    samples: list[dict[str, Any]] = []
    errors: list[str] = []
    with tempfile.TemporaryDirectory(prefix="akashic-schema5-compaction-resource-") as temporary:
        temporary_root = Path(temporary)
        for case in cases:
            for repetition in range(args.repetitions):
                for profile in profiles:
                    for mode in MODES:
                        try:
                            samples.append(
                                run_case(
                                    binary,
                                    temporary_root,
                                    case,
                                    profile,
                                    mode,
                                    repetition,
                                )
                            )
                        except Exception as error:
                            errors.append(
                                f"{case['caseID']} profile={profile} repetition={repetition} "
                                f"mode={mode}: {error}"
                            )
    source_after = capture_identity(source_after_path, compare=source_before_path)
    comparisons = paired_comparisons(samples) if not errors else []
    profile_comparisons = (
        cross_profile_comparisons(samples, comparisons)
        if not errors and "v1-json" in profiles and len(profiles) > 1
        else []
    )
    result = {
        "schemaVersion": 3,
        "matrixID": "AKASHIC-SCHEMA5-COMPACTION-RESOURCE-MECHANISM-V3",
        "status": "failed" if errors else "passed",
        "matrix": args.matrix,
        "repetitions": args.repetitions,
        "caseCount": len(cases),
        "profiles": profiles,
        "sampleCount": len(samples),
        "sourceIdentitySHA256": source_before["sourceIdentitySHA256"],
        "sourceIdentityFileCount": source_before["fileCount"],
        "sourceIdentityStableAcrossCampaign": source_before == source_after,
        "binarySHA256": sha256(binary),
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "rusageSemantics": (
            "Darwin proc_pid_rusage, preferring RUSAGE_INFO_V6 with V4 fallback; "
            "filesystem counters are process-visible and are not NAND/controller I/O"
        ),
        "samples": samples,
        "pairedComparisons": comparisons,
        "crossProfileComparisons": profile_comparisons,
        "errors": errors,
        "claims": {
            "mechanismMeasurement": True,
            "formalPerformance": False,
            "endToEndStorePerformance": False,
            "physicalIOBytes": False,
            "physicalDevice": False,
            "energy": False,
            "powerLoss": False,
            "automaticCompactionTrigger": False,
        },
    }
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic schema5 compaction resource mechanism: "
        f"status={result['status']} cases={len(cases)} samples={len(samples)} "
        f"source={source_before['sourceIdentitySHA256']}"
    )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
