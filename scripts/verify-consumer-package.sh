#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR

FIXTURE="$ROOT/Fixtures/ConsumerSmoke"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
SCRATCH="$WORK/swiftpm"

xcrun swift build --package-path "$FIXTURE" --scratch-path "$SCRATCH" -c release
BIN_DIR=$(xcrun swift build --package-path "$FIXTURE" --scratch-path "$SCRATCH" -c release --show-bin-path)
"$BIN_DIR/AkashicConsumerSmoke" >/dev/null
printf 'Akashic external consumer passed.\n'
