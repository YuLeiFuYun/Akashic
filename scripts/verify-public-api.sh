#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT HUP INT TERM
rm -rf .build/out/symbolgraph
xcrun swift package dump-symbol-graph --skip-synthesized-members >/dev/null
python3 Tools/API/normalize_public_api.py \
    --symbol-graph-directory .build/out/symbolgraph \
    --output "$TMPDIR_ROOT/PublicAPI.json"
cmp API/PublicAPI.json "$TMPDIR_ROOT/PublicAPI.json"
python3 Tools/API/verify_contract_boundary.py
printf 'Akashic public API baseline passed.\n'
