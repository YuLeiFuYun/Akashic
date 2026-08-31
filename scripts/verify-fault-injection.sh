#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
ARTIFACT_ROOT=.build/fault-injection
mkdir -p "$ARTIFACT_ROOT"
SOURCE_IDENTITY="$ARTIFACT_ROOT/source-identity-before.json"
python3 Tools/Identity/capture_source_identity.py --output "$SOURCE_IDENTITY"

xcrun swift test --filter DurableFileWriterFaultTests -Xswiftc -warnings-as-errors \
    >"$ARTIFACT_ROOT/durable-file-writer-tests.log" 2>&1
cat "$ARTIFACT_ROOT/durable-file-writer-tests.log"
xcrun swift test --filter FileBlobStorePermissionTransitionTests -Xswiftc -warnings-as-errors \
    >"$ARTIFACT_ROOT/permission-transition-tests.log" 2>&1
cat "$ARTIFACT_ROOT/permission-transition-tests.log"
xcrun swift test --filter FileBlobStoreFastXattrFaultTests -Xswiftc -warnings-as-errors \
    >"$ARTIFACT_ROOT/fast-xattr-classification-tests.log" 2>&1
cat "$ARTIFACT_ROOT/fast-xattr-classification-tests.log"
xcrun swift test --filter FileBlobStoreFastCommitFaultTests -Xswiftc -warnings-as-errors \
    >"$ARTIFACT_ROOT/fast-commit-syscall-tests.log" 2>&1
cat "$ARTIFACT_ROOT/fast-commit-syscall-tests.log"

scripts/verify-process-crash-matrix.sh
scripts/verify-real-full-volume.sh
scripts/verify-real-apfs-quota.sh
python3 Tools/Identity/capture_source_identity.py \
    --output "$ARTIFACT_ROOT/source-identity-after.json" \
    --compare "$SOURCE_IDENTITY"
python3 Tools/Crash/verify_fault_injection_report.py \
    --source-identity "$SOURCE_IDENTITY" \
    --durable-log "$ARTIFACT_ROOT/durable-file-writer-tests.log" \
    --permission-log "$ARTIFACT_ROOT/permission-transition-tests.log" \
    --fast-xattr-log "$ARTIFACT_ROOT/fast-xattr-classification-tests.log" \
    --fast-syscall-log "$ARTIFACT_ROOT/fast-commit-syscall-tests.log" \
    --switch-matrix .build/process-crash-matrix.json \
    --fast-switch-matrix .build/fast-commit-crash-matrix.json \
    --random-matrix .build/random-kill-matrix.json \
    --full-volume-matrix .build/real-full-volume-matrix.json \
    --quota-matrix .build/real-apfs-quota-matrix.json \
    --output "$ARTIFACT_ROOT/report.json"
