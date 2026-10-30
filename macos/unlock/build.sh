#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
app="$repo/generated/Mac Wake Unlock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -fobjc-arc -Wall -Wno-incompatible-pointer-types \
  -framework Cocoa -framework Security -framework LocalAuthentication \
  -framework CoreGraphics -framework Carbon -framework ApplicationServices -framework IOKit \
  "$repo/macos/unlock/MacWakeUnlock.m" -o "$app/Contents/MacOS/MacWakeUnlock"
cp "$repo/macos/unlock/THIRD_PARTY_NOTICES.txt" "$app/Contents/Resources/"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleExecutable='MacWakeUnlock',
        CFBundleIdentifier='io.github.esp32macremote.unlock',
        CFBundleName='Mac Wake Unlock', CFBundleDisplayName='Mac Wake Unlock',
        CFBundlePackageType='APPL', CFBundleShortVersionString='2.1.0',
        CFBundleVersion='1', LSUIElement=True, NSHighResolutionCapable=True,
        LSMinimumSystemVersion='13.0'), f)
PY
# Optional stable local signing identity; never ship a signing key.
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/MacWakeUnlock" --self-test
printf 'Built: %s\n' "$app"
