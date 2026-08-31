#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
python3 scripts/check-swift-toolchain.py
xcrun swift build -c release --product AkashicResourceProbe >/dev/null
python3 Tools/Resource/capture_filesystem_io_ledger.py \
    --output .build/filesystem-io-ledger.json \
    --repetitions 3
