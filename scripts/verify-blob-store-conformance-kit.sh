#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

python3 ConformanceKits/BlobStore/v1/run.py \
    --backend-package-path "$ROOT/Fixtures/BlobStoreConformance" \
    --backend-product AkashicBlobStoreConformanceFixture \
    --factory-source Fixtures/BlobStoreConformance/ConformanceFactory.swift
