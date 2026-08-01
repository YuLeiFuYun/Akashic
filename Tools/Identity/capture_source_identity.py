#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".build/source-identity.json"
INCLUDED_TOP_LEVEL = {
    ".gitignore",
    "API",
    "Fixtures",
    "LICENSE",
    "Package.swift",
    "README.md",
    "ROADMAP.md",
    "Sources",
    "Tests",
    "Tools",
    "docs",
    "scripts",
}
EXCLUDED_NAMES = {".build", ".git", ".swiftpm", "__pycache__", ".DS_Store"}


def file_digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def included_files() -> list[Path]:
    result: list[Path] = []
    for name in sorted(INCLUDED_TOP_LEVEL):
        path = ROOT / name
        if path.is_file():
            result.append(path)
            continue
        if not path.is_dir():
            raise FileNotFoundError(path)
        for candidate in sorted(path.rglob("*")):
            if not candidate.is_file():
                continue
            if any(part in EXCLUDED_NAMES for part in candidate.relative_to(ROOT).parts):
                continue
            result.append(candidate)
    return result


def canonical_identity(entries: list[dict[str, object]]) -> str:
    payload = json.dumps(
        entries,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def capture() -> dict[str, object]:
    entries = []
    for path in included_files():
        relative = str(path.relative_to(ROOT))
        entries.append(
            {
                "path": relative,
                "byteCount": path.stat().st_size,
                "sha256": file_digest(path),
            }
        )
    entries.sort(key=lambda item: str(item["path"]))
    return {
        "schemaVersion": 1,
        "identityID": "AKASHIC-SOURCE-IDENTITY-V1",
        "fileCount": len(entries),
        "sourceIdentitySHA256": canonical_identity(entries),
        "files": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()

    report = capture()
    if args.compare is not None:
        expected = json.loads(args.compare.read_text())
        expected_identity = expected.get("sourceIdentitySHA256")
        actual_identity = report["sourceIdentitySHA256"]
        if expected_identity != actual_identity:
            print(
                "Akashic source identity mismatch: "
                f"expected={expected_identity} actual={actual_identity}"
            )
            return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(
        "Akashic source identity: "
        f"files={report['fileCount']} sha256={report['sourceIdentitySHA256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
