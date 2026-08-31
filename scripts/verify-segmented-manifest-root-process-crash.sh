#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicResourceProbe -Xswiftc -warnings-as-errors >/dev/null
BIN_DIR=$(xcrun swift build -c release --show-bin-path)
python3 Tools/Crash/verify_segmented_manifest_root_process_crash.py \
    --binary "$BIN_DIR/AkashicResourceProbe" \
    --output .build/segmented-manifest-root-process-crash-matrix.json
