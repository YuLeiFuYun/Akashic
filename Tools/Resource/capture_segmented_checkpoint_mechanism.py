#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

RUSAGE_INFO_V4 = 4
HISTORIES = (512, 4096, 16384, 65536)
MODES = ("current-full", "segmented-epoch")
REPETITIONS = 5


class RUsageInfoV4(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class ProcTaskInfo:
    def __init__(self) -> None:
        self._libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self._proc_pid_rusage = self._libproc.proc_pid_rusage
        self._proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self._proc_pid_rusage.restype = ctypes.c_int

    def sample(self, pid: int) -> dict[str, int]:
        value = RUsageInfoV4()
        result = self._proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(value))
        if result != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        return {
            "bytesRead": int(value.ri_diskio_bytesread),
            "bytesWritten": int(value.ri_diskio_byteswritten),
            "logicalWrites": int(value.ri_logical_writes),
            "userTimeNanoseconds": int(value.ri_user_time),
            "systemTimeNanoseconds": int(value.ri_system_time),
            "instructions": int(value.ri_instructions),
            "cycles": int(value.ri_cycles),
        }


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def delta(before: dict[str, int], after: dict[str, int]) -> dict[str, int]:
    return {key: after[key] - before[key] for key in before}


def read_signal(fd: int, expected: bytes) -> None:
    value = os.read(fd, 1)
    if value != expected:
        raise RuntimeError(f"expected signal {expected!r}, got {value!r}")


def run_case(
    binary: Path,
    root: Path,
    mode: str,
    history: int,
    repetition: int,
    task_info: ProcTaskInfo,
) -> dict[str, object]:
    ready_r, ready_w = os.pipe()
    go_r, go_w = os.pipe()
    done_r, done_w = os.pipe()
    release_r, release_w = os.pipe()
    argv = [
        str(binary),
        "segmented-checkpoint-resource",
        "--root",
        str(root),
        "--mode",
        mode,
        "--history",
        str(history),
        "--ready-fd",
        str(ready_w),
        "--go-fd",
        str(go_r),
        "--done-fd",
        str(done_w),
        "--release-fd",
        str(release_r),
    ]
    process = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        pass_fds=(ready_w, go_r, done_w, release_r),
    )
    os.close(ready_w)
    os.close(go_r)
    os.close(done_w)
    os.close(release_r)
    try:
        read_signal(ready_r, b"R")
        before = task_info.sample(process.pid)
        wall_start = time.monotonic_ns()
        os.write(go_w, b"G")
        read_signal(done_r, b"D")
        wall_elapsed = time.monotonic_ns() - wall_start
        after = task_info.sample(process.pid)
        os.write(release_w, b"X")
        stdout, stderr = process.communicate(timeout=30)
    finally:
        for fd in (ready_r, go_w, done_r, release_w):
            try:
                os.close(fd)
            except OSError:
                pass
        if process.poll() is None:
            process.kill()
            process.wait()
    if process.returncode != 0:
        raise RuntimeError(
            f"case mode={mode} history={history} repetition={repetition} "
            f"failed {process.returncode}: {stderr[-2000:]}"
        )
    try:
        child = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid child JSON: {error}; stdout={stdout[-2000:]}") from error
    if not child.get("logicalStateEquivalent"):
        raise RuntimeError("child failed logical equivalence")
    return {
        "mode": mode,
        "historyEntries": history,
        "repetition": repetition,
        "wallElapsedNanoseconds": wall_elapsed,
        "rusageDelta": delta(before, after),
        "child": child,
    }


def summarize(cases: list[dict[str, object]]) -> list[dict[str, object]]:
    summaries: list[dict[str, object]] = []
    for history in HISTORIES:
        per_mode: dict[str, dict[str, object]] = {}
        for mode in MODES:
            rows = [
                row for row in cases
                if row["historyEntries"] == history and row["mode"] == mode
            ]
            child_elapsed = [int(row["child"]["measuredElapsedNanoseconds"]) for row in rows]
            wall_elapsed = [int(row["wallElapsedNanoseconds"]) for row in rows]
            fs_writes = [int(row["rusageDelta"]["bytesWritten"]) for row in rows]
            logical_writes = [int(row["rusageDelta"]["logicalWrites"]) for row in rows]
            authority_bytes = [int(row["child"]["measuredRegularFileAuthorityBytes"]) for row in rows]
            per_mode[mode] = {
                "sampleCount": len(rows),
                "childElapsedMedianNanoseconds": int(statistics.median(child_elapsed)),
                "childElapsedMaximumNanoseconds": max(child_elapsed),
                "wallElapsedMedianNanoseconds": int(statistics.median(wall_elapsed)),
                "filesystemBytesWrittenMedian": int(statistics.median(fs_writes)),
                "filesystemBytesWrittenMaximum": max(fs_writes),
                "logicalWritesMedian": int(statistics.median(logical_writes)),
                "authorityBytes": authority_bytes[0],
                "allAuthorityBytesEqual": len(set(authority_bytes)) == 1,
            }
        current = per_mode["current-full"]
        segmented = per_mode["segmented-epoch"]
        summaries.append(
            {
                "historyEntries": history,
                "modes": per_mode,
                "segmentedToCurrentChildElapsedMedianRatio":
                    segmented["childElapsedMedianNanoseconds"] / current["childElapsedMedianNanoseconds"],
                "segmentedToCurrentFilesystemWriteMedianRatio":
                    segmented["filesystemBytesWrittenMedian"] / current["filesystemBytesWrittenMedian"]
                    if current["filesystemBytesWrittenMedian"] else None,
                "segmentedToCurrentAuthorityByteRatio":
                    segmented["authorityBytes"] / current["authorityBytes"],
            }
        )
    return summaries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-root", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    args.run_root.mkdir(parents=True, exist_ok=True)
    task_info = ProcTaskInfo()

    cases: list[dict[str, object]] = []
    # Deterministic paired interleaving: reverse mode order every repetition to reduce ordering bias.
    for history in HISTORIES:
        for repetition in range(REPETITIONS):
            mode_order = MODES if repetition % 2 == 0 else tuple(reversed(MODES))
            for mode in mode_order:
                case_root = args.run_root / f"h{history}-r{repetition}-{mode}"
                cases.append(
                    run_case(
                        binary=binary,
                        root=case_root,
                        mode=mode,
                        history=history,
                        repetition=repetition,
                        task_info=task_info,
                    )
                )

    summaries = summarize(cases)
    by_history = {row["historyEntries"]: row for row in summaries}
    success = {
        "allCasesLogicalEquivalent": all(bool(row["child"]["logicalStateEquivalent"]) for row in cases),
        "segmentedAuthorityBytesBoundedAcrossHistory": len({
            row["modes"]["segmented-epoch"]["authorityBytes"] for row in summaries
        }) == 1,
        "currentAuthorityBytesGrowWithHistory": all(
            summaries[index]["modes"]["current-full"]["authorityBytes"]
            < summaries[index + 1]["modes"]["current-full"]["authorityBytes"]
            for index in range(len(summaries) - 1)
        ),
        "history16384ElapsedRatioAtMost0_75":
            by_history[16384]["segmentedToCurrentChildElapsedMedianRatio"] <= 0.75,
        "history65536ElapsedRatioAtMost0_50":
            by_history[65536]["segmentedToCurrentChildElapsedMedianRatio"] <= 0.50,
        "history65536FilesystemWriteRatioAtMost0_25":
            by_history[65536]["segmentedToCurrentFilesystemWriteMedianRatio"] is not None
            and by_history[65536]["segmentedToCurrentFilesystemWriteMedianRatio"] <= 0.25,
    }
    result = {
        "schemaVersion": 1,
        "measurementID": "AKASHIC-SEGMENTED-CHECKPOINT-MECHANISM-V1",
        "binarySHA256": sha256(binary),
        "histories": list(HISTORIES),
        "deltaRecords": 512,
        "repetitionsPerModeHistory": REPETITIONS,
        "measurementBoundary": "after synthetic state/base and old authority are durable; covers authority checkpoint encode/write/head initialization only",
        "rusageSemantics": "proc_pid_rusage RUSAGE_INFO_V4 process-visible filesystem counters; not physical NAND/controller I/O",
        "claims": {
            "mechanismMeasurement": True,
            "endToEndStorePerformance": False,
            "physicalIOBytes": False,
            "physicalDevice": False,
            "energy": False,
            "powerLoss": False,
            "productionFormat": False,
        },
        "successCriteria": success,
        "allSuccessCriteriaPass": all(success.values()),
        "summaries": summaries,
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic segmented checkpoint mechanism: "
        f"cases={len(cases)} success={result['allSuccessCriteriaPass']}"
    )
    for name, passed in success.items():
        print(f"{name}={passed}")
    return 0 if result["allSuccessCriteriaPass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
