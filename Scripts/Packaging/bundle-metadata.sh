#!/bin/bash

screenclear_verify_bundle_metadata() {
    local info_path="$1"
    local entry
    local key
    local expected
    local actual
    local -a required_entries=(
        'CFBundleName=ScreenClear'
        'CFBundleDisplayName=ScreenClear'
        'CFBundleIdentifier=local.screenclear'
        'CFBundleExecutable=ScreenClear'
        'CFBundlePackageType=APPL'
        'CFBundleInfoDictionaryVersion=6.0'
        'CFBundleShortVersionString=1.0'
        'CFBundleVersion=1'
        'CFBundleIconFile=ScreenClear'
        'LSMinimumSystemVersion=14.0'
        'LSUIElement=true'
        'NSHighResolutionCapable=true'
    )

    [[ -f "$info_path" && ! -L "$info_path" ]] || {
        printf 'bundle metadata is missing or unsafe: %s\n' "$info_path" >&2
        return 1
    }
    for entry in "${required_entries[@]}"; do
        key=${entry%%=*}
        expected=${entry#*=}
        actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$info_path" 2>/dev/null || true)
        [[ "$actual" = "$expected" ]] || {
            printf 'unexpected bundle metadata %s=%s in %s\n' \
                "$key" "$actual" "$info_path" >&2
            return 1
        }
    done
}
