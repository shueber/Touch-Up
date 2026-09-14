#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/touch-up-hid-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

clang -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable \
  -Wno-sign-compare -Wno-format -Wno-nullability-completeness \
  -Wno-unused-but-set-variable \
  "$test_dir/hid-regressions.c" \
  -framework CoreFoundation -framework CoreGraphics -framework IOKit \
  -o "$build_dir/hid-regressions"

# CFNumber's tagged pointers can mask missing CFDictionary retain/equality callbacks.
OBJC_DISABLE_TAGGED_POINTERS=YES "$build_dir/hid-regressions" "$test_dir/fixtures"
