#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
generator="$project_root/Scripts/Icons/generate-icons.swift"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-icon-test.XXXXXX")

cleanup() {
    if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" ]]; then
        case "$test_root" in
            */screenclear-icon-test.*) /bin/rm -rf -- "$test_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$test_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

set +e
/usr/bin/xcrun swift "$generator" >"$test_root/usage.out" 2>&1
usage_status=$?
set -e
test "$usage_status" -eq 64
grep -q 'usage:' "$test_root/usage.out"

output_root="$test_root/output"
mkdir -p "$output_root"

set +e
SCREENCLEAR_ICON_TEST_FAIL_AFTER_STAGING=1 /usr/bin/xcrun swift "$generator" "$output_root" >"$test_root/staging-failure.out" 2>&1
staging_failure_status=$?
set -e
test "$staging_failure_status" -ne 0
test ! -e "$output_root/ScreenClear.iconset"
test ! -L "$output_root/ScreenClear.iconset"
test ! -e "$output_root/ScreenClear.icns"
test ! -L "$output_root/ScreenClear.icns"
test ! -e "$output_root/MenuBarIcon.pdf"
test ! -L "$output_root/MenuBarIcon.pdf"

/usr/bin/xcrun swift "$generator" "$output_root"

while IFS=: read -r name width height; do
    image="$output_root/ScreenClear.iconset/$name"
    test -f "$image"
    test ! -L "$image"
    test -s "$image"
    test "$(/usr/bin/sips -g pixelWidth "$image" | awk '/pixelWidth:/ {print $2}')" = "$width"
    test "$(/usr/bin/sips -g pixelHeight "$image" | awk '/pixelHeight:/ {print $2}')" = "$height"
done <<'SIZES'
icon_16x16.png:16:16
icon_16x16@2x.png:32:32
icon_32x32.png:32:32
icon_32x32@2x.png:64:64
icon_128x128.png:128:128
icon_128x128@2x.png:256:256
icon_256x256.png:256:256
icon_256x256@2x.png:512:512
icon_512x512.png:512:512
icon_512x512@2x.png:1024:1024
SIZES

test -f "$output_root/ScreenClear.icns"
test ! -L "$output_root/ScreenClear.icns"
test -s "$output_root/ScreenClear.icns"
/usr/bin/file "$output_root/ScreenClear.icns" | grep -q 'Mac OS X icon'

test -f "$output_root/MenuBarIcon.pdf"
test ! -L "$output_root/MenuBarIcon.pdf"
test -s "$output_root/MenuBarIcon.pdf"
/usr/bin/file "$output_root/MenuBarIcon.pdf" | grep -q 'PDF document'

icns_digest=$(shasum -a 256 "$output_root/ScreenClear.icns" | awk '{print $1}')
set +e
/usr/bin/xcrun swift "$generator" "$output_root" >"$test_root/repeat.out" 2>&1
repeat_status=$?
set -e
test "$repeat_status" -ne 0
test "$(shasum -a 256 "$output_root/ScreenClear.icns" | awk '{print $1}')" = "$icns_digest"

printf 'icon generator tests passed\n'
