#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

from verify_real_full_volume import (
    ENOSPC,
    available_bytes,
    calibrate_available_space,
    expect_enospc,
    expect_recovered_store,
    fill_to_enospc,
    filesystem_type,
    parse_probe_output,
    probe,
    read_line_with_timeout,
    run,
    sha256,
    temporary_files,
    total_bytes,
)


def process_exists(process_id: int) -> bool:
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def cleanup_stale_quota_images() -> int:
    completed = subprocess.run(
        ["hdiutil", "info", "-plist"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"hdiutil info failed ({completed.returncode}): "
            f"{completed.stderr.decode(errors='replace')[-1000:]}"
        )
    document = plistlib.loads(completed.stdout)
    images = document.get("images", [])
    cleaned = 0
    for image in images:
        if not isinstance(image, dict):
            continue
        entities = image.get("system-entities", [])
        mounts = [
            str(entity.get("mount-point"))
            for entity in entities
            if isinstance(entity, dict) and entity.get("mount-point")
        ]
        relevant = [
            mount
            for mount in mounts
            if Path(mount).name.startswith("AkashicBase-")
            or Path(mount).name.startswith("AkashicQuota-")
        ]
        if not relevant:
            continue
        process_ids = {
            int(match.group(1))
            for mount in relevant
            if (match := re.search(r"-(\d+)$", Path(mount).name)) is not None
        }
        if not process_ids or any(process_exists(process_id) for process_id in process_ids):
            continue
        for mount in relevant:
            if Path(mount).name.startswith("AkashicQuota-"):
                run(["diskutil", "unmount", "force", mount], check=False)
        base_mount = next(
            (mount for mount in relevant if Path(mount).name.startswith("AkashicBase-")),
            None,
        )
        if base_mount is not None:
            detached = run(["hdiutil", "detach", base_mount, "-force"], check=False)
            if detached.returncode != 0:
                raise RuntimeError(
                    f"unable to detach stale quota image at {base_mount}: "
                    f"{detached.stderr[-1000:]}"
                )
            cleaned += 1
    return cleaned


def plist_command(command: list[str]) -> dict[str, object]:
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"stderr={completed.stderr.decode(errors='replace')[-1000:]}"
        )
    value = plistlib.loads(completed.stdout)
    if not isinstance(value, dict):
        raise RuntimeError(f"plist command returned a non-object: {' '.join(command)}")
    return value


def apfs_container(document: dict[str, object]) -> dict[str, object]:
    containers = document.get("Containers")
    if not isinstance(containers, list) or len(containers) != 1:
        raise RuntimeError("diskutil did not report exactly one APFS container")
    container = containers[0]
    if not isinstance(container, dict):
        raise RuntimeError("APFS container entry is not an object")
    return container


def quota_volume_state(
    container_reference: str,
    volume_name: str,
) -> tuple[dict[str, object], dict[str, object]]:
    container = apfs_container(
        plist_command(["diskutil", "apfs", "list", "-plist", container_reference])
    )
    volumes = container.get("Volumes")
    if not isinstance(volumes, list):
        raise RuntimeError("APFS container did not report volumes")
    matches = [
        volume
        for volume in volumes
        if isinstance(volume, dict) and volume.get("Name") == volume_name
    ]
    if len(matches) != 1:
        raise RuntimeError(f"expected one quota volume named {volume_name!r}")
    return container, matches[0]


def integer_field(document: dict[str, object], key: str) -> int:
    value = document.get(key)
    if not isinstance(value, int) or value < 0:
        raise RuntimeError(f"missing or invalid integer field {key!r}: {value!r}")
    return value


@contextmanager
def mounted_apfs_quota_volume(
    container_size_megabytes: int,
    quota_bytes: int,
    case_name: str,
) -> Iterator[tuple[Path, dict[str, object], str]]:
    temporary = Path(tempfile.mkdtemp(prefix=f"akashic-quota-{case_name}-"))
    image_base = temporary / "container"
    base_name = f"AkashicBase-{case_name[:18]}-{os.getpid()}"
    quota_name = f"AkashicQuota-{case_name[:16]}-{os.getpid()}"
    base_mountpoint: Path | None = None
    quota_mountpoint: Path | None = None
    quota_device: str | None = None
    try:
        create = run(
            [
                "hdiutil",
                "create",
                "-size",
                f"{container_size_megabytes}m",
                "-fs",
                "APFS",
                "-volname",
                base_name,
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

        attach = subprocess.run(
            ["hdiutil", "attach", "-plist", "-nobrowse", str(image)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if attach.returncode != 0:
            raise RuntimeError(
                f"hdiutil attach failed ({attach.returncode}): "
                f"{attach.stderr.decode(errors='replace')[-1000:]}"
            )
        attach_document = plistlib.loads(attach.stdout)
        entities = attach_document.get("system-entities", [])
        mounted_entities = [
            entity
            for entity in entities
            if isinstance(entity, dict) and isinstance(entity.get("mount-point"), str)
        ]
        if len(mounted_entities) != 1:
            raise RuntimeError("disk image did not expose exactly one mounted base volume")
        base_entity = mounted_entities[0]
        base_mountpoint = Path(str(base_entity["mount-point"]))
        base_device = str(base_entity.get("dev-entry", ""))
        if not base_device:
            raise RuntimeError("base APFS volume did not expose a device")
        base_info = plist_command(["diskutil", "info", "-plist", base_device])
        container_reference = base_info.get("APFSContainerReference")
        if not isinstance(container_reference, str) or not container_reference:
            raise RuntimeError("base APFS volume did not expose a container reference")

        run(
            [
                "diskutil",
                "apfs",
                "addVolume",
                container_reference,
                "APFS",
                quota_name,
                "-quota",
                str(quota_bytes),
            ],
            timeout=120,
        )
        container, volume = quota_volume_state(container_reference, quota_name)
        device_identifier = volume.get("DeviceIdentifier")
        if not isinstance(device_identifier, str) or not device_identifier:
            raise RuntimeError("quota APFS volume did not expose a device identifier")
        quota_device = f"/dev/{device_identifier}"
        quota_info = plist_command(["diskutil", "info", "-plist", quota_device])
        mount_value = quota_info.get("MountPoint")
        if not isinstance(mount_value, str) or not mount_value:
            raise RuntimeError("quota APFS volume is not mounted")
        quota_mountpoint = Path(mount_value)
        fs_type = filesystem_type(quota_mountpoint)
        if fs_type.lower() != "apfs":
            raise RuntimeError(f"expected APFS, observed {fs_type!r}")

        observed_quota = integer_field(volume, "CapacityQuota")
        if observed_quota != quota_bytes:
            raise RuntimeError(
                f"quota mismatch: requested={quota_bytes} observed={observed_quota}"
            )
        metadata: dict[str, object] = {
            "filesystem": fs_type,
            "imageType": "sparse-disk-image",
            "requestedContainerBytes": container_size_megabytes * 1024 * 1024,
            "containerCapacityBytes": integer_field(container, "CapacityCeiling"),
            "containerFreeBytesAtMount": integer_field(container, "CapacityFree"),
            "quotaBytes": observed_quota,
            "mountedQuotaVolumeBytes": total_bytes(quota_mountpoint),
        }
        yield quota_mountpoint, metadata, container_reference
    finally:
        if quota_device is not None:
            run(["diskutil", "unmount", "force", quota_device], check=False)
        if base_mountpoint is not None:
            detached = run(
                ["hdiutil", "detach", str(base_mountpoint), "-force"],
                check=False,
            )
            if detached.returncode != 0:
                run(["diskutil", "unmount", "force", str(base_mountpoint)], check=False)
                detached = run(
                    ["hdiutil", "detach", str(base_mountpoint), "-force"],
                    check=False,
                )
            if detached.returncode != 0:
                print(
                    f"warning: unable to detach quota image at {base_mountpoint}: "
                    f"{detached.stderr[-1000:]}",
                    file=sys.stderr,
                )
        shutil.rmtree(temporary, ignore_errors=True)




def container_free_bytes(container_reference: str) -> int:
    container = apfs_container(
        plist_command(["diskutil", "apfs", "list", "-plist", container_reference])
    )
    return integer_field(container, "CapacityFree")


def assert_quota_specific(
    mountpoint: Path,
    container_reference: str,
    payload_bytes: int,
) -> tuple[int, int]:
    quota_available = available_bytes(mountpoint)
    container_available = container_free_bytes(container_reference)
    if quota_available >= payload_bytes:
        raise RuntimeError(
            f"quota volume still has {quota_available} bytes, not below payload {payload_bytes}"
        )
    if container_available < payload_bytes * 8:
        raise RuntimeError(
            "container free space is too small to distinguish quota exhaustion from full volume: "
            f"container={container_available} payload={payload_bytes}"
        )
    return quota_available, container_available


def durable_quota_case(
    binary: Path,
    container_size_megabytes: int,
    quota_bytes: int,
    payload_bytes: int,
) -> dict[str, object]:
    with mounted_apfs_quota_volume(
        container_size_megabytes, quota_bytes, "durable"
    ) as (mountpoint, metadata, container_reference):
        root = mountpoint / "durable"
        root.mkdir(mode=0o700)
        destination = root / "state.bin"
        old = b"old-quota-durable-state-v1"
        destination.write_bytes(old)
        os.chmod(destination, 0o600)
        filler = mountpoint / "filler.bin"
        filled_bytes, observed_errno = fill_to_enospc(filler)
        calibrate_available_space(filler, mountpoint, filled_bytes, 4 * 1024 * 1024)
        quota_available, container_available = assert_quota_specific(
            mountpoint, container_reference, payload_bytes
        )
        result = probe(binary, "full-volume-durable", root, payload_bytes)
        expect_enospc(result, "quota durable replacement")
        if destination.read_bytes() != old:
            raise RuntimeError("quota failure changed the old durable destination")
        leftovers = temporary_files(root)
        if leftovers:
            raise RuntimeError(f"quota durable replacement left temporary files: {leftovers}")
        return {
            "caseID": "real-apfs-quota-durable-replacement-enospc",
            **metadata,
            "filledBytes": filled_bytes,
            "quotaAvailableBytesBeforeOperation": quota_available,
            "containerFreeBytesBeforeOperation": container_available,
            "kernelErrno": observed_errno,
            "probe": result,
            "oldDestinationPreserved": True,
            "temporaryCount": 0,
            "status": "passed",
        }


def stage_quota_case(
    binary: Path,
    container_size_megabytes: int,
    quota_bytes: int,
    payload_bytes: int,
) -> dict[str, object]:
    with mounted_apfs_quota_volume(
        container_size_megabytes, quota_bytes, "stage"
    ) as (mountpoint, metadata, container_reference):
        root = mountpoint / "store"
        seed = probe(binary, "full-volume-seed", root)
        if seed.get("status") != "seeded":
            raise RuntimeError(f"unable to seed quota store: {seed}")
        filler = mountpoint / "filler.bin"
        filled_bytes, observed_errno = fill_to_enospc(filler)
        calibrate_available_space(filler, mountpoint, filled_bytes, 4 * 1024 * 1024)
        quota_available, container_available = assert_quota_specific(
            mountpoint, container_reference, payload_bytes
        )
        attempted = probe(binary, "full-volume-commit", root, payload_bytes)
        expect_enospc(attempted, "quota blob stage")
        filler.unlink()
        recovered = probe(binary, "full-volume-inspect", root, payload_bytes)
        expect_recovered_store(recovered)
        return {
            "caseID": "real-apfs-quota-blob-stage-enospc",
            **metadata,
            "filledBytes": filled_bytes,
            "quotaAvailableBytesBeforeOperation": quota_available,
            "containerFreeBytesBeforeOperation": container_available,
            "kernelErrno": observed_errno,
            "probe": attempted,
            "recovered": recovered,
            "status": "passed",
        }


def expect_quota_manifest_failure(result: dict[str, object]) -> str:
    if result.get("status") != "failed":
        raise RuntimeError(f"quota manifest publication unexpectedly succeeded: {result}")
    if result.get("errno") == ENOSPC:
        if (
            result.get("errorType") != "POSIXError"
            and result.get("underlyingPOSIXError") is not True
        ):
            raise RuntimeError(
                f"quota manifest ENOSPC did not preserve the POSIX error chain: {result}"
            )
        return "kernel-enospc"
    if (
        result.get("errorDomain") == "NSCocoaErrorDomain"
        and result.get("errorCode") == 512
        and "errno" not in result
    ):
        return "foundation-metadata-prewrite-failure"
    raise RuntimeError(f"unexpected quota manifest failure surface: {result}")


def manifest_quota_case(
    binary: Path,
    container_size_megabytes: int,
    quota_bytes: int,
    payload_bytes: int,
) -> dict[str, object]:
    with mounted_apfs_quota_volume(
        container_size_megabytes, quota_bytes, "manifest"
    ) as (mountpoint, metadata, container_reference):
        root = mountpoint / "store"
        seed = probe(binary, "full-volume-seed", root)
        if seed.get("status") != "seeded":
            raise RuntimeError(f"unable to seed quota store: {seed}")
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
                f"quota probe did not reach staged boundary: line={staged!r} "
                f"stderr={stderr.decode(errors='replace')[-1000:]}"
            )
        filler = mountpoint / "filler.bin"
        filled_bytes, observed_errno = fill_to_enospc(filler)
        quota_available, container_available = assert_quota_specific(
            mountpoint, container_reference, payload_bytes
        )
        assert process.stdin is not None
        process.stdin.write(b"x")
        process.stdin.flush()
        process.stdin.close()
        process.stdin = None
        stdout, stderr = process.communicate(timeout=120)
        attempted = parse_probe_output(
            subprocess.CompletedProcess(
                args=process.args,
                returncode=process.returncode,
                stdout=stdout.decode(errors="replace"),
                stderr=stderr.decode(errors="replace"),
            )
        )
        failure_surface = expect_quota_manifest_failure(attempted)
        filler.unlink()
        recovered = probe(binary, "full-volume-inspect", root, payload_bytes)
        expect_recovered_store(recovered)
        return {
            "caseID": "real-apfs-quota-manifest-publication-failure",
            **metadata,
            "filledBytes": filled_bytes,
            "quotaAvailableBytesBeforeOperation": quota_available,
            "containerFreeBytesBeforeOperation": container_available,
            "kernelErrnoDuringFill": observed_errno,
            "publicationFailureSurface": failure_surface,
            "probe": attempted,
            "recovered": recovered,
            "status": "passed",
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--container-size-megabytes", type=int, default=1024)
    parser.add_argument("--quota-bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--payload-bytes", type=int, default=8 * 1024 * 1024)
    args = parser.parse_args()

    if sys.platform != "darwin":
        raise RuntimeError("real APFS quota verification requires Darwin")
    for tool in ("hdiutil", "diskutil"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"required system tool is unavailable: {tool}")

    binary = args.binary.resolve()
    if not binary.is_file():
        raise FileNotFoundError(binary)
    if args.container_size_megabytes < 512:
        raise ValueError("container size must be at least 512 MiB")
    if not 32 * 1024 * 1024 <= args.quota_bytes <= 512 * 1024 * 1024:
        raise ValueError("quota must be between 32 MiB and 512 MiB")
    if not 1024 * 1024 <= args.payload_bytes <= 64 * 1024 * 1024:
        raise ValueError("payload bytes must be between 1 MiB and 64 MiB")
    if args.quota_bytes < args.payload_bytes * 4:
        raise ValueError("quota must be at least four payloads")

    stale_image_cleanup_count = cleanup_stale_quota_images()
    errors: list[str] = []
    cases: list[dict[str, object]] = []
    case_functions = (
        durable_quota_case,
        stage_quota_case,
        manifest_quota_case,
    )
    for operation in case_functions:
        try:
            cases.append(
                operation(
                    binary,
                    args.container_size_megabytes,
                    args.quota_bytes,
                    args.payload_bytes,
                )
            )
        except Exception as error:
            errors.append(f"{operation.__name__}: {error}")

    result = {
        "schemaVersion": 1,
        "matrixID": "AKASHIC-REAL-APFS-QUOTA-MATRIX-V1",
        "status": "failed" if errors else "passed",
        "binarySHA256": sha256(binary),
        "hostPlatform": platform.platform(),
        "caseCount": len(cases),
        "expectedCaseCount": len(case_functions),
        "containerSizeMegabytes": args.container_size_megabytes,
        "quotaBytes": args.quota_bytes,
        "payloadBytes": args.payload_bytes,
        "staleImageCleanupCount": stale_image_cleanup_count,
        "realAPFSQuotaExhaustionClaim": len(cases) == len(case_functions) and not errors,
        "kernelENOSPCCaseCount": sum(
            1
            for case in cases
            if case.get("probe", {}).get("errno") == ENOSPC
        ),
        "foundationMetadataPrewriteFailureCaseCount": sum(
            1
            for case in cases
            if case.get("publicationFailureSurface")
            == "foundation-metadata-prewrite-failure"
        ),
        "wholeContainerFullClaim": False,
        "sparseDiskImage": True,
        "physicalDeviceQualification": False,
        "powerLossClaim": False,
        "cases": cases,
        "errors": errors,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic real APFS quota matrix: "
        f"cases={len(cases)}/{len(case_functions)} errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
