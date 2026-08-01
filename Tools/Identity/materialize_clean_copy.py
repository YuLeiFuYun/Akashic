#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()

    source_root = args.source_root.resolve()
    destination = args.destination.resolve()
    document = json.loads(args.identity.read_text())
    if document.get("identityID") != "AKASHIC-SOURCE-IDENTITY-V1":
        raise ValueError("unexpected identity document")
    if destination.exists():
        raise FileExistsError(destination)
    destination.mkdir(parents=True)

    for entry in document.get("files", []):
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"unsafe identity path: {relative}")
        source = source_root / relative
        target = destination / relative
        if not source.is_file():
            raise FileNotFoundError(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    print(
        "Akashic clean copy materialized: "
        f"files={document.get('fileCount')} destination={destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
