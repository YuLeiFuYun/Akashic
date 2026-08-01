#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

scripts/verify.sh
scripts/verify-clean-copy.sh
scripts/verify-fault-injection.sh
scripts/verify-store-generation-contention.py
scripts/verify-local-resource-envelope.sh
scripts/verify-platform-matrix.sh
printf 'Akashic release-readiness mechanics passed; physical power-loss and stable-device resource qualification remain open.\n'
