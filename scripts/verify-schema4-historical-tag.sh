#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicCrashProbe -Xswiftc -warnings-as-errors >/dev/null
BIN_DIR=$(xcrun swift build -c release --show-bin-path)
python3 Tools/Compatibility/verify_schema4_historical_tag.py \
    --binary "$BIN_DIR/AkashicCrashProbe" \
    --tag 0.1.0-alpha.5 \
    --output .build/schema4-historical-tag-downgrade.json
