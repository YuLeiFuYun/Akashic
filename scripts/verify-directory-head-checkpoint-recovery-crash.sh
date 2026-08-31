#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicCrashProbe -Xswiftc -warnings-as-errors >/dev/null
BIN_DIR=$(xcrun swift build -c release --show-bin-path)
python3 Tools/Crash/verify_directory_head_checkpoint_recovery_crash.py \
    --binary "$BIN_DIR/AkashicCrashProbe" \
    --output .build/directory-head-checkpoint-recovery-crash.json
