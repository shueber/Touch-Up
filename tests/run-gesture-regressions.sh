#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$test_dir/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/touch-up-gesture-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -Wno-unused-variable -Wno-format -Wno-objc-missing-property-synthesis \
  -I "$project_dir" \
  "$test_dir/gesture-regressions.m" \
  "$project_dir/TouchUpCore/TUCTouchInputManager.m" \
  "$project_dir/TouchUpCore/TUCTouch.m" \
  "$project_dir/TouchUpCore/TUCScreen.m" \
  -framework AppKit -framework CoreGraphics \
  -o "$build_dir/gesture-regressions"

"$build_dir/gesture-regressions"
