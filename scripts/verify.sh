#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
printf 'Using DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
xcodebuild -version
xcrun swift --version
python3 scripts/check-swift-toolchain.py

scripts/verify-source-boundary.sh
scripts/verify-privacy-manifests.sh
python3 Tools/Conformance/verify_status.py
python3 Tools/Quality/verify_structure.py
python3 Tools/Resource/test_capture_segmented_compaction_resource.py
xcrun swift test -Xswiftc -warnings-as-errors
xcrun swift build --product AkashicResourceProbe -Xswiftc -warnings-as-errors
AKASHIC_RESOURCE_PROBE_BIN_DIR=$(xcrun swift build --show-bin-path)
python3 scripts/verify-multiprocess-retirement-lease.py \
  --executable "$AKASHIC_RESOURCE_PROBE_BIN_DIR/AkashicResourceProbe"
scripts/verify-blob-store-conformance-kit.sh
xcrun swift build -c release -Xswiftc -warnings-as-errors
scripts/verify-consumer-package.sh
scripts/verify-negative-consumer.sh
scripts/verify-public-api.sh
scripts/verify-source-identity.sh
printf 'Akashic Core/Memory/Disk vertical slice verification passed.\n'
