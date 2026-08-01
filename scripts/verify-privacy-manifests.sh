#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

for manifest in \
    Sources/AkashicCore/PrivacyInfo.xcprivacy \
    Sources/AkashicDisk/PrivacyInfo.xcprivacy
do
    plutil -lint "$manifest" >/dev/null
    grep -F 'NSPrivacyAccessedAPICategoryFileTimestamp' "$manifest" >/dev/null
    grep -F '<string>C617.1</string>' "$manifest" >/dev/null
done

python3 - <<'PY'
from pathlib import Path
package = Path('Package.swift').read_text()
for target in ('AkashicCore', 'AkashicDisk'):
    expected = '.target(\n' + f'            name: "{target}",\n'
    start = package.find(expected)
    if start < 0:
        raise SystemExit(f'missing target block {target}')
    end = package.find('\n        ),', start)
    if end < 0 or 'PrivacyInfo.xcprivacy' not in package[start:end]:
        raise SystemExit(f'{target} does not process PrivacyInfo.xcprivacy')
PY
printf 'Akashic privacy manifests passed.\n'
