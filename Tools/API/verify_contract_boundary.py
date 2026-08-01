#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "API/PublicAPI.json"
FORBIDDEN = re.compile(
    r"Fovea|ImageCraft|OriginalEncoded|contentID|namespace|URLSession|ETag|Vary|RenderKey|DecodeKey",
    re.IGNORECASE,
)
REQUIRED = {
    "AkashicCore": {
        "BlobDigest",
        "CachePartitionID",
        "PhysicalBlobID",
        "StoreGenerationID",
        "BlobStage",
        "BlobPublication",
        "LiveBlobReference",
        "BlobStoring",
        "TransactionalBlobStoring",
        "BlobStoreMaintaining",
        "StoreGenerationManaging",
    },
    "AkashicMemory": {
        "MemoryCache",
        "MemoryCacheRemovalSummary",
    },
    "AkashicDisk": {
        "FileBlobStore",
        "FileBlobStoreLimits",
        "StoreGenerationHandle",
        "StoreGenerationDirectory",
        "DirectoryStoreGenerationManager",
    },
}


def main() -> int:
    document = json.loads(BASELINE.read_text())
    errors: list[str] = []
    modules = {module["module"]: module for module in document.get("modules", [])}

    if set(modules) != set(REQUIRED):
        errors.append(
            f"module set drifted: expected={sorted(REQUIRED)} actual={sorted(modules)}"
        )

    for module_name, required_paths in REQUIRED.items():
        module = modules.get(module_name)
        if module is None:
            continue
        paths = {symbol["path"] for symbol in module.get("symbols", [])}
        root_paths = {path.split(".", 1)[0] for path in paths}
        missing = required_paths - root_paths
        if missing:
            errors.append(f"{module_name}: missing required public symbols {sorted(missing)}")

        for symbol in module.get("symbols", []):
            surface = f"{symbol.get('path', '')} {symbol.get('declaration', '')}"
            match = FORBIDDEN.search(surface)
            if match:
                errors.append(
                    f"{module_name}: forbidden public vocabulary {match.group(0)!r} in {surface}"
                )

    core_symbols = modules.get("AkashicCore", {}).get("symbols", [])
    partition_initializers = [
        symbol.get("declaration", "")
        for symbol in core_symbols
        if symbol.get("path", "").startswith("CachePartitionID.init")
    ]
    for declaration in partition_initializers:
        if "String" in declaration:
            errors.append(
                "CachePartitionID must not expose a public String initializer: "
                f"{declaration}"
            )

    disk_symbols = modules.get("AkashicDisk", {}).get("symbols", [])
    for symbol in disk_symbols:
        path = symbol.get("path", "")
        declaration = symbol.get("declaration", "")
        if any(
            path.startswith(prefix)
            for prefix in (
                "FileBlobStore.read(",
                "FileBlobStore.commit(",
                "FileBlobStore.stage(",
                "FileBlobStore.physicalID(",
                "FileBlobStore.remove(",
            )
        ):
            if "BlobDigest" not in declaration or "CachePartitionID" not in declaration:
                errors.append(
                    f"typed disk identity missing from {path}: {declaration}"
                )

    print(
        "Akashic public contract boundary: "
        f"modules={len(modules)} symbols="
        f"{sum(module.get('symbolCount', 0) for module in modules.values())} "
        f"errors={len(errors)}"
    )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
