#!/bin/bash

screenclear_pids_for_executable() {
    local executable_path="$1"
    local lsof_output
    local lsof_status

    [[ -f "$executable_path" && ! -L "$executable_path" ]] || return 0
    lsof_output=$(/usr/sbin/lsof -t -a -d txt -- "$executable_path" 2>/dev/null) || {
        lsof_status=$?
        [[ "$lsof_status" -eq 1 ]] && return 0
        return "$lsof_status"
    }
    printf '%s\n' "$lsof_output" | awk 'NF' | sort -n -u
}

screenclear_wait_for_pids_to_exit() {
    local timeout_seconds="$1"
    local deadline
    local process_id
    local any_running
    shift

    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || return 2
    for process_id in "$@"; do
        [[ "$process_id" =~ ^[0-9]+$ ]] || return 2
    done

    deadline=$((SECONDS + timeout_seconds))
    while :; do
        any_running=false
        for process_id in "$@"; do
            if kill -0 "$process_id" 2>/dev/null; then
                any_running=true
                break
            fi
        done
        [[ "$any_running" = true ]] || return 0
        (( SECONDS < deadline )) || return 1
        sleep 1
    done
}

screenclear_pid_is_listed() {
    local candidate="$1"
    local listed_pid
    shift

    for listed_pid in "$@"; do
        [[ "$candidate" != "$listed_pid" ]] || return 0
    done
    return 1
}

screenclear_new_pids_for_executable() {
    local executable_path="$1"
    local process_id
    local running_pids
    shift

    running_pids=$(screenclear_pids_for_executable "$executable_path") || return $?
    while IFS= read -r process_id; do
        [[ -n "$process_id" ]] || continue
        if ! screenclear_pid_is_listed "$process_id" "$@"; then
            printf '%s\n' "$process_id"
        fi
    done <<< "$running_pids"
}

screenclear_new_pids_excluding_recorded() {
    local executable_path="$1"
    local recorded_pids="$2"

    if [[ -z "$recorded_pids" ]]; then
        screenclear_new_pids_for_executable "$executable_path"
        return
    fi
    screenclear_new_pids_for_executable "$executable_path" $recorded_pids
}
