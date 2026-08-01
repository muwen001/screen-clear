#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-arguments-test.XXXXXX")

cleanup() {
    if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" ]]; then
        case "$test_root" in
            */screenclear-arguments-test.*) /bin/rm -rf -- "$test_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$test_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
printf '#!/bin/bash\nprintf called > %q\nexit 99\n' "$test_root/swift-called" > "$fake_bin/swift"
chmod 755 "$fake_bin/swift"

assert_usage_error() {
    local output="$test_root/output-$1.txt"
    local status
    shift

    set +e
    PATH="$fake_bin:$PATH" "$project_root/make-app.sh" "$@" >"$output" 2>&1
    status=$?
    set -e

    if [[ "$status" -ne 64 ]]; then
        printf '%s: expected status 64, got %s\n' "$output" "$status" >&2
        return 1
    fi
    grep -q '用法:' "$output"
    test ! -e "$test_root/swift-called"
}

assert_usage_error extra-after-install --install extra
assert_usage_error explicit-empty ""

printf 'make-app argument tests passed\n'
