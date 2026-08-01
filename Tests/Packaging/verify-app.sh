#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    printf 'usage: %s APP_PATH ZIP_PATH\n' "$0" >&2
    exit 64
fi

app_path="$1"
zip_path="$2"
extract_root=""

cleanup() {
    if [[ -n "${extract_root:-}" && -d "$extract_root" && ! -L "$extract_root" ]]; then
        case "$extract_root" in
            */screenclear-verify.*) /bin/rm -rf -- "$extract_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$extract_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

verify_bundle() {
    local bundle_path="$1"
    local info="$bundle_path/Contents/Info.plist"
    local executable="$bundle_path/Contents/MacOS/ScreenClear"
    local details

    test -d "$bundle_path"
    test ! -L "$bundle_path"
    test -f "$info"
    test -x "$executable"
    test ! -L "$executable"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" = \
        "local.screenclear"
    test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info")" = \
        "14.0"

    codesign --verify --deep --strict --verbose=2 "$bundle_path"
    details=$(codesign -dv --verbose=4 "$bundle_path" 2>&1)
    printf '%s\n' "$details"
    printf '%s\n' "$details" | grep -q '^Identifier=local.screenclear$'
    printf '%s\n' "$details" | grep -q '^Signature=adhoc$'
    file "$executable" | grep -q 'Mach-O 64-bit executable arm64'
}

verify_bundle "$app_path"
test -f "$zip_path"
test ! -L "$zip_path"
unzip -tq "$zip_path"

extract_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-verify.XXXXXX")
ditto -x -k "$zip_path" "$extract_root"
archived_app="$extract_root/ScreenClear.app"
top_level_count=$(find "$extract_root" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')
test "$top_level_count" -eq 1
test -d "$archived_app"
test ! -L "$archived_app"
if find "$archived_app" -type l -print | grep -q .; then
    printf 'archive contains an unexpected symbolic link\n' >&2
    exit 1
fi

verify_bundle "$archived_app"
supplied_hash=$(shasum -a 256 "$app_path/Contents/MacOS/ScreenClear" | awk '{print $1}')
archived_hash=$(shasum -a 256 "$archived_app/Contents/MacOS/ScreenClear" | awk '{print $1}')
test "$supplied_hash" = "$archived_hash"
