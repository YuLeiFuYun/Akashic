#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT_DIR/.build/out/Products/Release/AkashicResourceProbe"
OUT="$ROOT_DIR/.artifacts/program/T102/20260814T1515+0800-schema5-checkpoint-crash"
mkdir -p "$OUT"

for POINT in manifest-data-written manifest-file-synced manifest-renamed manifest-directory-synced; do
  CASE_DIR="$OUT/$POINT"
  STORE="$CASE_DIR/store"
  PLAN="$CASE_DIR/plan.json"
  mkdir -p "$CASE_DIR"
  chmod 700 "$CASE_DIR"
  "$BIN" segmented-schema5-checkpoint-crash-seed --root "$STORE" > "$CASE_DIR/seed.json"
  set +e
  "$BIN" segmented-schema5-checkpoint-crash --root "$STORE" --point "$POINT" --plan "$PLAN"
  CODE=$?
  set -e
  if [ "$CODE" -ne 91 ]; then
    echo "unexpected child exit $CODE for $POINT" >&2
    exit 1
  fi
  "$BIN" segmented-schema5-checkpoint-crash-inspect --root "$STORE" > "$CASE_DIR/inspect.json"
  python3 - "$CASE_DIR/seed.json" "$PLAN" "$CASE_DIR/inspect.json" "$POINT" <<'PY'
import json, sys
seed = json.load(open(sys.argv[1]))
plan = json.load(open(sys.argv[2]))
inspect = json.load(open(sys.argv[3]))
point = sys.argv[4]
new = point in {"manifest-renamed", "manifest-directory-synced"}
if new:
    assert inspect["generation"] == seed["generation"] + 1, (point, inspect)
    assert inspect["runCount"] == 1 and inspect["runRecordCount"] == 512, (point, inspect)
    assert inspect["activeDistinctKeys"] == 0, (point, inspect)
    assert inspect["entryCount"] == plan["newEntryCount"], (point, inspect)
    assert inspect["identityCommitment"] == plan["newIdentityCommitment"], point
else:
    assert inspect["generation"] == seed["generation"], (point, inspect)
    assert inspect["runCount"] == 0 and inspect["runRecordCount"] == 0, (point, inspect)
    assert inspect["activeDistinctKeys"] == seed["activeDistinctKeys"] == 511, (point, inspect)
    assert inspect["entryCount"] == seed["oldEntryCount"], (point, inspect)
    assert inspect["identityCommitment"] == seed["oldIdentityCommitment"], point
print(point, "new" if new else "old", inspect["generation"], inspect["runCount"], inspect["activeDistinctKeys"], inspect["identityCommitment"][:16], "segments", inspect["segmentFileCount"])
PY
done
