#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if grep -R -n -E '^import (Fovea|ImageCraft|FoveaHTTP|FoveaPersistence)' Sources; then
    echo 'host or image dependency leaked into Akashic sources' >&2
    exit 1
fi

if grep -R -n -E 'OriginalEncoded|contentID|namespace|dev\.fovea|fovea-storage|URLSession|ETag|Vary|RenderKey|DecodeKey' Sources; then
    echo 'host-domain vocabulary leaked into Akashic production sources' >&2
    exit 1
fi

if find Sources -type f -name '*.swift' -print0 | xargs -0 grep -n -E '(^|[^A-Za-z])(userID|accountID|logout|authorization)([^A-Za-z]|$)'; then
    echo 'application authority vocabulary leaked into Akashic production sources' >&2
    exit 1
fi

printf 'Akashic source boundary passed.\n'
