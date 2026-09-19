#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RECEIPT = ROOT / "docs/evidence/FOVEA_AKASHIC_HOST_CONFORMANCE_V1.json"
REQUIRED = {
    "AKASHIC-CT-022",
    "AKASHIC-CT-023",
    "AKASHIC-CT-024",
    "AKASHIC-CT-025",
    "AKASHIC-CT-026",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv: list[str], cwd: Path, env: dict[str, str] | None = None) -> str:
    return subprocess.run(
        argv, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=True,
    ).stdout.strip()


def working_tree_identity(root: Path) -> str:
    env = dict(os.environ)
    top = Path(command(["git", "rev-parse", "--show-toplevel"], root, env)).resolve()
    with tempfile.TemporaryDirectory(prefix="akashic-fovea-receipt-index-") as temp:
        git_env = dict(env)
        git_env["GIT_INDEX_FILE"] = str(Path(temp) / "index")
        subprocess.run(["git", "read-tree", "HEAD"], cwd=top, env=git_env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(["git", "add", "-A", "--", "."], cwd=top, env=git_env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return command(["git", "write-tree"], top, git_env)


def validate_receipt(receipt_path: Path, fovea_root: Path | None = None) -> list[str]:
    errors: list[str] = []
    try:
        value = json.loads(receipt_path.read_text())
    except Exception as error:
        return [f"cannot read Fovea host receipt: {error}"]

    if value.get("schemaVersion") != 1:
        errors.append("unexpected Fovea host receipt schemaVersion")
    if value.get("reportID") != "FOVEA-AKASHIC-HOST-CONFORMANCE-V1":
        errors.append("unexpected Fovea host receipt reportID")
    if value.get("status") != "passed" or value.get("errors") != []:
        errors.append("Fovea host receipt is not a clean pass")
    if value.get("host") != "Fovea" or value.get("component") != "Akashic":
        errors.append("Fovea host receipt host/component identity drift")
    claims = value.get("claims", {})
    for claim in ("hostSemanticConformance", "sourceBound", "exactComponentPin"):
        if claims.get(claim) is not True:
            errors.append(f"Fovea host receipt claim {claim} must be true")
    if claims.get("releaseQualified") is not False:
        errors.append("Fovea host receipt must not claim protected-release qualification")
    if claims.get("physicalDeviceQualification") is not False:
        errors.append("Fovea host receipt must not claim physical-device qualification")

    tag = str(value.get("componentReleaseTag") or "")
    revision = str(value.get("componentRevision") or "")
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", tag) is None:
        errors.append("Fovea receipt component release tag is missing or invalid")
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        errors.append("Fovea receipt component revision is missing or invalid")
    # Source-identity clean copies intentionally contain no Git metadata.  In a
    # real checkout, resolve the historical tag and bind it to the receipt; in
    # a Git-free clean copy, retain the receipt's explicit tag/revision format
    # checks and package-resolved binding without inventing repository state.
    if (ROOT / ".git").exists() and tag:
        try:
            tagged_revision = command(
                ["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], ROOT
            )
        except subprocess.CalledProcessError:
            tagged_revision = ""
            errors.append(f"cannot resolve Akashic receipt release tag {tag}")
        if tagged_revision and revision != tagged_revision:
            errors.append(f"Fovea receipt component revision does not match local {tag} tag")
    if value.get("packageResolvedRevision") != revision:
        errors.append("Fovea receipt Package.resolved revision differs from component revision")

    tree = str(value.get("hostVerifiedTree") or "")
    if re.fullmatch(r"[0-9a-f]{40}", tree) is None:
        errors.append("Fovea receipt hostVerifiedTree is not a Git tree digest")

    obligations = value.get("obligations")
    if not isinstance(obligations, list):
        errors.append("Fovea receipt obligations must be a list")
        obligations = []
    ids = {str(item.get("obligation")) for item in obligations if isinstance(item, dict)}
    if ids != REQUIRED or len(obligations) != len(REQUIRED):
        errors.append(f"Fovea receipt obligation set drift: {sorted(ids)}")
    for item in obligations:
        if not isinstance(item, dict):
            continue
        identifier = str(item.get("obligation") or "")
        if item.get("passed") is not True:
            errors.append(f"{identifier}: host semantic test did not pass")
        if not item.get("test") or not item.get("source"):
            errors.append(f"{identifier}: host test/source binding missing")
        if re.fullmatch(r"[0-9a-f]{64}", str(item.get("sourceSHA256") or "")) is None:
            errors.append(f"{identifier}: source SHA-256 missing or invalid")

    if fovea_root is not None:
        host_report = fovea_root / ".artifacts/conformance/akashic-host-v1/report.json"
        if not host_report.is_file():
            errors.append("live Fovea checkout is missing its host-owned receipt")
        elif sha256(host_report) != sha256(receipt_path):
            errors.append("Akashic receipt mirror differs from the live Fovea host-owned receipt")
        for item in obligations:
            if not isinstance(item, dict):
                continue
            source = fovea_root / str(item.get("source") or "")
            if not source.is_file():
                errors.append(f"{item.get('obligation')}: live Fovea source is missing")
            elif sha256(source) != item.get("sourceSHA256"):
                errors.append(f"{item.get('obligation')}: live Fovea source digest drift")
        try:
            live_tree = working_tree_identity(fovea_root)
        except Exception as error:
            errors.append(f"cannot recompute live Fovea working-tree identity: {error}")
        else:
            if live_tree != tree:
                errors.append("live Fovea working-tree identity differs from receipt")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, default=DEFAULT_RECEIPT)
    parser.add_argument("--fovea-root", type=Path)
    args = parser.parse_args()
    errors = validate_receipt(args.receipt.resolve(), args.fovea_root.resolve() if args.fovea_root else None)
    print(f"Fovea host receipt verification: obligations={len(REQUIRED)} errors={len(errors)}")
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
