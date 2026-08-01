#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicCrashProbe -Xswiftc -warnings-as-errors
BIN_DIR=$(xcrun swift build -c release --show-bin-path)
python3 Tools/Fault/verify_real_full_volume.py \
    --binary "$BIN_DIR/AkashicCrashProbe" \
    --output .build/real-full-volume-matrix.json
