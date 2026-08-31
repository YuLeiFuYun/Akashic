#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT_DIR/.build/out/Products/Release/AkashicResourceProbe"
OUT="$ROOT_DIR/.artifacts/program/T102/20260814T1535+0800-schema5-checkpoint-one-head"
CASE_DIR="$OUT/case"
STORE="$CASE_DIR/store"
PLAN="$CASE_DIR/plan.json"
mkdir -p "$CASE_DIR"
chmod 700 "$CASE_DIR"

"$BIN" segmented-schema5-checkpoint-crash-seed --root "$STORE" > "$CASE_DIR/seed.json"
set +e
"$BIN" segmented-schema5-checkpoint-one-head-crash --root "$STORE" --plan "$PLAN"
CODE=$?
set -e
if [ "$CODE" -ne 91 ]; then
  echo "unexpected one-head child exit $CODE" >&2
  exit 1
fi

python3 - "$CASE_DIR/seed.json" "$STORE/blobs" > "$CASE_DIR/pre-open-head-count.txt" <<'PY'
import json, subprocess, sys
seed=json.load(open(sys.argv[1]))
g=seed['generation']+1
prefix=f'dev.akashic.mh1.g{g:016x}.'
output=subprocess.check_output(['/usr/bin/xattr', sys.argv[2]], text=True)
names=[line.strip() for line in output.splitlines() if line.strip()]
heads=[n for n in names if n.startswith(prefix)]
assert len(heads)==1, (prefix, names)
print(len(heads))
PY

"$BIN" segmented-schema5-checkpoint-crash-inspect --root "$STORE" > "$CASE_DIR/inspect.json"
python3 - "$CASE_DIR/seed.json" "$PLAN" "$CASE_DIR/inspect.json" "$CASE_DIR/pre-open-head-count.txt" <<'PY'
import json, sys
seed=json.load(open(sys.argv[1]))
plan=json.load(open(sys.argv[2]))
inspect=json.load(open(sys.argv[3]))
before=int(open(sys.argv[4]).read().strip())
assert before==1
assert inspect['generation']==seed['generation']+1
assert inspect['runCount']==1 and inspect['runRecordCount']==512
assert inspect['activeDistinctKeys']==0
assert inspect['entryCount']==plan['newEntryCount']
assert inspect['identityCommitment']==plan['newIdentityCommitment']
print('one-head-before-open',before,'repaired-new',inspect['generation'],inspect['runCount'],inspect['activeDistinctKeys'],inspect['identityCommitment'][:16])
PY
