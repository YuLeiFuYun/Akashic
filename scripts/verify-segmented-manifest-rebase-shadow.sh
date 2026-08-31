#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicResourceProbe -Xswiftc -warnings-as-errors >/dev/null
BIN_DIR=$(xcrun swift build -c release --show-bin-path)
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM
mkdir -p .build
"$BIN_DIR/AkashicResourceProbe" segmented-manifest-rebase-shadow \
    --root "$TEMP_ROOT/store" \
    > .build/segmented-manifest-rebase-shadow.json
