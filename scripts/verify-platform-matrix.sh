#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEVELOPER_DIR=$($ROOT/scripts/select-xcode.sh)
export DEVELOPER_DIR
DERIVED_ROOT=${AKASHIC_PLATFORM_DERIVED_DATA:-"$ROOT/.build/platform-matrix"}
mkdir -p "$DERIVED_ROOT"

run_build() {
    product=$1
    label=$2
    destination=$3
    deployment_key=$4
    deployment_value=$5
    expected_target=$6
    products_directory=$7
    shift 7

    derived="$DERIVED_ROOT/$product-$label"
    log="$DERIVED_ROOT/$product-$label.log"
    rm -rf "$derived" "$log"
    if ! xcodebuild \
        -scheme "$product" \
        -configuration Release \
        -destination "$destination" \
        -derivedDataPath "$derived" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        APPINTENTS_METADATA_PROCESSING_ENABLED=NO \
        "$deployment_key=$deployment_value" \
        build > "$log" 2>&1
    then
        tail -200 "$log" >&2
        exit 1
    fi
    if ! grep -F -- "$expected_target" "$log" >/dev/null; then
        echo "expected deployment target not observed for $product/$label: $expected_target" >&2
        tail -120 "$log" >&2
        exit 1
    fi

    artifact="$derived/Build/Products/$products_directory/$product.o"
    if [ ! -f "$artifact" ]; then
        echo "missing platform artifact for $product/$label: $artifact" >&2
        exit 1
    fi
    architectures=$(xcrun lipo -archs "$artifact")
    for required_architecture in "$@"; do
        case " $architectures " in
            *" $required_architecture "*) ;;
            *)
                echo "missing $required_architecture for $product/$label: $architectures" >&2
                exit 1
                ;;
        esac
    done
    printf 'Akashic platform build passed: %s %s [%s]\n' \
        "$product" "$label" "$architectures"
}

run_case() {
    product=$1
    label=$2
    case "$label" in
        macos)
            run_build \
                "$product" macos \
                'generic/platform=macOS' \
                MACOSX_DEPLOYMENT_TARGET 12.0 \
                '-apple-macos12.0' \
                Release \
                arm64 x86_64
            ;;
        ios-simulator)
            run_build \
                "$product" ios-simulator \
                'generic/platform=iOS Simulator' \
                IPHONEOS_DEPLOYMENT_TARGET 15.0 \
                '-apple-ios15.0-simulator' \
                Release-iphonesimulator \
                arm64 x86_64
            ;;
        ios-device)
            run_build \
                "$product" ios-device \
                'generic/platform=iOS' \
                IPHONEOS_DEPLOYMENT_TARGET 15.0 \
                '-apple-ios15.0' \
                Release-iphoneos \
                arm64
            ;;
        *)
            echo "unknown platform label: $label" >&2
            exit 2
            ;;
    esac
}

if [ "$#" -eq 2 ]; then
    case "$1" in
        AkashicDisk|AkashicMemory) ;;
        *) echo "unknown product: $1" >&2; exit 2 ;;
    esac
    run_case "$1" "$2"
    exit 0
fi

if [ "$#" -ne 0 ]; then
    echo 'usage: verify-platform-matrix.sh [AkashicDisk|AkashicMemory macos|ios-simulator|ios-device]' >&2
    exit 2
fi

rm -rf "$DERIVED_ROOT"
mkdir -p "$DERIVED_ROOT"
for product in AkashicDisk AkashicMemory
do
    for label in macos ios-simulator ios-device
    do
        run_case "$product" "$label"
    done
done
python3 Tools/Compatibility/validate_platform_matrix.py
