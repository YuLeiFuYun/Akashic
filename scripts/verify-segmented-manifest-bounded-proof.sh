#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
OUT=${1:-.build/segmented-manifest-bounded-proof.json}
STORE=${2:-.build/segmented-manifest-bounded-proof-store}
mkdir -p "$(dirname -- "$OUT")"
rm -rf "$STORE"
xcrun swift run -c release -Xswiftc -warnings-as-errors AkashicResourceProbe \
    segmented-manifest-bounded-proof --root "$STORE" > "$OUT"
