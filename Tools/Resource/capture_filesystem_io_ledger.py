#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / ".build" / "release" / "AkashicResourceProbe"
IDENTITY_TOOL = ROOT / "Tools" / "Identity" / "capture_source_identity.py"

CASES = (
    {"blobCount": 64, "blobBytes": 4 * 1024, "readPasses": 2},
    {"blobCount": 32, "blobBytes": 64 * 1024, "readPasses": 2},
    {"blobCount": 8, "blobBytes": 1024 * 1024, "readPasses": 1},
)

RUSAGE_INFO_V4 = 4
RUSAGE_INFO_V6 = 6


class RUsageInfoV6(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "ri_user_time",
            "ri_system_time",
            "ri_pkg_idle_wkups",
            "ri_interrupt_wkups",
            "ri_pageins",
            "ri_wired_size",
            "ri_resident_size",
            "ri_phys_footprint",
            "ri_proc_start_abstime",
            "ri_proc_exit_abstime",
            "ri_child_user_time",
            "ri_child_system_time",
            "ri_child_pkg_idle_wkups",
            "ri_child_interrupt_wkups",
            "ri_child_pageins",
            "ri_child_elapsed_abstime",
            "ri_diskio_bytesread",
            "ri_diskio_byteswritten",
            "ri_cpu_time_qos_default",
            "ri_cpu_time_qos_maintenance",
            "ri_cpu_time_qos_background",
            "ri_cpu_time_qos_utility",
            "ri_cpu_time_qos_legacy",
            "ri_cpu_time_qos_user_initiated",
            "ri_cpu_time_qos_user_interactive",
            "ri_billed_system_time",
            "ri_serviced_system_time",
            "ri_logical_writes",
            "ri_lifetime_max_phys_footprint",
            "ri_instructions",
            "ri_cycles",
            "ri_billed_energy",
            "ri_serviced_energy",
            "ri_interval_max_phys_footprint",
            "ri_runnable_time",
            "ri_flags",
            "ri_user_ptime",
            "ri_system_ptime",
            "ri_pinstructions",
            "ri_pcycles",
            "ri_energy_nj",
            "ri_penergy_nj",
            "ri_secure_time_in_system",
            "ri_secure_ptime_in_system",
            "ri_neural_footprint",
            "ri_lifetime_max_neural_footprint",
            "ri_interval_max_neural_footprint",
            "ri_conclave_footprint",
            "ri_page_wait_time_mach",
            "ri_page_cache_hits",
        )
    ] + [("ri_reserved", ctypes.c_uint64 * 6)]


LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
LIBPROC.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
LIBPROC.proc_pid_rusage.restype = ctypes.c_int


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sample_rusage(pid: int, flavor: int | None = None) -> tuple[RUsageInfoV6, int]:
    flavors = (flavor,) if flavor is not None else (RUSAGE_INFO_V6, RUSAGE_INFO_V4)
    last_error = 0
    for requested_flavor in flavors:
        usage = RUsageInfoV6()
        ctypes.set_errno(0)
        if LIBPROC.proc_pid_rusage(pid, requested_flavor, ctypes.byref(usage)) == 0:
            return usage, requested_flavor
        last_error = ctypes.get_errno()
        if flavor is not None or requested_flavor != RUSAGE_INFO_V6:
            break
        if last_error not in (errno.EINVAL, errno.ENOTSUP):
            break
    raise OSError(last_error, os.strerror(last_error))


def read_signal(descriptor: int, expected: bytes) -> None:
    value = os.read(descriptor, 1)
    if value != expected:
        raise RuntimeError(f"measurement barrier expected {expected!r}, observed {value!r}")


class StatFS(ctypes.Structure):
    _fields_ = [
        ("f_bsize", ctypes.c_uint32),
        ("f_iosize", ctypes.c_int32),
        ("f_blocks", ctypes.c_uint64),
        ("f_bfree", ctypes.c_uint64),
        ("f_bavail", ctypes.c_uint64),
        ("f_files", ctypes.c_uint64),
        ("f_ffree", ctypes.c_uint64),
        ("f_fsid0", ctypes.c_int32),
        ("f_fsid1", ctypes.c_int32),
        ("f_owner", ctypes.c_uint32),
        ("f_type", ctypes.c_uint32),
        ("f_flags", ctypes.c_uint32),
        ("f_fssubtype", ctypes.c_uint32),
        ("f_fstypename", ctypes.c_char * 16),
        ("f_mntonname", ctypes.c_char * 1024),
        ("f_mntfromname", ctypes.c_char * 1024),
        ("f_flags_ext", ctypes.c_uint32),
        ("f_reserved", ctypes.c_uint32 * 7),
    ]


LIBSYSTEM = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
LIBSYSTEM.statfs.argtypes = [ctypes.c_char_p, ctypes.POINTER(StatFS)]
LIBSYSTEM.statfs.restype = ctypes.c_int


def filesystem_identity(path: Path) -> dict[str, str]:
    info = StatFS()
    if LIBSYSTEM.statfs(os.fsencode(path), ctypes.byref(info)) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))

    def text(value: bytes) -> str:
        return value.split(b"\0", 1)[0].decode("utf-8", errors="strict")

    return {
        "type": text(bytes(info.f_fstypename)),
        "mountPoint": text(bytes(info.f_mntonname)),
        "device": text(bytes(info.f_mntfromname)),
    }


def capture_source_identity(destination: Path) -> dict[str, Any]:
    subprocess.run(
        ["python3", str(IDENTITY_TOOL), "--output", str(destination)],
        cwd=ROOT,
        check=True,
    )
    return json.loads(destination.read_text())


def run_sample(
    case: dict[str, int],
    root: Path,
    binary: Path,
    use_directory_head: bool,
    preseed_store: bool,
) -> dict[str, Any]:
    ready_read, ready_write = os.pipe()
    go_read, go_write = os.pipe()
    done_read, done_write = os.pipe()
    release_read, release_write = os.pipe()
    command = [
        str(binary),
        "--root",
        str(root),
        "--blob-count",
        str(case["blobCount"]),
        "--blob-bytes",
        str(case["blobBytes"]),
        "--read-passes",
        str(case["readPasses"]),
        "--measurement-ready-fd",
        str(ready_write),
        "--measurement-go-fd",
        str(go_read),
        "--measurement-done-fd",
        str(done_write),
        "--measurement-release-fd",
        str(release_read),
    ]
    if use_directory_head:
        command.extend(["--use-directory-head", "1"])
    elif preseed_store:
        command.extend(["--preseed-store", "1"])
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        pass_fds=(ready_write, go_read, done_write, release_read),
    )
    for descriptor in (ready_write, go_read, done_write, release_read):
        os.close(descriptor)
    released = False
    try:
        read_signal(ready_read, b"R")
        before, rusage_flavor = sample_rusage(process.pid)
        os.write(go_write, b"G")
        read_signal(done_read, b"D")
        after, after_flavor = sample_rusage(process.pid, rusage_flavor)
        if after_flavor != rusage_flavor:
            raise RuntimeError("rusage flavor changed during one measurement sample")
        os.write(release_write, b"X")
        released = True
        stdout, stderr = process.communicate(timeout=120)
        if process.returncode != 0:
            raise RuntimeError(
                f"resource probe failed ({process.returncode}): {stderr.strip()}"
            )
        report = json.loads(stdout)
    finally:
        for descriptor in (ready_read, go_write, done_read, release_write):
            try:
                os.close(descriptor)
            except OSError:
                pass
        if not released and process.poll() is None:
            process.kill()
            process.wait()

    payload = case["blobCount"] * case["blobBytes"]
    if report.get("logicalPayloadBytes") != payload:
        raise RuntimeError("resource probe payload identity drifted")
    written = int(after.ri_diskio_byteswritten - before.ri_diskio_byteswritten)
    read = int(after.ri_diskio_bytesread - before.ri_diskio_bytesread)
    logical_writes = int(after.ri_logical_writes - before.ri_logical_writes)
    instructions = int(after.ri_instructions - before.ri_instructions)
    cycles = int(after.ri_cycles - before.ri_cycles)
    if written <= 0 or written < payload:
        raise RuntimeError(
            f"invalid filesystem write observation: written={written} payload={payload}"
        )
    return {
        "workloadID": report["workloadID"],
        "blobCount": case["blobCount"],
        "blobBytes": case["blobBytes"],
        "logicalPayloadBytes": payload,
        "logicalMetadataWriteBytes": report["logicalMetadataWriteBytes"],
        "logicalWriteAmplification": report["logicalWriteAmplification"],
        "filesystemReadBytes": read,
        "filesystemWriteBytes": written,
        "filesystemExcessWriteBytes": max(0, written - payload),
        "filesystemWriteAmplificationRatio": written / payload,
        "processLogicalWriteBytes": logical_writes,
        "rusageFlavor": rusage_flavor,
        "processInstructionCount": instructions,
        "processCycleCount": cycles,
        "rusageEnergyNanojouleCounterDelta": (
            int(after.ri_energy_nj - before.ri_energy_nj)
            if rusage_flavor >= RUSAGE_INFO_V6
            else None
        ),
        "rusagePEnergyNanojouleCounterDelta": (
            int(after.ri_penergy_nj - before.ri_penergy_nj)
            if rusage_flavor >= RUSAGE_INFO_V6
            else None
        ),
        "footprint": report["footprint"],
        "commitNanoseconds": report["commitNanoseconds"],
    }


def aggregate(samples: list[dict[str, Any]]) -> dict[str, Any]:
    ratios = [float(sample["filesystemWriteAmplificationRatio"]) for sample in samples]
    writes = [int(sample["filesystemWriteBytes"]) for sample in samples]
    excess = [int(sample["filesystemExcessWriteBytes"]) for sample in samples]
    result: dict[str, Any] = {
        "sampleCount": len(samples),
        "minimumFilesystemWriteBytes": min(writes),
        "medianFilesystemWriteBytes": statistics.median(writes),
        "maximumFilesystemWriteBytes": max(writes),
        "minimumFilesystemExcessWriteBytes": min(excess),
        "medianFilesystemExcessWriteBytes": statistics.median(excess),
        "maximumFilesystemExcessWriteBytes": max(excess),
        "minimumFilesystemWriteAmplificationRatio": min(ratios),
        "medianFilesystemWriteAmplificationRatio": statistics.median(ratios),
        "maximumFilesystemWriteAmplificationRatio": max(ratios),
    }
    instructions = [int(sample["processInstructionCount"]) for sample in samples]
    cycles = [int(sample["processCycleCount"]) for sample in samples]
    result["medianProcessInstructionCount"] = statistics.median(instructions)
    result["medianProcessCycleCount"] = statistics.median(cycles)
    energy = [sample["rusageEnergyNanojouleCounterDelta"] for sample in samples]
    penergy = [sample["rusagePEnergyNanojouleCounterDelta"] for sample in samples]
    if all(isinstance(value, int) for value in energy):
        result["medianRusageEnergyNanojouleCounterDelta"] = statistics.median(energy)
    if all(isinstance(value, int) for value in penergy):
        result["medianRusagePEnergyNanojouleCounterDelta"] = statistics.median(penergy)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument(
        "--use-directory-head",
        action="store_true",
        help="pre-migrate an empty store to schema4 before the measured population",
    )
    parser.add_argument(
        "--preseed-store",
        action="store_true",
        help="create an empty schema3 store before the measured population",
    )
    parser.add_argument(
        "--binary",
        type=Path,
        default=BINARY,
        help="source-bound AkashicResourceProbe binary (defaults to the legacy .build path)",
    )
    parser.add_argument(
        "--case",
        action="append",
        metavar="BLOB_COUNT:BLOB_BYTES:READ_PASSES",
        help="override the default matrix with one or more explicit workload cases",
    )
    args = parser.parse_args()
    if args.repetitions < 1 or args.repetitions > 20:
        parser.error("--repetitions must be between 1 and 20")
    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(f"missing resource probe binary: {binary}")
    requested_cases = CASES
    if args.case:
        parsed_cases: list[dict[str, int]] = []
        for value in args.case:
            try:
                blob_count_text, blob_bytes_text, read_passes_text = value.split(":")
                parsed = {
                    "blobCount": int(blob_count_text),
                    "blobBytes": int(blob_bytes_text),
                    "readPasses": int(read_passes_text),
                }
            except (ValueError, TypeError):
                parser.error(f"invalid --case {value!r}; expected count:bytes:read-passes")
            if parsed["blobCount"] <= 0 or parsed["blobBytes"] <= 0 or parsed["readPasses"] <= 0:
                parser.error(f"invalid --case {value!r}; all values must be positive")
            parsed_cases.append(parsed)
        requested_cases = parsed_cases

    errors: list[str] = []
    case_results: list[dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="akashic-filesystem-io-ledger-") as temporary:
        temporary_root = Path(temporary)
        filesystem = filesystem_identity(temporary_root)
        if filesystem["type"].lower() != "apfs":
            errors.append(
                f"expected APFS measurement filesystem, observed {filesystem['type']!r}"
            )
        for case_index, case in enumerate(requested_cases):
            samples: list[dict[str, Any]] = []
            for repetition in range(args.repetitions):
                try:
                    sample = run_sample(
                        case,
                        temporary_root / f"case-{case_index}-run-{repetition}",
                        binary,
                        args.use_directory_head,
                        args.preseed_store,
                    )
                except Exception as error:  # retained as evidence, not silently retried
                    errors.append(
                        f"{case['blobCount']}x{case['blobBytes']} run {repetition}: {error}"
                    )
                    continue
                sample["repetition"] = repetition
                samples.append(sample)
            case_result: dict[str, Any] = {
                "blobCount": case["blobCount"],
                "blobBytes": case["blobBytes"],
                "readPasses": case["readPasses"],
                "samples": samples,
            }
            if len(samples) != args.repetitions:
                errors.append(
                    f"{case['blobCount']}x{case['blobBytes']}: incomplete repetitions "
                    f"{len(samples)}/{args.repetitions}"
                )
            elif samples:
                case_result["aggregate"] = aggregate(samples)
            case_results.append(case_result)

        identity_path = temporary_root / "source-identity.json"
        identity = capture_source_identity(identity_path)

    output = args.output.resolve()
    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-FILESYSTEM-IO-LEDGER-V1",
        "status": "failed" if errors else "passed",
        "sourceIdentitySHA256": identity["sourceIdentitySHA256"],
        "binarySHA256": sha256(binary),
        "useDirectoryHead": args.use_directory_head,
        "preseedStore": args.preseed_store or args.use_directory_head,
        "measurementContract": {
            "metricID": "cache.write-amplification.bytes",
            "methodID": "filesystem-io-ledger-v1",
            "boundary": (
                "External parent samples Darwin proc_pid_rusage using RUSAGE_INFO_V6 when "
                "available (RUSAGE_INFO_V4 fallback) before FileBlobStore population and after "
                "all population commits return. The child "
                "is held at pipe barriers so process startup, reopen and read phases are excluded."
            ),
            "counter": "ri_diskio_byteswritten",
            "supplementalCounters": [
                "ri_logical_writes",
                "ri_instructions",
                "ri_cycles",
                "ri_energy_nj when RUSAGE_INFO_V6 is available",
                "ri_penergy_nj when RUSAGE_INFO_V6 is available",
            ],
            "rusageFlavorPolicy": (
                "Prefer RUSAGE_INFO_V6 and retain the same flavor for before/after sampling; "
                "fall back to RUSAGE_INFO_V4 only when the host reports V6 unsupported."
            ),
            "flushPolicy": (
                "FileBlobStore/DurableFileWriter production commit path completes file and "
                "directory fsync durability boundaries before the done barrier."
            ),
            "requiredControls": [
                "same APFS filesystem",
                "same FileBlobStore durability level",
                "one isolated store root per process sample",
                "external parent-owned before/after counter sampling",
                "no retry-until-success capture loop",
            ],
        },
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
            "filesystem": filesystem,
        },
        "claims": {
            "filesystemProcessIOBytes": not errors,
            "processCPUWorkCounters": not errors,
            "rusageEnergyCounter": (
                not errors
                and all(
                    sample.get("rusageFlavor") == RUSAGE_INFO_V6
                    for case in case_results
                    for sample in case.get("samples", [])
                )
            ),
            "rusageEnergyCounterIsStorageSpecific": False,
            "physicalDevice": False,
            "nandOrControllerBytes": False,
            "energy": False,
            "powerLoss": False,
        },
        "repetitions": args.repetitions,
        "cases": case_results,
        "errors": errors,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        f"Akashic filesystem I/O ledger: cases={len(case_results)} "
        f"repetitions={args.repetitions} errors={len(errors)}"
    )
    for case in case_results:
        aggregate_result = case.get("aggregate")
        if aggregate_result:
            print(
                f"  {case['blobCount']}x{case['blobBytes']}: "
                f"median_ratio={aggregate_result['medianFilesystemWriteAmplificationRatio']:.6f} "
                f"max_ratio={aggregate_result['maximumFilesystemWriteAmplificationRatio']:.6f}"
            )
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
