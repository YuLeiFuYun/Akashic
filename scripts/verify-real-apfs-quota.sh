#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicCrashProbe -Xswiftc -warnings-as-errors
BIN_PATH=$(xcrun swift build -c release --show-bin-path)
PROBE="$BIN_PATH/AkashicCrashProbe"
test -x "$PROBE"
python3 Tools/Fault/verify_real_quota.py \
    --binary "$PROBE" \
    --output .build/real-apfs-quota-matrix.json
