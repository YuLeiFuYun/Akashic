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
printf 'Akashic local release-readiness mechanics passed; power-loss, physical-resource, remote, tag and protected CI remain blockers.\n'
