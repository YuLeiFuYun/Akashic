#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

ARTIFACT_ROOT=.build/release-readiness
mkdir -p "$ARTIFACT_ROOT"
SOURCE_IDENTITY="$ARTIFACT_ROOT/source-identity-before.json"
python3 Tools/Identity/capture_source_identity.py --output "$SOURCE_IDENTITY"

scripts/verify.sh
scripts/verify-clean-copy.sh
scripts/verify-fault-injection.sh
scripts/verify-store-generation-contention.py
scripts/verify-local-resource-envelope.sh
scripts/verify-filesystem-io-ledger.sh
/bin/sh scripts/verify-schema4-downgrade.sh
/bin/sh scripts/verify-schema4-historical-tag.sh
scripts/verify-platform-matrix.sh
python3 Tools/Identity/capture_source_identity.py \
    --output "$ARTIFACT_ROOT/source-identity-after.json" \
    --compare "$SOURCE_IDENTITY"
printf 'Akashic release-readiness mechanics passed on one stable source identity; physical power-loss and stable-device resource qualification remain open.\n'
