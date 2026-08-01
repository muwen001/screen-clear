#!/bin/bash
set -euo pipefail

app_path="$1"
zip_path="$2"
info="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/ScreenClear"

test -d "$app_path"
test ! -L "$app_path"
test -f "$info"
test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = "local.screenclear"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")" = "14.0"

codesign --verify --deep --strict --verbose=2 "$app_path"
details=$(codesign -dv --verbose=4 "$app_path" 2>&1)
printf '%s\n' "$details"
printf '%s\n' "$details" | grep -q '^Identifier=local.screenclear$'
printf '%s\n' "$details" | grep -q '^Signature=adhoc$'
file "$executable" | grep -q 'Mach-O 64-bit executable arm64'
test -f "$zip_path"
unzip -tq "$zip_path"
