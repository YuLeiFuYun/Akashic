#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicCrashProbe -Xswiftc -warnings-as-errors
python3 Tools/Fault/verify_real_quota.py \
    --binary "$ROOT/.build/out/Products/Release/AkashicCrashProbe" \
    --output .build/real-apfs-quota-matrix.json
