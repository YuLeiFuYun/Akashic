#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
FIXTURE="$ROOT/Fixtures/NegativeConsumer"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
SCRATCH="$WORK/swiftpm"
LOG="$WORK/negative-consumer.log"

set +e
xcrun swift build --package-path "$FIXTURE" --scratch-path "$SCRATCH" -c release > "$LOG" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
    echo 'negative consumer unexpectedly compiled package-only fault hooks' >&2
    exit 1
fi
if ! grep -F 'FileBlobStoreSwitchPoint' "$LOG" >/dev/null; then
    tail -120 "$LOG" >&2
    echo 'negative consumer failed for an unrelated reason' >&2
    exit 1
fi
if ! grep -E "cannot find|inaccessible due to 'package' protection level|extra argument 'faultInjector'" "$LOG" >/dev/null; then
    tail -120 "$LOG" >&2
    echo 'negative consumer did not fail at the expected access-control boundary' >&2
    exit 1
fi
printf 'Akashic negative consumer passed.\n'
