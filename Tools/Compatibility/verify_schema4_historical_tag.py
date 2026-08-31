#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

CRASH_EXIT = 91


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=check,
    )


def git(root: Path, *args: str) -> str:
    return run(["git", *args], cwd=root).stdout.strip()


def extract_tag(root: Path, tag: str, destination: Path) -> None:
    archive = subprocess.Popen(
        ["git", "archive", "--format=tar", tag],
        cwd=root,
        stdout=subprocess.PIPE,
    )
    assert archive.stdout is not None
    unpack = subprocess.run(
        ["tar", "-xf", "-", "-C", str(destination)],
        stdin=archive.stdout,
        check=False,
    )
    archive.stdout.close()
    archive_code = archive.wait()
    if archive_code != 0 or unpack.returncode != 0:
        raise RuntimeError(
            f"tag archive failed: git={archive_code} tar={unpack.returncode}"
        )


def inspect(binary: Path, store: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), "inspect", str(store)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def require_hit(observation: subprocess.CompletedProcess[str], context: str) -> dict[str, object]:
    if observation.returncode != 0:
        raise RuntimeError(f"{context} inspect exit={observation.returncode}")
    decoded = json.loads(observation.stdout)
    if decoded.get("disposition") != "hit":
        raise RuntimeError(f"{context} reader did not recover committed schema4 hit")
    return decoded


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    current_binary = args.binary.resolve()
    if not current_binary.is_file():
        raise FileNotFoundError(current_binary)

    tag_type = git(root, "cat-file", "-t", args.tag)
    if tag_type != "tag":
        raise RuntimeError(f"historical reference must be an annotated tag: {args.tag}")
    tag_object = git(root, "rev-parse", args.tag)
    tag_commit = git(root, "rev-parse", f"{args.tag}^{{commit}}")
    tag_tree = git(root, "rev-parse", f"{args.tag}^{{tree}}")

    developer_dir = run([str(root / "scripts/select-xcode.sh")], cwd=root).stdout.strip()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = developer_dir
    swift_version = run(["/usr/bin/xcrun", "swift", "--version"], cwd=root, env=env).stdout.strip()

    with tempfile.TemporaryDirectory(prefix="akashic-historical-downgrade-") as temporary:
        workspace = Path(temporary)
        historical_source = workspace / "historical"
        store = workspace / "store"
        historical_source.mkdir()
        extract_tag(root, args.tag, historical_source)

        build = subprocess.run(
            [
                "/usr/bin/xcrun",
                "swift",
                "build",
                "--package-path",
                str(historical_source),
                "-c",
                "release",
                "--product",
                "AkashicCrashProbe",
            ],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if build.returncode != 0:
            raise RuntimeError(
                "historical tagged source did not build unmodified:\n"
                + build.stdout
                + build.stderr
            )
        bin_path = run(
            [
                "/usr/bin/xcrun",
                "swift",
                "build",
                "--package-path",
                str(historical_source),
                "-c",
                "release",
                "--show-bin-path",
            ],
            cwd=root,
            env=env,
        ).stdout.strip()
        historical_binary = Path(bin_path) / "AkashicCrashProbe"
        if not historical_binary.is_file():
            raise FileNotFoundError(historical_binary)

        seed = subprocess.run(
            [str(current_binary), "directory-head-seed", str(store)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if seed.returncode != 0:
            raise RuntimeError(f"schema4 seed failed: {seed.returncode}\n{seed.stderr}")
        crash = subprocess.run(
            [
                str(current_binary),
                "directory-head-crash",
                str(store),
                "afterDirectorySynced",
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if crash.returncode != CRASH_EXIT:
            raise RuntimeError(f"schema4 commit crash exit={crash.returncode}")

        current_before = require_hit(inspect(current_binary, store, env), "current-before")
        manifest = store / "manifest.json"
        manifest_before = sha256(manifest)

        historical = inspect(historical_binary, store, env)
        historical_rejected = (
            historical.returncode != 0 and "unsupportedSchema" in historical.stderr
        )
        if not historical_rejected:
            raise RuntimeError(
                "historical tagged-source reader did not fail closed on schema4: "
                f"exit={historical.returncode} stderr={historical.stderr!r}"
            )
        manifest_after = sha256(manifest)
        if manifest_after != manifest_before:
            raise RuntimeError("historical inspect mutated manifest.json bytes")

        current_after = require_hit(inspect(current_binary, store, env), "current-after")
        result = {
            "schemaVersion": 1,
            "status": "passed",
            "historicalTag": args.tag,
            "historicalTagObject": tag_object,
            "historicalCommit": tag_commit,
            "historicalTree": tag_tree,
            "historicalSourceMode": "exact-git-tag-archive-unmodified",
            "historicalBinaryRebuiltFromTaggedSource": True,
            "originalDistributedBinaryArtifactQualified": False,
            "currentBinarySHA256": sha256(current_binary),
            "historicalBinarySHA256": sha256(historical_binary),
            "historicalInspectExitCode": historical.returncode,
            "historicalInspectRejectedUnsupportedSchema": True,
            "manifestSHA256BeforeHistoricalInspect": manifest_before,
            "manifestSHA256AfterHistoricalInspect": manifest_after,
            "historicalInspectPreservedManifestBytes": True,
            "currentDispositionBeforeHistoricalInspect": current_before.get("disposition"),
            "currentDispositionAfterHistoricalInspect": current_after.get("disposition"),
            "automaticMigrationQualified": False,
            "buildToolchain": " ".join(swift_version.splitlines()),
        }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic historical schema4 downgrade control: "
        f"tag={args.tag} status=passed taggedSourceRebuild=true "
        "distributedBinaryQualified=false automaticMigrationQualified=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
