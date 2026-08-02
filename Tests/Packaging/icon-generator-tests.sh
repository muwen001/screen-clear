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

regular_icon="$output_root/ScreenClear.iconset/icon_512x512@2x.png"
validate_regular_icon_footprint() {
    /usr/bin/xcrun swift - "$1" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let image = NSBitmapImageRep(data: data),
      image.pixelsWide == 1024,
      image.pixelsHigh == 1024 else {
    fputs("cannot decode 1024px icon\n", stderr)
    exit(1)
}

let row = image.pixelsHigh / 2
let opaqueColumns = (0..<image.pixelsWide).filter {
    (image.colorAt(x: $0, y: row)?.alphaComponent ?? 0) >= 0.95
}
guard let first = opaqueColumns.first, let last = opaqueColumns.last else {
    fputs("regular icon footprint failure: center row is transparent\n", stderr)
    exit(1)
}
let span = last - first + 1
guard (87...89).contains(first),
      (935...937).contains(last),
      (847...851).contains(span),
      abs((first + last) - 1023) <= 1 else {
    fputs("regular icon footprint failure: expected centered 83% span, got first=\(first) last=\(last) span=\(span)\n", stderr)
    exit(1)
}
SWIFT
}

validate_regular_icon_footprint "$regular_icon"

small_icon="$output_root/ScreenClear.iconset/icon_16x16.png"
validate_small_icon() {
    /usr/bin/xcrun swift - "$1" <<'SWIFT'
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
    $0.alphaComponent >= 0.95 && min($0.redComponent, min($0.greenComponent, $0.blueComponent)) >= 0.90
}
let cyan: (NSColor) -> Bool = {
    $0.alphaComponent >= 0.95 &&
        $0.redComponent >= 0.55 &&
        $0.greenComponent >= 0.75 &&
        $0.blueComponent >= 0.85 &&
        $0.greenComponent - $0.redComponent >= 0.15 &&
        $0.blueComponent - $0.redComponent >= 0.15
}

// These hand-picked decoded-PNG regions use y=0 at the image top and cover the visible monitor, stand, and sparkle.
guard countPixels(x: 2...3, y: 6...10, matching: white) >= 5,
      countPixels(x: 10...11, y: 6...9, matching: white) >= 4 else {
    fail("display side boundary")
}
guard countPixels(x: 4...9, y: 4...5, matching: white) >= 5 else {
    fail("display top boundary")
}
guard countPixels(x: 4...9, y: 10...10, matching: white) >= 5 else {
    fail("display bottom boundary")
}
guard countPixels(x: 6...7, y: 11...12, matching: white) >= 2,
      countPixels(x: 4...9, y: 12...13, matching: white) >= 4 else {
    fail("display stand")
}
guard countPixels(x: 11...15, y: 1...5, matching: cyan) >= 3 else {
    fail("upper-right sparkle")
}
SWIFT
}

mutate_small_icon() {
    /usr/bin/xcrun swift - "$1" "$2" "$3" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 4,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let image = NSBitmapImageRep(data: data),
      let mutable = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: image.pixelsWide,
          pixelsHigh: image.pixelsHigh,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
      ) else {
    fputs("cannot decode mutation fixture\n", stderr)
    exit(1)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let mutation = CommandLine.arguments[3]
var changes = 0

func isCyan(_ pixel: NSColor) -> Bool {
    pixel.alphaComponent >= 0.95 &&
        pixel.redComponent >= 0.55 &&
        pixel.greenComponent >= 0.75 &&
        pixel.blueComponent >= 0.85 &&
        pixel.greenComponent - pixel.redComponent >= 0.15 &&
        pixel.blueComponent - pixel.redComponent >= 0.15
}

for y in 0..<image.pixelsHigh {
    for x in 0..<image.pixelsWide {
        guard let pixel = image.colorAt(x: x, y: y) else {
            fputs("cannot read mutation fixture pixel\n", stderr)
            exit(1)
        }
        var replacement = NSColor(
            deviceRed: pixel.redComponent,
            green: pixel.greenComponent,
            blue: pixel.blueComponent,
            alpha: pixel.alphaComponent
        )
        switch mutation {
        case "sparkle" where (11...15).contains(x) && (1...5).contains(y) && isCyan(pixel):
            replacement = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
            changes += 1
        case "top-boundary" where (4...9).contains(x) && (4...5).contains(y):
            replacement = NSColor(deviceRed: 0.12, green: 0.25, blue: 0.85, alpha: 1)
            changes += 1
        default:
            break
        }
        mutable.setColor(replacement, atX: x, y: y)
    }
}

guard changes > 0,
      let encoded = mutable.representation(using: .png, properties: [:]) else {
    fputs("cannot create mutation fixture\n", stderr)
    exit(1)
}
do {
    try encoded.write(to: destination, options: .withoutOverwriting)
} catch {
    fputs("cannot write mutation fixture: \(error.localizedDescription)\n", stderr)
    exit(1)
}
SWIFT
}

sparkle_fixture="$test_root/mutated-sparkle-16px.png"
mutate_small_icon "$small_icon" "$sparkle_fixture" sparkle
set +e
validate_small_icon "$sparkle_fixture" >"$test_root/mutated-sparkle.out" 2>&1
sparkle_fixture_status=$?
set -e
test "$sparkle_fixture_status" -ne 0
grep -qx '16px icon visibility failure: upper-right sparkle' "$test_root/mutated-sparkle.out"

top_boundary_fixture="$test_root/mutated-top-boundary-16px.png"
mutate_small_icon "$small_icon" "$top_boundary_fixture" top-boundary
set +e
validate_small_icon "$top_boundary_fixture" >"$test_root/mutated-top-boundary.out" 2>&1
top_boundary_fixture_status=$?
set -e
test "$top_boundary_fixture_status" -ne 0
grep -qx '16px icon visibility failure: display top boundary' "$test_root/mutated-top-boundary.out"

validate_small_icon "$small_icon"

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
