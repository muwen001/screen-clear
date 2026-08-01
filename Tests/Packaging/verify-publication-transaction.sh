#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
script_path="$project_root/Tests/Packaging/verify-publication-transaction.sh"
case_name="${1:-all}"

if [[ "$case_name" = all ]]; then
    status=0
    for test_case in identity zip-rollback signature-rollback; do
        if "$script_path" "$test_case"; then
            printf 'PASS: %s\n' "$test_case"
        else
            status=1
        fi
    done
    exit "$status"
fi

case "$case_name" in
    identity|zip-rollback|signature-rollback) ;;
    *) printf '用法: %s [all|identity|zip-rollback|signature-rollback]\n' "$0" >&2; exit 64 ;;
esac

swift build -c release >/dev/null
release_binary="$project_root/.build/release/ScreenClear"
test -x "$release_binary"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-transaction-test.XXXXXX")
test_root=$(cd "$test_root" && pwd -P)
case_root="$test_root/project"
shim_dir="$test_root/shims"

cleanup() {
    if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" ]]; then
        case "$test_root" in
            */screenclear-transaction-test.*) /bin/rm -rf -- "$test_root" ;;
            *) printf '拒绝清理意外测试路径: %s\n' "$test_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

mkdir -p "$case_root/.build/release" \
    "$case_root/Scripts/Packaging" \
    "$case_root/Scripts/Icons" \
    "$shim_dir"
cp "$project_root/make-app.sh" "$case_root/make-app.sh"
cp "$project_root/Scripts/Packaging/install-lifecycle.sh" \
    "$case_root/Scripts/Packaging/install-lifecycle.sh"
cp "$project_root/Scripts/Icons/generate-icons.swift" \
    "$case_root/Scripts/Icons/generate-icons.swift"
cp "$release_binary" "$case_root/.build/release/ScreenClear"
chmod 755 "$case_root/make-app.sh" \
    "$case_root/Scripts/Packaging/install-lifecycle.sh" \
    "$case_root/.build/release/ScreenClear"

cat > "$shim_dir/swift" <<'SHIM'
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 3 && "$1" = build && "$2" = -c && "$3" = release ]]
SHIM

cat > "$shim_dir/mv" <<'SHIM'
#!/bin/bash
set -euo pipefail
args=("$@")
count=${#args[@]}
if (( count >= 2 )); then
    source_path=${args[$((count - 2))]}
    target_path=${args[$((count - 1))]}
    if [[ "${SCREENCLEAR_FAIL_ZIP_PUBLISH:-}" = true &&
          "$target_path" = "$SCREENCLEAR_TEST_ROOT/dist/ScreenClear-macos-arm64.zip" ]]; then
        case "$source_path" in
            */screenclear-build.*/ScreenClear-macos-arm64.zip) exit 71 ;;
        esac
    fi
    if [[ "${SCREENCLEAR_FAIL_FAILED_APP_MOVE:-}" = true &&
          "$source_path" = "$SCREENCLEAR_TEST_ROOT/ScreenClear.app" ]]; then
        case "$target_path" in
            */failed-project.app) exit 72 ;;
        esac
    fi
fi
exec /bin/mv "$@"
SHIM

cat > "$shim_dir/codesign" <<'SHIM'
#!/bin/bash
set -euo pipefail
args=("$@")
target_path=${args[$((${#args[@]} - 1))]}
if [[ "${SCREENCLEAR_FAIL_PUBLISHED_SIGNATURE:-}" = true &&
      "$1" = --verify &&
      "$target_path" = "$SCREENCLEAR_TEST_ROOT/ScreenClear.app" ]]; then
    exit 73
fi
exec /usr/bin/codesign "$@"
SHIM

chmod 755 "$shim_dir/swift" "$shim_dir/mv" "$shim_dir/codesign"

PATH="$shim_dir:$PATH" SCREENCLEAR_TEST_ROOT="$case_root" "$case_root/make-app.sh" >/dev/null

marker="$case_root/ScreenClear.app/Contents/transaction-marker.txt"
printf 'previous-%s\n' "$case_name" > "$marker"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$case_root/ScreenClear.app"
marked_zip="$test_root/previous.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
    "$case_root/ScreenClear.app" "$marked_zip"
/bin/mv -f "$marked_zip" "$case_root/dist/ScreenClear-macos-arm64.zip"
previous_zip_digest=$(shasum -a 256 "$case_root/dist/ScreenClear-macos-arm64.zip" | awk '{print $1}')

assert_previous_outputs() {
    test "$(<"$marker")" = "previous-$case_name"
    /usr/bin/codesign --verify --deep --strict "$case_root/ScreenClear.app"
    test "$(shasum -a 256 "$case_root/dist/ScreenClear-macos-arm64.zip" | awk '{print $1}')" = \
        "$previous_zip_digest"
    test "$(/usr/bin/unzip -p "$case_root/dist/ScreenClear-macos-arm64.zip" \
        'ScreenClear.app/Contents/transaction-marker.txt')" = "previous-$case_name"
}

case "$case_name" in
    identity)
        /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.foreign' \
            "$case_root/ScreenClear.app/Contents/Info.plist"
        /usr/bin/codesign --force --deep --sign - --timestamp=none "$case_root/ScreenClear.app"
        replacement_zip="$test_root/foreign.zip"
        /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
            "$case_root/ScreenClear.app" "$replacement_zip"
        /bin/mv -f "$replacement_zip" "$case_root/dist/ScreenClear-macos-arm64.zip"
        previous_zip_digest=$(shasum -a 256 \
            "$case_root/dist/ScreenClear-macos-arm64.zip" | awk '{print $1}')

        if PATH="$shim_dir:$PATH" SCREENCLEAR_TEST_ROOT="$case_root" \
            "$case_root/make-app.sh" >/dev/null 2>&1; then
            printf 'FAIL: foreign project bundle was replaced\n' >&2
            exit 1
        fi
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$case_root/ScreenClear.app/Contents/Info.plist")" = com.example.foreign
        assert_previous_outputs
        ;;
    zip-rollback)
        if SCREENCLEAR_FAIL_ZIP_PUBLISH=true PATH="$shim_dir:$PATH" \
            SCREENCLEAR_TEST_ROOT="$case_root" "$case_root/make-app.sh" >/dev/null 2>&1; then
            printf 'FAIL: injected ZIP publication failure unexpectedly succeeded\n' >&2
            exit 1
        fi
        assert_previous_outputs
        ;;
    signature-rollback)
        if SCREENCLEAR_FAIL_PUBLISHED_SIGNATURE=true \
            SCREENCLEAR_FAIL_FAILED_APP_MOVE=true PATH="$shim_dir:$PATH" \
            SCREENCLEAR_TEST_ROOT="$case_root" "$case_root/make-app.sh" >/dev/null 2>&1; then
            printf 'FAIL: injected published-signature failure unexpectedly succeeded\n' >&2
            exit 1
        fi
        assert_previous_outputs
        ;;
esac
