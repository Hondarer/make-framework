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
script_dir=$(cd "$(dirname "$0")" && pwd)
emit_utf8_console_py="$script_dir/emit_utf8_console.py"
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
terminate_requested=0
terminate_started_at=0
force_terminate_requested=0
interrupt_grace_seconds=5

case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) is_windows=1 ;;
    *) is_windows=0 ;;
esac

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


emit_out_file() {
    local out_file="$1"
    if [ ! -f "$emit_utf8_console_py" ]; then
        cat "$out_file"
        return $?
    fi

    python "$emit_utf8_console_py" "$out_file" || {
        cat "$out_file"
        return $?
    }
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
        force_terminate_requested=1
        printf 'INFO: Additional interrupt received. Forcing running jobs to stop...\n' >&2
        return
    fi
    signal_received="$1"
    abort=1
    printf 'INFO: Interrupt received (%s). Stopping running jobs...\n' "$1" >&2
}

terminate_leftover_nodes() {
    local idx

    idx=0
    while [ "$idx" -lt "${count:-0}" ]; do
        if [ -n "${node_pids[$idx]:-}" ]; then
            signal_pid_tree KILL "${node_pids[$idx]}"
        fi
        idx=$((idx + 1))
    done
}

cleanup() {
    terminate_leftover_nodes
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
                tr -d '\r' |
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

    release_slot() {
        if [ -n "${lock_dir:-}" ]; then
            rmdir "$lock_dir" 2>/dev/null || true
            lock_dir=""
        fi
    }

    trap 'release_slot' EXIT
    trap 'release_slot; exit 130' INT
    trap 'release_slot; exit 143' TERM
    trap 'release_slot; exit 129' HUP

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
        release_slot
        trap - EXIT INT TERM HUP
        return "$rc"
    } > "$out_file" 2>&1
}

windows_pid_for() {
    local pid="$1"
    local winpid=""

    # MSYS/Cygwin の pid は Windows の pid と一致しない場合がある。
    # /proc/<pid>/winpid が対応する Windows pid を公開する。
    # see: https://cygwin.com/cygwin-ug-net/proc.html
    if [ -r "/proc/$pid/winpid" ]; then
        winpid=$(cat "/proc/$pid/winpid" 2>/dev/null)
    fi
    printf '%s\n' "${winpid:-$pid}"
}

taskkill_pid_tree() {
    local pid="$1"
    local winpid

    [ -n "$pid" ] || return 0
    command -v taskkill.exe >/dev/null 2>&1 || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    winpid=$(windows_pid_for "$pid")
    # /T で子プロセスを含めて終了する。/F なしの taskkill は
    # 終了要求を送るだけで、コンソールの make.exe / cl.exe は応答しない。
    # see: https://learn.microsoft.com/windows-server/administration/windows-commands/taskkill
    # MSYS2_ARG_CONV_EXCL は /PID などの引数がパス変換されるのを防ぐ。
    # see: https://www.msys2.org/docs/filesystem-paths/
    MSYS2_ARG_CONV_EXCL='*' taskkill.exe /PID "$winpid" /T /F >/dev/null 2>&1 || true
}

list_descendant_pids() {
    local parent="$1"
    local child

    command -v pgrep >/dev/null 2>&1 || return 0
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        list_descendant_pids "$child"
        printf '%s\n' "$child"
    done
}

signal_pid_tree() {
    local sig="$1"
    local pid="$2"
    local child

    [ -n "$pid" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0

    if [ "$is_windows" -eq 1 ]; then
        # Git for Windows に pgrep はなく、MSYS の kill はネイティブ Windows
        # 子プロセス (make.exe -> cl.exe) にシグナルを届けられない。
        # see: https://cygwin.com/cygwin-ug-net/kill.html
        # さらに bash はフォアグラウンドの make.exe が終わるまでトラップを
        # 実行しないため、シグナルによる段階的終了は成立しない。
        # see: https://www.gnu.org/software/bash/manual/html_node/Signals.html
        # よって Windows ではシグナル種別によらず taskkill /T /F で
        # プロセス ツリーごと強制終了する。
        taskkill_pid_tree "$pid"
        return 0
    fi

    for child in $(list_descendant_pids "$pid"); do
        kill "-$sig" "$child" 2>/dev/null || true
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

is_pid_alive() {
    local pid="$1"

    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

status_for_signal() {
    case "$1" in
        INT) printf '%s\n' 130 ;;
        TERM) printf '%s\n' 143 ;;
        HUP) printf '%s\n' 129 ;;
        *) printf '%s\n' 130 ;;
    esac
}

begin_running_job_termination() {
    local sig
    local idx

    if [ "$terminate_requested" -eq 1 ]; then
        return 0
    fi

    sig="${signal_received:-TERM}"
    terminate_requested=1
    terminate_started_at=$(now_seconds)

    idx=0
    while [ "$idx" -lt "$count" ]; do
        if [ "${state[$idx]}" = "running" ]; then
            progress_log "stopping ${dirs[$idx]}"
            signal_pid_tree "$sig" "${node_pids[$idx]}"
        fi
        idx=$((idx + 1))
    done
}

force_running_job_termination() {
    local idx

    idx=0
    while [ "$idx" -lt "$count" ]; do
        if [ "${state[$idx]}" = "running" ]; then
            signal_pid_tree KILL "${node_pids[$idx]}"
        fi
        idx=$((idx + 1))
    done
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
node_pids=()
count="${#dirs[@]}"
i=0
while [ "$i" -lt "$count" ]; do
    state[$i]=pending
    status_values[$i]=
    deps_by_index[$i]=""
    node_pids[$i]=""
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
    local pid

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
                pid="${node_pids[$i]}"
                if [ -n "$pid" ]; then
                    wait "$pid" 2>/dev/null || true
                    node_pids[$i]=""
                fi
                progress_made=1
                progress_log "done [$completed/$count] ${dirs[$i]} rc=$status"
                last_wait_report_at=$(now_seconds)
            elif [ "${state[$i]}" = "running" ] && [ "$abort" -eq 1 ] && ! is_pid_alive "${node_pids[$i]}"; then
                status=$(status_for_signal "${signal_received:-INT}")
                out_file="$tmp_root/node-$i.out"
                status_file="$tmp_root/node-$i.status"
                printf 'ERROR: Stopped %s due to interrupt.\n' "${dirs[$i]}" >> "$out_file"
                printf '%s\n' "$status" > "$status_file"
                status_values[$i]="$status"
                state[$i]=interrupted
                if [ "$failed" -eq 0 ]; then
                    failed="$status"
                fi
                running=$((running - 1))
                completed=$((completed + 1))
                pid="${node_pids[$i]}"
                if [ -n "$pid" ]; then
                    wait "$pid" 2>/dev/null || true
                    node_pids[$i]=""
                fi
                progress_made=1
                progress_log "interrupted [$completed/$count] ${dirs[$i]} rc=$status"
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
                node_pids[$i]="$!"
                state[$i]=running
                running=$((running + 1))
                progress_made=1
                last_wait_report_at=$(now_seconds)
            fi
            i=$((i + 1))
        done

        if [ "$abort" -eq 1 ]; then
            begin_running_job_termination
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

        if [ "$abort" -eq 1 ] && [ "$running" -gt 0 ]; then
            current_time=$(now_seconds)
            if [ "$force_terminate_requested" -eq 1 ] ||
                [ $((current_time - terminate_started_at)) -ge "$interrupt_grace_seconds" ]; then
                force_running_job_termination
                force_terminate_requested=0
            fi
        fi

        while [ "$next_print" -lt "$count" ] && [ -n "${status_values[$next_print]}" ]; do
            out_file="$tmp_root/node-$next_print.out"
            if [ -f "$out_file" ]; then
                emit_out_file "$out_file"
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
            emit_out_file "$out_file"
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
