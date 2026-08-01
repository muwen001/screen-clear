#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
verifier="$project_root/Tests/Packaging/verify-app.sh"
source_app="${1:-$project_root/ScreenClear.app}"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-archive-test.XXXXXX")

cleanup() {
    if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" ]]; then
        case "$test_root" in
            */screenclear-archive-test.*) /bin/rm -rf -- "$test_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$test_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

assert_rejected() {
    local zip_path="$1"
    if "$verifier" "$source_app" "$zip_path" >"$test_root/verifier.out" 2>&1; then
        printf 'verifier unexpectedly accepted %s\n' "$zip_path" >&2
        exit 1
    fi
}

appledouble_root="$test_root/appledouble"
appledouble_zip="$test_root/appledouble.zip"
appledouble_filler="$appledouble_root/ScreenClear.app/Contents/appledouble-fixture"
mkdir -p "$appledouble_root" "$appledouble_filler"
ditto "$source_app" "$appledouble_root/ScreenClear.app"
printf 'unexpected metadata\n' > "$appledouble_root/ScreenClear.app/._metadata"
for filler_index in $(/usr/bin/jot -w '%05d' 4096 1); do
    : > "$appledouble_filler/entry-$filler_index"
done
(
    cd "$appledouble_root"
    /usr/bin/zip -q "$appledouble_zip" ScreenClear.app/._metadata
    find ScreenClear.app -mindepth 1 ! -path ScreenClear.app/._metadata -print |
        /usr/bin/zip -q "$appledouble_zip" -@
)
old_pipeline_status=0
unzip -Z1 "$appledouble_zip" | grep -Eq '(^|/)\._|^__MACOSX/' ||
    old_pipeline_status=$?
test "$old_pipeline_status" -eq 141
assert_rejected "$appledouble_zip"
if ! grep -Fxq 'archive contains unexpected AppleDouble metadata' \
    "$test_root/verifier.out"; then
    printf 'verifier did not report the AppleDouble-specific rejection\n' >&2
    sed -n '1,40p' "$test_root/verifier.out" >&2
    exit 1
fi

extra_root="$test_root/extra"
mkdir -p "$extra_root"
ditto "$source_app" "$extra_root/ScreenClear.app"
printf 'unexpected\n' > "$extra_root/unexpected.txt"
ditto -c -k --norsrc "$extra_root" "$test_root/extra.zip"
assert_rejected "$test_root/extra.zip"

mismatch_root="$test_root/mismatch"
mkdir -p "$mismatch_root"
ditto "$source_app" "$mismatch_root/ScreenClear.app"
cp /usr/bin/true "$mismatch_root/ScreenClear.app/Contents/MacOS/ScreenClear"
chmod 755 "$mismatch_root/ScreenClear.app/Contents/MacOS/ScreenClear"
codesign --force --deep --sign - --timestamp=none "$mismatch_root/ScreenClear.app" >/dev/null
ditto -c -k --norsrc --keepParent \
    "$mismatch_root/ScreenClear.app" "$test_root/mismatch.zip"
assert_rejected "$test_root/mismatch.zip"

resource_mismatch_root="$test_root/resource-mismatch"
mkdir -p "$resource_mismatch_root"
ditto "$source_app" "$resource_mismatch_root/ScreenClear.app"
printf '\n' >> "$resource_mismatch_root/ScreenClear.app/Contents/Resources/MenuBarIcon.pdf"
codesign --force --deep --sign - --timestamp=none \
    "$resource_mismatch_root/ScreenClear.app" >/dev/null
ditto -c -k --norsrc --keepParent \
    "$resource_mismatch_root/ScreenClear.app" "$test_root/resource-mismatch.zip"
assert_rejected "$test_root/resource-mismatch.zip"

printf 'archive verifier rejection tests passed\n'
