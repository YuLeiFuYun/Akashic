#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
OUT=${1:-.build/segmented-manifest-epoch-process-crash.json}
mkdir -p "$(dirname -- "$OUT")"
xcrun swift build -c release --product AkashicResourceProbe -Xswiftc -warnings-as-errors >/dev/null
BIN_DIR=$(xcrun swift build -c release --show-bin-path)
python3 Tools/Crash/verify_segmented_manifest_epoch_process_crash.py \
    --binary "$BIN_DIR/AkashicResourceProbe" \
    --output "$OUT"
