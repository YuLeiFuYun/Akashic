#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

EXCLUDED = {".git", ".build", ".artifacts", ".swiftpm", "__pycache__", ".DS_Store"}
CRASH_EXIT = 91


def ignored(_path: str, names: list[str]) -> list[str]:
    return [name for name in names if name in EXCLUDED]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv: list[str], *, cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=check)


def make_schema3_control(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination, ignore=ignored)
    target = destination / "Sources/AkashicDisk/FileBlobStoreBootstrapManifest.swift"
    text = target.read_text()
    old = """        switch schemaVersion {\n        case Self.segmentedManifestSchemaVersion:\n            try bootstrapSegmentedManifest(observer: observer)\n        case Self.legacyManifestSchemaVersion,\n            Self.currentSchemaVersion,\n            Self.directoryHeadManifestSchemaVersion:\n            try bootstrapLegacyOrDirectoryHeadManifest(\n                data: data,\n                schemaVersion: schemaVersion,\n                observer: observer\n            )\n        default:\n            throw AkashicError.unsupportedSchema\n        }\n"""
    new = """        switch schemaVersion {\n        case Self.legacyManifestSchemaVersion, Self.currentSchemaVersion:\n            try bootstrapLegacyOrDirectoryHeadManifest(\n                data: data,\n                schemaVersion: schemaVersion,\n                observer: observer\n            )\n        default:\n            throw AkashicError.unsupportedSchema\n        }\n"""
    if text.count(old) != 1:
        raise RuntimeError("schema3 bootstrap acceptance switch not found exactly once")
    target.write_text(text.replace(old, new, 1))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    current_binary = args.binary.resolve()
    if not current_binary.is_file():
        raise FileNotFoundError(current_binary)

    developer_dir = run([str(root / "scripts/select-xcode.sh")], cwd=root).stdout.strip()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = developer_dir

    with tempfile.TemporaryDirectory(prefix="akashic-schema3-control-") as temporary:
        workspace = Path(temporary)
        control = workspace / "control"
        store = workspace / "store"
        make_schema3_control(root, control)

        subprocess.run(
            [
                "/usr/bin/xcrun",
                "swift",
                "build",
                "--package-path",
                str(control),
                "-c",
                "release",
                "--product",
                "AkashicCrashProbe",
                "-Xswiftc",
                "-warnings-as-errors",
            ],
            cwd=root,
            env=env,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        control_bin_dir = subprocess.run(
            [
                "/usr/bin/xcrun",
                "swift",
                "build",
                "--package-path",
                str(control),
                "-c",
                "release",
                "--show-bin-path",
            ],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        control_binary = Path(control_bin_dir) / "AkashicCrashProbe"

        seeded = subprocess.run(
            [str(current_binary), "directory-head-seed", str(store)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if seeded.returncode != 0:
            raise RuntimeError(f"schema4 seed failed: {seeded.returncode}")
        crashed = subprocess.run(
            [str(current_binary), "directory-head-crash", str(store), "afterDirectorySynced"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if crashed.returncode != CRASH_EXIT:
            raise RuntimeError(f"schema4 commit crash exit={crashed.returncode}")

        current_inspect = subprocess.run(
            [str(current_binary), "inspect", str(store)],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        )
        current_observation = json.loads(current_inspect.stdout)
        if current_observation.get("disposition") != "hit":
            raise RuntimeError("current reader did not recover committed schema4 hit")

        control_inspect = subprocess.run(
            [str(control_binary), "inspect", str(store)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        downgrade_fail_closed = (
            control_inspect.returncode != 0
            and "unsupportedSchema" in control_inspect.stderr
        )
        if not downgrade_fail_closed:
            raise RuntimeError("schema3-control reader did not fail closed on schema4")

        result = {
            "schemaVersion": 1,
            "status": "passed",
            "currentBinarySHA256": sha256(current_binary),
            "schema3ControlBinarySHA256": sha256(control_binary),
            "currentDisposition": current_observation.get("disposition"),
            "schema3ControlExitCode": control_inspect.returncode,
            "downgradeFailClosed": True,
            "historicalBinaryIdentity": False,
            "automaticMigrationQualified": False,
        }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic schema4 downgrade control: "
        f"status={result['status']} historicalBinaryIdentity=false automaticMigrationQualified=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
