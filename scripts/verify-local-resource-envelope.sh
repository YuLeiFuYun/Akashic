#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
xcrun swift build -c release --product AkashicResourceProbe -Xswiftc -warnings-as-errors
python3 Tools/Resource/verify_local_resource_envelope.py
