#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:?usage: dump-public-api-symbols.sh OUTPUT_DIRECTORY}
DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM
mkdir -p "$OUTPUT"
rm -f "$OUTPUT"/*.symbols.json
cd "$ROOT"
xcrun swift build --scratch-path "$SCRATCH" --target AkashicDisk >/dev/null
xcrun swift build --scratch-path "$SCRATCH" --target AkashicMemory >/dev/null
MODULE_PATH=$(
    find "$SCRATCH" \( -type f -o -type d \) -name AkashicCore.swiftmodule -print |
    while IFS= read -r CORE
    do
        CANDIDATE=$(dirname "$CORE")
        if [ -e "$CANDIDATE/AkashicMemory.swiftmodule" ] && [ -e "$CANDIDATE/AkashicDisk.swiftmodule" ]; then
            printf '%s\n' "$CANDIDATE"
        fi
    done |
    head -n 1
)
if [ -z "$MODULE_PATH" ]; then
    echo 'production Swift modules were not produced in one search path' >&2
    exit 1
fi
ATOMIC_MODULE_MAP=$(find "$SCRATCH" -type f -path '*/GeneratedModuleMaps/CAkashicAtomics.modulemap' -print | head -n 1)
if [ -z "$ATOMIC_MODULE_MAP" ]; then
    echo 'CAkashicAtomics module map was not produced by the package build' >&2
    exit 1
fi
ATOMIC_HEADER_DIR="$ROOT/Sources/CAkashicAtomics/include"
ARCH=$(uname -m)
case "$ARCH" in arm64|x86_64) ;; *) echo "unsupported host architecture: $ARCH" >&2; exit 1 ;; esac
TARGET="${ARCH}-apple-macosx12.0"
SDK=$(xcrun --sdk macosx --show-sdk-path)
for MODULE in AkashicCore AkashicMemory AkashicDisk
do
    xcrun swift-symbolgraph-extract \
        -module-name "$MODULE" \
        -target "$TARGET" \
        -sdk "$SDK" \
        -I "$MODULE_PATH" \
        -Xcc "-fmodule-map-file=$ATOMIC_MODULE_MAP" \
        -Xcc "-I$ATOMIC_HEADER_DIR" \
        -minimum-access-level public \
        -skip-synthesized-members \
        -omit-extension-block-symbols \
        -output-dir "$OUTPUT"
done
