#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
clang -fobjc-arc -Wall -Wno-incompatible-pointer-types \
  -framework Cocoa -framework Security -framework CoreGraphics \
  -framework Carbon -framework ApplicationServices -framework IOKit \
  "$repo/tests/local_unlock_core.m" -o "$test_dir/test_unlock"
"$test_dir/test_unlock"
