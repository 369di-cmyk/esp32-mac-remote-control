#!/bin/zsh
set -euo pipefail
source_dir="${0:A:h}"
project_dir="${source_dir:h:h}"
output_dir="${1:-$project_dir/generated/apps}"
app="$output_dir/Mac Sleep Sync.app"
mkdir -p "$app/Contents/MacOS"
/usr/bin/xcrun clang -fobjc-arc -O2 -framework Cocoa "$source_dir/MacSleepSync.m" -o "$app/Contents/MacOS/MacSleepSync"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'io.github.esp32macremote.sleep-sync',
    'CFBundleName': 'Mac Sleep Sync', 'CFBundleDisplayName': 'Mac Sleep Sync',
    'CFBundleExecutable': 'MacSleepSync', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '13.0', 'LSUIElement': True,
    'NSHighResolutionCapable': True,
}))
PY
/usr/bin/codesign --force --sign - "$app"
print -r -- "$app"
