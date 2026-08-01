#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR

FIXTURE="$ROOT/Fixtures/ConsumerSmoke"
rm -rf "$FIXTURE/.build"
xcrun swift build --package-path "$FIXTURE" -c release
"$FIXTURE/.build/release/AkashicConsumerSmoke" >/dev/null
printf 'Akashic external consumer passed.\n'
