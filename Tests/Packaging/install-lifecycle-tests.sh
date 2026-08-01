#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
. "$project_root/Scripts/Packaging/install-lifecycle.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-lifecycle-test.XXXXXX")
test_executable="$test_root/test-process"
process_one=""
process_two=""

cleanup() {
    [[ -z "$process_one" ]] || kill "$process_one" 2>/dev/null || true
    [[ -z "$process_two" ]] || kill "$process_two" 2>/dev/null || true
    [[ -z "$process_one" ]] || wait "$process_one" 2>/dev/null || true
    [[ -z "$process_two" ]] || wait "$process_two" 2>/dev/null || true
    if [[ -n "${test_root:-}" && -d "$test_root" && ! -L "$test_root" ]]; then
        case "$test_root" in
            */screenclear-lifecycle-test.*) /bin/rm -rf -- "$test_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$test_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' > "$test_root/test-process.c"
/usr/bin/clang -arch arm64 -mmacosx-version-min=14.0 \
    "$test_root/test-process.c" -o "$test_executable"

"$test_executable" 30 &
process_one=$!
sleep 0.1
running_pids=$(screenclear_pids_for_executable "$test_executable")
printf '%s\n' "$running_pids" | grep -qx "$process_one"
recorded_old_pids=""
new_without_old_pids=$(screenclear_new_pids_excluding_recorded \
    "$test_executable" "$recorded_old_pids")
printf '%s\n' "$new_without_old_pids" | grep -qx "$process_one"

if screenclear_wait_for_pids_to_exit 1 "$process_one"; then
    printf 'bounded wait unexpectedly accepted a running PID\n' >&2
    exit 1
fi

"$test_executable" 30 &
process_two=$!
sleep 0.1
new_pids=$(screenclear_new_pids_for_executable "$test_executable" "$process_one")
printf '%s\n' "$new_pids" | grep -qx "$process_two"
if printf '%s\n' "$new_pids" | grep -qx "$process_one"; then
    printf 'old PID was incorrectly reported as newly launched\n' >&2
    exit 1
fi

kill "$process_one" "$process_two"
wait "$process_one" 2>/dev/null || true
wait "$process_two" 2>/dev/null || true
process_one=""
process_two=""
screenclear_wait_for_pids_to_exit 2

printf 'install lifecycle tests passed\n'
