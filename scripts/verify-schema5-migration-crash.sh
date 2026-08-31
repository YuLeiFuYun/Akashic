#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT_DIR/.build/out/Products/Release/AkashicResourceProbe"
OUT="$ROOT_DIR/.artifacts/program/T102/20260814T1425+0800-schema5-migration-crash"
mkdir -p "$OUT"

for POINT in base-durable-root-old root-pre-rename root-post-rename root-post-directory-sync; do
  CASE_DIR="$OUT/$POINT"
  STORE="$CASE_DIR/store"
  mkdir -p "$CASE_DIR"
  "$BIN" segmented-schema5-migration-crash-seed --root "$STORE" > "$CASE_DIR/seed.json"
  set +e
  "$BIN" segmented-schema5-migration-crash --root "$STORE" --point "$POINT"
  CODE=$?
  set -e
  if [ "$CODE" -ne 91 ]; then
    echo "unexpected child exit $CODE for $POINT" >&2
    exit 1
  fi
  "$BIN" segmented-schema5-migration-crash-inspect --root "$STORE" > "$CASE_DIR/inspect.json"
  python3 - "$CASE_DIR/seed.json" "$CASE_DIR/inspect.json" "$POINT" <<'PY'
import json, sys
seed = json.load(open(sys.argv[1]))
inspect = json.load(open(sys.argv[2]))
point = sys.argv[3]
old_points = {"base-durable-root-old", "root-pre-rename"}
expected_authority = "schema4" if point in old_points else "schema5"
assert inspect["authority"] == expected_authority, (point, inspect)
assert inspect["stateCommitment"] == seed["expectedStateCommitment"], point
assert inspect["entryCount"] == seed["expectedEntryCount"], point
if expected_authority == "schema4":
    assert inspect["generation"] == seed["schema4Generation"], point
    assert inspect["activeSchema4DistinctKeys"] == seed["activeDistinctKeys"] == 3, point
    assert inspect["oldReaderRejectedSchema5"] is False, point
else:
    assert inspect["generation"] == seed["schema4Generation"] + 1, point
    assert inspect["segmentedRunCount"] == 0, point
    assert inspect["oldReaderRejectedSchema5"] is True, point
print(point, expected_authority, inspect["stateCommitment"][:16], "segments", inspect["orphanSegmentCount"])
PY
done
