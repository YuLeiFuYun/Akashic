#!/bin/sh
set -eu

if [ -n "${DEVELOPER_DIR:-}" ] && [ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    printf '%s\n' "$DEVELOPER_DIR"
    exit 0
fi

for candidate in \
    /Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode-beta.app/Contents/Developer
do
    if [ -x "$candidate/usr/bin/xcodebuild" ]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

echo 'A full Xcode installation is required' >&2
exit 1
