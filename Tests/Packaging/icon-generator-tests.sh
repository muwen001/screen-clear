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

small_icon="$output_root/ScreenClear.iconset/icon_16x16.png"
/usr/bin/xcrun swift - "$small_icon" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let image = NSBitmapImageRep(data: data),
      image.pixelsWide == 16,
      image.pixelsHigh == 16 else {
    fputs("cannot decode 16px icon\n", stderr)
    exit(1)
}

func countPixels(x: ClosedRange<Int>, y: ClosedRange<Int>, matching: (NSColor) -> Bool) -> Int {
    var count = 0
    for row in y {
        for column in x {
            if let pixel = image.colorAt(x: column, y: row), matching(pixel) {
                count += 1
            }
        }
    }
    return count
}

func fail(_ message: String) -> Never {
    fputs("16px icon visibility failure: \(message)\n", stderr)
    exit(1)
}

let white: (NSColor) -> Bool = {
    min($0.redComponent, min($0.greenComponent, $0.blueComponent)) >= 0.90
}
let cyan: (NSColor) -> Bool = {
    $0.redComponent >= 0.55 && $0.greenComponent >= 0.75 && $0.blueComponent >= 0.85
}

// These hand-picked decoded-PNG regions use y=0 at the image top and cover the visible monitor, stand, and sparkle.
guard countPixels(x: 2...3, y: 6...10, matching: white) >= 5,
      countPixels(x: 4...9, y: 10...11, matching: white) >= 5,
      countPixels(x: 10...11, y: 6...9, matching: white) >= 4 else {
    fail("display boundary")
}
guard countPixels(x: 6...7, y: 11...12, matching: white) >= 2,
      countPixels(x: 4...9, y: 12...13, matching: white) >= 4 else {
    fail("display stand")
}
guard countPixels(x: 11...15, y: 1...5, matching: cyan) >= 3 else {
    fail("upper-right sparkle")
}
SWIFT

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
