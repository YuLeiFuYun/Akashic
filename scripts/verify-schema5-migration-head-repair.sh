#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT_DIR/.build/out/Products/Release/AkashicResourceProbe"
OUT="$ROOT_DIR/.artifacts/program/T102/20260814T1440+0800-schema5-migration-head-repair"
mkdir -p "$OUT"

for POINT in no-new-head one-new-head both-new-heads; do
  CASE_DIR="$OUT/$POINT"
  STORE="$CASE_DIR/store"
  mkdir -p "$CASE_DIR"
  "$BIN" segmented-schema5-migration-crash-seed --root "$STORE" > "$CASE_DIR/seed.json"
  "$BIN" segmented-schema5-migration-complete --root "$STORE"
  set +e
  "$BIN" segmented-schema5-migration-head-crash --root "$STORE" --point "$POINT"
  CODE=$?
  set -e
  if [ "$CODE" -ne 91 ]; then
    echo "unexpected head child exit $CODE for $POINT" >&2
    exit 1
  fi
  "$BIN" segmented-schema5-migration-head-inspect --root "$STORE" > "$CASE_DIR/inspect.json"
  python3 - "$CASE_DIR/seed.json" "$CASE_DIR/inspect.json" "$POINT" <<'PY'
import json, sys
seed = json.load(open(sys.argv[1]))
inspect = json.load(open(sys.argv[2]))
point = sys.argv[3]
expected_before = {"no-new-head": 0, "one-new-head": 1, "both-new-heads": 2}[point]
assert inspect["generation"] == seed["schema4Generation"] + 1, point
assert inspect["stateCommitment"] == seed["expectedStateCommitment"], point
assert inspect["headCountBeforeRepair"] == expected_before, (point, inspect)
assert inspect["headCountAfterRepair"] == 2, point
assert inspect["oldReaderRejectedSchema5"] is True, point
print(point, "before", expected_before, "after", inspect["headCountAfterRepair"], inspect["stateCommitment"][:16])
PY
done

FUTURE_DIR="$OUT/future-head-before-root"
FUTURE_STORE="$FUTURE_DIR/store"
mkdir -p "$FUTURE_DIR"
"$BIN" segmented-schema5-migration-crash-seed --root "$FUTURE_STORE" > "$FUTURE_DIR/seed.json"
"$BIN" segmented-schema5-migration-future-head-control --root "$FUTURE_STORE" > "$FUTURE_DIR/report.json"
python3 - "$FUTURE_DIR/seed.json" "$FUTURE_DIR/report.json" <<'PY'
import json, sys
seed = json.load(open(sys.argv[1]))
report = json.load(open(sys.argv[2]))
assert report["schema4Generation"] == seed["schema4Generation"]
assert report["futureGeneration"] == seed["schema4Generation"] + 1
assert report["futureHeadCount"] == 1
assert report["oldReaderRejectedFutureHead"] is True
print("future-head-before-root rejected", report["schema4Generation"], "->", report["futureGeneration"])
PY
