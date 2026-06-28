#!/bin/bash

set -u

usage() {
    echo "Usage: $0 [--app-deps] [--silent-missing] [--echo-command] [--progress] <jobs> <target> [subdir ...]" >&2
}

app_deps=0
silent_missing=0
echo_command=0
progress=0
progress_interval=60
progress_fd_open=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app-deps)
            app_deps=1
            shift
            ;;
        --silent-missing)
            silent_missing=1
            shift
            ;;
        --echo-command)
            echo_command=1
            shift
            ;;
        --progress)
            progress=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -lt 2 ]; then
    usage
    exit 2
fi

jobs="$1"
target="$2"
shift 2

case "$jobs" in
    *[!0-9]*|0)
        echo "ERROR: jobs must be a positive integer: $jobs" >&2
        exit 2
        ;;
esac

test_run_jobs="${MAKEFW_TEST_RUN_JOBS:-$jobs}"
case "$test_run_jobs" in
    *[!0-9]*|0)
        echo "ERROR: MAKEFW_TEST_RUN_JOBS must be a positive integer: $test_run_jobs" >&2
        exit 2
        ;;
esac

make_cmd="${MAKEFW_SUBDIR_MAKE:-make}"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/makefw-test-run.XXXXXX") || exit 1
created_slot_root=0
slot_root="${MAKEFW_TEST_SLOT_DIR:-}"
if [ -z "$slot_root" ]; then
    slot_root="$tmp_root/slots"
    mkdir -p "$slot_root" || exit 1
    created_slot_root=1
    slot_i=1
    while [ "$slot_i" -le "$test_run_jobs" ]; do
        mkdir "$slot_root/slot-$slot_i" || exit 1
        slot_i=$((slot_i + 1))
    done
fi

abort=0
signal_received=""

now_seconds() {
    date +%s 2>/dev/null || echo 0
}

format_duration() {
    local total="$1"
    local hours
    local minutes
    local seconds

    hours=$((total / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))

    if [ "$hours" -gt 0 ]; then
        printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
    else
        printf '%02d:%02d' "$minutes" "$seconds"
    fi
}

setup_progress_stream() {
    if [ "$progress" -eq 0 ]; then
        return 0
    fi

    if [ -t 2 ] && { exec 3>/dev/tty; } 2>/dev/null; then
        :
    else
        exec 3>&2
    fi
    progress_fd_open=1
}

close_progress_stream() {
    if [ "$progress_fd_open" -eq 1 ]; then
        exec 3>&-
        progress_fd_open=0
    fi
}

progress_log() {
    if [ "$progress" -eq 0 ] || [ "$progress_fd_open" -eq 0 ]; then
        return 0
    fi
    printf 'INFO: %s\n' "$1" >&3
}

count_pending_nodes() {
    local pending_count=0
    local idx=0

    while [ "$idx" -lt "$count" ]; do
        if [ "${state[$idx]}" = "pending" ]; then
            pending_count=$((pending_count + 1))
        fi
        idx=$((idx + 1))
    done

    printf '%s\n' "$pending_count"
}

handle_interrupt() {
    if [ -n "$signal_received" ]; then
        return
    fi
    signal_received="$1"
    abort=1
    printf 'INFO: Interrupt received (%s). Waiting for running jobs to finish...\n' "$1" >&2
    trap '' INT HUP TERM
}

cleanup() {
    close_progress_stream
    if [ "$created_slot_root" -eq 1 ]; then
        rm -rf "$slot_root"
    fi
    rm -rf "$tmp_root"
}
trap 'handle_interrupt INT' INT
trap 'handle_interrupt HUP' HUP
trap 'handle_interrupt TERM' TERM
trap cleanup EXIT

setup_progress_stream

has_makefile() {
    [ -f "$1/makefile" ] || [ -f "$1/GNUmakefile" ] || [ -f "$1/Makefile" ]
}

acquire_slot() {
    local lock_dir
    local slot_dir

    while :; do
        if [ "$abort" -eq 1 ]; then
            return 1
        fi
        for slot_dir in "$slot_root"/slot-*; do
            [ -d "$slot_dir" ] || continue
            lock_dir="$slot_dir/lock"
            if mkdir "$lock_dir" 2>/dev/null; then
                printf '%s\n' "$lock_dir"
                return 0
            fi
        done
        sleep 0.05
    done
}

read_app_deps() {
    local dir="$1"
    local deps=""

    if [ -f "$dir/appdeps.mk" ]; then
        deps=$(
            sed -n 's/^[[:space:]]*APP_DEPS[[:space:]]*[:+?]\{0,1\}=[[:space:]]*//p' "$dir/appdeps.mk" |
                sed 's/#.*//' |
                tr '\n' ' '
        )
    fi
    printf '%s\n' "$deps"
}

run_make_node() {
    local dir="$1"
    local out_file="$2"
    local leaf="$3"
    local lock_dir=""
    local rc

    {
        if [ "$echo_command" -eq 1 ]; then
            echo "$make_cmd -C $dir $target"
        fi
        if [ "$leaf" -eq 1 ]; then
            lock_dir=$(acquire_slot) || return 130
        fi
        if [ "$leaf" -eq 1 ]; then
            MAKEFLAGS= MFLAGS= MAKEFW_TEST_RUN_JOBS="$test_run_jobs" MAKEFW_TEST_SLOT_DIR="$slot_root" \
                "$make_cmd" -j1 -C "$dir" "$target"
        else
            MAKEFLAGS= MFLAGS= MAKEFW_TEST_RUN_JOBS="$test_run_jobs" MAKEFW_TEST_SLOT_DIR="$slot_root" \
                "$make_cmd" -C "$dir" "$target"
        fi
        rc="$?"
        if [ -n "$lock_dir" ]; then
            rmdir "$lock_dir"
        fi
        return "$rc"
    } > "$out_file" 2>&1
}

dirs=()
leaves=()
nested_dirs=()

for dir in "$@"; do
    if ! has_makefile "$dir"; then
        if [ "$silent_missing" -eq 0 ]; then
            nested_dirs+=("$dir")
        fi
        continue
    fi

    if [ "$app_deps" -eq 1 ]; then
        dirs+=("$dir")
        leaves+=(0)
        continue
    fi

    if [ "${MAKEFW_FORCE_LEAF:-0}" = "1" ]; then
        leaf=1
    else
        leaf=$(MAKEFLAGS= MFLAGS= "$make_cmd" -s -j1 -C "$dir" _makefw_is_test_leaf 2>/dev/null | tail -n 1)
    fi
    if [ "$leaf" = "1" ]; then
        dirs+=("$dir")
        leaves+=(1)
    else
        nested_dirs+=("$dir")
    fi
done

state=()
status_values=()
deps_by_index=()
count="${#dirs[@]}"
i=0
while [ "$i" -lt "$count" ]; do
    state[$i]=pending
    status_values[$i]=
    deps_by_index[$i]=""
    i=$((i + 1))
done

if [ "$app_deps" -eq 1 ]; then
    i=0
    while [ "$i" -lt "$count" ]; do
        dir="${dirs[$i]}"
        dep_indices=""
        for dep in $(read_app_deps "$dir"); do
            dep_i=0
            while [ "$dep_i" -lt "$count" ]; do
                if [ "$(basename "${dirs[$dep_i]}")" = "$dep" ]; then
                    dep_indices="$dep_indices $dep_i"
                    break
                fi
                dep_i=$((dep_i + 1))
            done
        done
        deps_by_index[$i]="$dep_indices"
        i=$((i + 1))
    done
fi

deps_done() {
    local idx="$1"
    local dep_i

    for dep_i in ${deps_by_index[$idx]}; do
        if [ "${state[$dep_i]}" != "done" ]; then
            return 1
        fi
    done
    return 0
}

dep_failed() {
    local idx="$1"
    local dep_i

    for dep_i in ${deps_by_index[$idx]}; do
        if [ "${state[$dep_i]}" = "failed" ] || [ "${state[$dep_i]}" = "blocked" ]; then
            return 0
        fi
    done
    return 1
}

run_ordered_nodes() {
    local next_print=0
    local running=0
    local completed=0
    local failed=0
    local progress_made
    local status_file
    local out_file
    local status
    local dir
    local leaf
    local started=0
    local start_time
    local current_time
    local last_wait_report_at
    local pending_count
    local elapsed

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    start_time=$(now_seconds)
    last_wait_report_at="$start_time"

    while [ "$completed" -lt "$count" ]; do
        progress_made=0

        i=0
        while [ "$i" -lt "$count" ]; do
            if [ "${state[$i]}" = "running" ] && [ -f "$tmp_root/node-$i.status" ]; then
                status=$(cat "$tmp_root/node-$i.status")
                status_values[$i]="$status"
                if [ "$status" -eq 0 ]; then
                    state[$i]=done
                else
                    state[$i]=failed
                    if [ "$failed" -eq 0 ]; then
                        failed="$status"
                    fi
                fi
                running=$((running - 1))
                completed=$((completed + 1))
                progress_made=1
                progress_log "done [$completed/$count] ${dirs[$i]} rc=$status"
                last_wait_report_at=$(now_seconds)
            fi
            i=$((i + 1))
        done

        i=0
        while [ "$i" -lt "$count" ]; do
            if [ "${state[$i]}" = "pending" ] && dep_failed "$i"; then
                out_file="$tmp_root/node-$i.out"
                status_file="$tmp_root/node-$i.status"
                printf 'ERROR: Skipping %s because a dependency failed.\n' "${dirs[$i]}" > "$out_file"
                printf '%s\n' 1 > "$status_file"
                status_values[$i]=1
                state[$i]=blocked
                if [ "$failed" -eq 0 ]; then
                    failed=1
                fi
                completed=$((completed + 1))
                progress_made=1
                progress_log "blocked ${dirs[$i]} (dependency failed)"
                last_wait_report_at=$(now_seconds)
            fi
            i=$((i + 1))
        done

        i=0
        while [ "$i" -lt "$count" ] && [ "$running" -lt "$jobs" ] && [ "$abort" -eq 0 ]; do
            if [ "${state[$i]}" = "pending" ] && deps_done "$i"; then
                dir="${dirs[$i]}"
                leaf="${leaves[$i]}"
                out_file="$tmp_root/node-$i.out"
                status_file="$tmp_root/node-$i.status"
                started=$((started + 1))
                progress_log "dispatch [$started/$count] $dir"
                (
                    run_make_node "$dir" "$out_file" "$leaf"
                    printf '%s\n' "$?" > "$status_file"
                ) &
                state[$i]=running
                running=$((running + 1))
                progress_made=1
                last_wait_report_at=$(now_seconds)
            fi
            i=$((i + 1))
        done

        if [ "$abort" -eq 1 ]; then
            i=0
            while [ "$i" -lt "$count" ]; do
                if [ "${state[$i]}" = "pending" ]; then
                    out_file="$tmp_root/node-$i.out"
                    status_file="$tmp_root/node-$i.status"
                    printf 'ERROR: Skipping %s due to interrupt.\n' "${dirs[$i]}" > "$out_file"
                    printf '%s\n' 130 > "$status_file"
                    status_values[$i]=130
                    state[$i]=interrupted
                    if [ "$failed" -eq 0 ]; then
                        failed=130
                    fi
                    completed=$((completed + 1))
                    progress_made=1
                    progress_log "blocked ${dirs[$i]} (interrupt received)"
                    last_wait_report_at=$(now_seconds)
                fi
                i=$((i + 1))
            done
        fi

        while [ "$next_print" -lt "$count" ] && [ -n "${status_values[$next_print]}" ]; do
            out_file="$tmp_root/node-$next_print.out"
            if [ -f "$out_file" ]; then
                cat "$out_file"
            fi
            next_print=$((next_print + 1))
            progress_made=1
        done

        if [ "$completed" -lt "$count" ] && [ "$running" -eq 0 ] && [ "$progress_made" -eq 0 ]; then
            i=0
            while [ "$i" -lt "$count" ]; do
                if [ "${state[$i]}" = "pending" ]; then
                    out_file="$tmp_root/node-$i.out"
                    status_file="$tmp_root/node-$i.status"
                    printf 'ERROR: Dependency cycle or unresolved dependency around %s.\n' "${dirs[$i]}" > "$out_file"
                    printf '%s\n' 1 > "$status_file"
                    status_values[$i]=1
                    state[$i]=blocked
                    failed=1
                    completed=$((completed + 1))
                    progress_made=1
                    progress_log "blocked ${dirs[$i]} (dependency cycle or unresolved dependency)"
                    last_wait_report_at=$(now_seconds)
                    break
                fi
                i=$((i + 1))
            done
        fi

        if [ "$completed" -lt "$count" ] && [ "$progress_made" -eq 0 ]; then
            current_time=$(now_seconds)
            if [ "$running" -gt 0 ] && [ $((current_time - last_wait_report_at)) -ge "$progress_interval" ]; then
                pending_count=$(count_pending_nodes)
                elapsed=$(format_duration $((current_time - start_time)))
                progress_log "waiting elapsed=$elapsed running=$running pending=$pending_count completed=$completed/$count"
                last_wait_report_at="$current_time"
            fi

            if [ "$running" -gt 0 ]; then
                sleep 1
            else
                sleep 0.05
            fi
        fi
    done

    while [ "$next_print" -lt "$count" ]; do
        out_file="$tmp_root/node-$next_print.out"
        if [ -f "$out_file" ]; then
            cat "$out_file"
        fi
        next_print=$((next_print + 1))
    done

    return "$failed"
}

run_nested_dirs() {
    local dir

    for dir in "${nested_dirs[@]}"; do
        if ! has_makefile "$dir"; then
            echo "Skipping $dir (no makefile found)"
        else
            MAKEFLAGS= MFLAGS= MAKEFW_TEST_RUN_JOBS="$test_run_jobs" MAKEFW_TEST_SLOT_DIR="$slot_root" \
                "$make_cmd" -C "$dir" "$target" || return "$?"
        fi
    done
}

run_ordered_nodes
ordered_rc=$?
if [ -n "$signal_received" ]; then
    case "$signal_received" in
        INT) exit 130 ;;
        TERM) exit 143 ;;
        HUP) exit 129 ;;
        *) exit 130 ;;
    esac
fi
if [ "$ordered_rc" -ne 0 ]; then
    exit "$ordered_rc"
fi
run_nested_dirs
