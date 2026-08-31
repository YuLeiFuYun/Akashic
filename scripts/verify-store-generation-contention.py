#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / ".artifacts/store-generation/contention.json"
PARTICIPANTS = 12
FINGERPRINT = "akashic-store-contention-v1"
ENV = os.environ.copy()


def run(command: list[str], timeout: int = 180) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
        env=ENV,
    )


def main() -> int:
    identity_before_path = ROOT / ".build/store-generation-source-identity-before.json"
    identity_after_path = ROOT / ".build/store-generation-source-identity-after.json"
    identity_before = run([
        "python3",
        "Tools/Identity/capture_source_identity.py",
        "--output",
        str(identity_before_path),
    ])
    if identity_before.returncode != 0:
        print(identity_before.stdout)
        print(identity_before.stderr)
        return identity_before.returncode
    source_identity = json.loads(identity_before_path.read_text())

    build = run(["xcrun", "swift", "build", "--product", "AkashicCrashProbe"])
    if build.returncode != 0:
        print(build.stdout)
        print(build.stderr)
        return build.returncode

    bin_path = run(["xcrun", "swift", "build", "--show-bin-path"])
    if bin_path.returncode != 0:
        print(bin_path.stdout)
        print(bin_path.stderr)
        return bin_path.returncode
    probe = Path(bin_path.stdout.strip()) / "AkashicCrashProbe"
    if not probe.is_file():
        print(f"probe binary missing: {probe}")
        return 1

    temporary = Path(tempfile.mkdtemp(prefix="akashic-store-contention-"))
    try:
        root = temporary / "generation"
        processes = [
            subprocess.Popen(
                [str(probe), "generation", str(root), FINGERPRINT, "75"],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=ENV,
            )
            for _ in range(PARTICIPANTS)
        ]
        identifiers: list[str] = []
        errors: list[str] = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=30)
            if process.returncode != 0:
                errors.append(f"exit={process.returncode} stderr={stderr.strip()}")
            elif stdout.strip():
                identifiers.append(stdout.strip())
            else:
                errors.append("probe returned an empty identifier")

        unique = sorted(set(identifiers))
        identity_after = run([
            "python3",
            "Tools/Identity/capture_source_identity.py",
            "--output",
            str(identity_after_path),
            "--compare",
            str(identity_before_path),
        ])
        if identity_after.returncode != 0:
            errors.append("source identity changed during store-generation contention campaign")
        passed = not errors and len(identifiers) == PARTICIPANTS and len(unique) == 1
        head = run(["git", "rev-parse", "HEAD"])
        report = {
            "schemaVersion": 2,
            "verifiedCommit": head.stdout.strip(),
            "sourceIdentitySHA256": source_identity["sourceIdentitySHA256"],
            "sourceIdentityFileCount": source_identity["fileCount"],
            "sourceIdentityStableAcrossCampaign": identity_after.returncode == 0,
            "participants": PARTICIPANTS,
            "successfulParticipants": len(identifiers),
            "uniqueGenerationIdentifiers": unique,
            "errors": errors,
            "status": "passed" if passed else "failed",
        }
        ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
        ARTIFACT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(
            f"Akashic store generation contention {report['status']}: "
            f"participants={len(identifiers)}/{PARTICIPANTS} unique={len(unique)}"
        )
        print(f"Artifact: {ARTIFACT.relative_to(ROOT)}")
        return 0 if passed else 1
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
