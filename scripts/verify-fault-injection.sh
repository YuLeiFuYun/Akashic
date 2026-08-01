#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
ARTIFACT_ROOT=.build/fault-injection
mkdir -p "$ARTIFACT_ROOT"

xcrun swift test --filter DurableFileWriterFaultTests -Xswiftc -warnings-as-errors \
    >"$ARTIFACT_ROOT/durable-file-writer-tests.log" 2>&1
cat "$ARTIFACT_ROOT/durable-file-writer-tests.log"
xcrun swift test --filter FileBlobStorePermissionTransitionTests -Xswiftc -warnings-as-errors \
    >"$ARTIFACT_ROOT/permission-transition-tests.log" 2>&1
cat "$ARTIFACT_ROOT/permission-transition-tests.log"

scripts/verify-process-crash-matrix.sh
scripts/verify-real-full-volume.sh
scripts/verify-real-apfs-quota.sh
python3 Tools/Crash/verify_fault_injection_report.py \
    --durable-log "$ARTIFACT_ROOT/durable-file-writer-tests.log" \
    --permission-log "$ARTIFACT_ROOT/permission-transition-tests.log" \
    --switch-matrix .build/process-crash-matrix.json \
    --random-matrix .build/random-kill-matrix.json \
    --full-volume-matrix .build/real-full-volume-matrix.json \
    --quota-matrix .build/real-apfs-quota-matrix.json \
    --output "$ARTIFACT_ROOT/report.json"
