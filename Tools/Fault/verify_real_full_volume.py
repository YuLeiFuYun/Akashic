#!/usr/bin/env python3
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import platform
import plistlib
import select
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

ENOSPC = errno.ENOSPC


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(
    command: list[str],
    *,
    timeout: float = 90,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"stdout={completed.stdout[-1000:]}\nstderr={completed.stderr[-1000:]}"
        )
    return completed


def available_bytes(path: Path) -> int:
    values = os.statvfs(path)
    return values.f_bavail * values.f_frsize


def total_bytes(path: Path) -> int:
    values = os.statvfs(path)
    return values.f_blocks * values.f_frsize


def filesystem_type(path: Path) -> str:
    completed = subprocess.run(
        ["diskutil", "info", "-plist", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"diskutil info failed ({completed.returncode}): "
            f"{completed.stderr.decode(errors='replace')[-1000:]}"
        )
    document = plistlib.loads(completed.stdout)
    value = document.get("FilesystemType") or document.get("FilesystemName")
    if not isinstance(value, str) or not value:
        raise RuntimeError("diskutil info did not report a filesystem type")
    return value


@contextmanager
def mounted_apfs_volume(size_megabytes: int, case_name: str) -> Iterator[tuple[Path, dict[str, object]]]:
    temporary = Path(tempfile.mkdtemp(prefix=f"akashic-full-volume-{case_name}-"))
    image_base = temporary / "volume"
    mountpoint = temporary / "mount"
    mountpoint.mkdir(mode=0o700)
    volume_name = f"Akashic-{case_name[:20]}"
    attached = False
    try:
        create = run(
            [
                "hdiutil",
                "create",
                "-size",
                f"{size_megabytes}m",
                "-fs",
                "APFS",
                "-volname",
                volume_name,
                "-type",
                "SPARSE",
                "-ov",
                str(image_base),
            ]
        )
        candidates = [
            image_base,
            image_base.with_suffix(".sparseimage"),
            image_base.with_suffix(".dmg"),
        ]
        image = next((candidate for candidate in candidates if candidate.is_file()), None)
        if image is None:
            raise RuntimeError(
                f"hdiutil did not create an image: {create.stdout} {create.stderr}"
            )

        run(
            [
                "hdiutil",
                "attach",
                str(image),
                "-nobrowse",
                "-mountpoint",
                str(mountpoint),
            ]
        )
        attached = True
        fs_type = filesystem_type(mountpoint)
        if fs_type.lower() != "apfs":
            raise RuntimeError(f"expected APFS, observed {fs_type!r}")
        metadata: dict[str, object] = {
            "filesystem": fs_type,
            "imageType": "sparse-disk-image",
            "requestedImageBytes": size_megabytes * 1024 * 1024,
            "mountedVolumeBytes": total_bytes(mountpoint),
        }
        yield mountpoint, metadata
    finally:
        if attached:
            detached = run(
                ["hdiutil", "detach", str(mountpoint), "-force"],
                check=False,
            )
            if detached.returncode != 0:
                run(["diskutil", "unmount", "force", str(mountpoint)], check=False)
                detached = run(
                    ["hdiutil", "detach", str(mountpoint), "-force"],
                    check=False,
                )
            if detached.returncode != 0:
                print(
                    f"warning: unable to detach {mountpoint}: {detached.stderr[-1000:]}",
                    file=sys.stderr,
                )
        shutil.rmtree(temporary, ignore_errors=True)


def fill_to_enospc(path: Path) -> tuple[int, int]:
    descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    written = 0
    observed_errno = 0
    try:
        for chunk_size in (1024 * 1024, 64 * 1024, 4 * 1024, 512, 1):
            chunk = bytes(chunk_size)
            while True:
                try:
                    count = os.write(descriptor, chunk)
                    if count <= 0:
                        raise OSError(errno.EIO, "write returned no progress")
                    written += count
                except OSError as error:
                    if error.errno != ENOSPC:
                        raise
                    observed_errno = error.errno
                    break
        try:
            os.fsync(descriptor)
        except OSError as error:
            if error.errno != ENOSPC:
                raise
            observed_errno = error.errno
    finally:
        os.close(descriptor)
    if observed_errno != ENOSPC:
        raise RuntimeError("filler did not observe ENOSPC")
    return written, observed_errno


def write_exact(path: Path, byte_count: int) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    remaining = byte_count
    chunk = bytes(1024 * 1024)
    try:
        while remaining > 0:
            requested = min(remaining, len(chunk))
            count = os.write(descriptor, chunk[:requested])
            if count <= 0:
                raise OSError(errno.EIO, "write returned no progress")
            remaining -= count
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def calibrate_available_space(
    filler: Path,
    mountpoint: Path,
    full_written_bytes: int,
    reserve_bytes: int,
) -> int:
    filler.unlink()
    os.sync()
    for _ in range(50):
        if available_bytes(mountpoint) > reserve_bytes:
            break
        time.sleep(0.05)
    else:
        raise RuntimeError("APFS did not reclaim the deleted calibration filler")
    target_filler_bytes = max(0, full_written_bytes - reserve_bytes)
    write_exact(filler, target_filler_bytes)
    return available_bytes(mountpoint)


def parse_probe_output(completed: subprocess.CompletedProcess[str]) -> dict[str, object]:
    if completed.returncode != 0:
        raise RuntimeError(
            f"probe failed ({completed.returncode}): stdout={completed.stdout[-1000:]} "
            f"stderr={completed.stderr[-1000:]}"
        )
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if not lines:
        raise RuntimeError("probe produced no output")
    try:
        value = json.loads(lines[-1])
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid probe JSON: {lines[-1]!r}: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError("probe JSON must be an object")
    return value


def probe(binary: Path, mode: str, root: Path, payload_bytes: int | None = None) -> dict[str, object]:
    command = [str(binary), mode, str(root)]
    if payload_bytes is not None:
        command.append(str(payload_bytes))
    return parse_probe_output(run(command, timeout=120, check=False))


def expect_enospc(result: dict[str, object], operation: str) -> None:
    if result.get("status") != "failed":
        raise RuntimeError(f"{operation} unexpectedly succeeded: {result}")
    if result.get("errno") != ENOSPC:
        raise RuntimeError(f"{operation} did not report underlying POSIX ENOSPC: {result}")
    if result.get("errorType") != "POSIXError" and result.get("underlyingPOSIXError") is not True:
        raise RuntimeError(f"{operation} did not preserve the POSIX error chain: {result}")


def expect_recovered_store(result: dict[str, object]) -> None:
    expected = {
        "status": "inspected",
        "baselineDisposition": "hit",
        "targetDisposition": "miss",
        "blobCount": 1,
        "temporaryCount": 0,
        "manifestExists": True,
    }
    for key, value in expected.items():
        if result.get(key) != value:
            raise RuntimeError(f"recovered store mismatch for {key}: expected {value!r}, got {result.get(key)!r}")


def temporary_files(root: Path) -> list[str]:
    return sorted(
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.name.startswith(".durable-tmp-") or path.name.startswith(".tmp-")
    )


def durable_replacement_case(
    binary: Path,
    image_size_megabytes: int,
    payload_bytes: int,
) -> dict[str, object]:
    with mounted_apfs_volume(image_size_megabytes, "durable") as (mountpoint, metadata):
        root = mountpoint / "durable"
        root.mkdir(mode=0o700)
        destination = root / "state.bin"
        old = b"old-durable-state-v1"
        destination.write_bytes(old)
        os.chmod(destination, 0o600)
        filler = mountpoint / "filler.bin"
        filled_bytes, observed_errno = fill_to_enospc(filler)
        available_before = calibrate_available_space(
            filler, mountpoint, filled_bytes, 4 * 1024 * 1024
        )
        if available_before >= payload_bytes:
            raise RuntimeError(
                f"released space {available_before} is not below payload {payload_bytes}"
            )
        result = probe(binary, "full-volume-durable", root, payload_bytes)
        expect_enospc(result, "durable replacement")
        if destination.read_bytes() != old:
            raise RuntimeError("durable replacement changed the old destination after ENOSPC")
        leftovers = temporary_files(root)
        if leftovers:
            raise RuntimeError(f"durable replacement left temporary files: {leftovers}")
        return {
            "caseID": "real-apfs-durable-replacement-enospc",
            **metadata,
            "filledBytes": filled_bytes,
            "availableBytesBeforeOperation": available_before,
            "kernelErrno": observed_errno,
            "probe": result,
            "oldDestinationPreserved": True,
            "temporaryCount": 0,
            "status": "passed",
        }


def stage_enospc_case(
    binary: Path,
    image_size_megabytes: int,
    payload_bytes: int,
) -> dict[str, object]:
    with mounted_apfs_volume(image_size_megabytes, "stage") as (mountpoint, metadata):
        root = mountpoint / "store"
        seed = probe(binary, "full-volume-seed", root)
        if seed.get("status") != "seeded":
            raise RuntimeError(f"unable to seed store: {seed}")
        filler = mountpoint / "filler.bin"
        filled_bytes, observed_errno = fill_to_enospc(filler)
        available_before = calibrate_available_space(
            filler, mountpoint, filled_bytes, 4 * 1024 * 1024
        )
        if available_before >= payload_bytes:
            raise RuntimeError(
                f"released space {available_before} is not below payload {payload_bytes}"
            )
        attempted = probe(binary, "full-volume-commit", root, payload_bytes)
        expect_enospc(attempted, "blob stage")
        filler.unlink()
        recovered = probe(binary, "full-volume-inspect", root, payload_bytes)
        expect_recovered_store(recovered)
        return {
            "caseID": "real-apfs-blob-stage-enospc",
            **metadata,
            "filledBytes": filled_bytes,
            "availableBytesBeforeOperation": available_before,
            "kernelErrno": observed_errno,
            "probe": attempted,
            "recovered": recovered,
            "status": "passed",
        }


def read_line_with_timeout(process: subprocess.Popen[bytes], timeout: float) -> bytes:
    assert process.stdout is not None
    readable, _, _ = select.select([process.stdout], [], [], timeout)
    if not readable:
        return b""
    return process.stdout.readline()


def manifest_enospc_case(
    binary: Path,
    image_size_megabytes: int,
    payload_bytes: int,
) -> dict[str, object]:
    with mounted_apfs_volume(image_size_megabytes, "manifest") as (mountpoint, metadata):
        root = mountpoint / "store"
        seed = probe(binary, "full-volume-seed", root)
        if seed.get("status") != "seeded":
            raise RuntimeError(f"unable to seed store: {seed}")
        process = subprocess.Popen(
            [str(binary), "full-volume-stage-publish", str(root), str(payload_bytes)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        staged = read_line_with_timeout(process, 60)
        if staged != b"staged\n":
            process.kill()
            _, stderr = process.communicate(timeout=10)
            raise RuntimeError(
                f"probe did not reach staged boundary: line={staged!r} "
                f"stderr={stderr.decode(errors='replace')[-1000:]}"
            )
        filler = mountpoint / "filler.bin"
        filled_bytes, observed_errno = fill_to_enospc(filler)
        available_before = available_bytes(mountpoint)
        assert process.stdin is not None
        process.stdin.write(b"x")
        process.stdin.flush()
        process.stdin.close()
        process.stdin = None
        stdout, stderr = process.communicate(timeout=120)
        completed = subprocess.CompletedProcess(
            args=process.args,
            returncode=process.returncode,
            stdout=stdout.decode(errors="replace"),
            stderr=stderr.decode(errors="replace"),
        )
        attempted = parse_probe_output(completed)
        expect_enospc(attempted, "manifest publication")
        filler.unlink()
        recovered = probe(binary, "full-volume-inspect", root, payload_bytes)
        expect_recovered_store(recovered)
        return {
            "caseID": "real-apfs-manifest-publication-enospc",
            **metadata,
            "filledBytes": filled_bytes,
            "availableBytesBeforeOperation": available_before,
            "kernelErrno": observed_errno,
            "probe": attempted,
            "recovered": recovered,
            "status": "passed",
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image-size-megabytes", type=int, default=64)
    parser.add_argument("--payload-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args()

    if sys.platform != "darwin":
        raise RuntimeError("real full-volume verification requires Darwin")
    for tool in ("hdiutil", "diskutil", "stat"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"required system tool is unavailable: {tool}")

    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    if args.image_size_megabytes < 32:
        raise ValueError("image size must be at least 32 MiB")
    if not 1024 * 1024 <= args.payload_bytes <= 64 * 1024 * 1024:
        raise ValueError("payload bytes must be between 1 MiB and 64 MiB")

    errors: list[str] = []
    cases: list[dict[str, object]] = []
    case_functions = (
        durable_replacement_case,
        stage_enospc_case,
        manifest_enospc_case,
    )
    for operation in case_functions:
        try:
            cases.append(
                operation(
                    binary,
                    args.image_size_megabytes,
                    args.payload_bytes,
                )
            )
        except Exception as error:
            errors.append(f"{operation.__name__}: {error}")

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-REAL-FULL-VOLUME-MATRIX-V1",
        "status": "failed" if errors else "passed",
        "binarySHA256": sha256(binary),
        "hostPlatform": platform.platform(),
        "caseCount": len(cases),
        "expectedCaseCount": len(case_functions),
        "imageSizeMegabytes": args.image_size_megabytes,
        "payloadBytes": args.payload_bytes,
        "realMountedFilesystemENOSPCClaim": len(cases) == len(case_functions) and not errors,
        "sparseDiskImage": True,
        "quotaExhaustionClaim": False,
        "physicalDeviceQualification": False,
        "powerLossClaim": False,
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic real full-volume matrix: "
        f"cases={len(cases)}/{len(case_functions)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
