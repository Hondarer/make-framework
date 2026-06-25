#!/bin/bash

set -u

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <jobs> <target> [subdir ...]" >&2
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

make_cmd="${MAKEFW_SUBDIR_MAKE:-make}"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/makefw-test-run.XXXXXX") || exit 1
cleanup() {
    rm -rf "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

test_dirs=()
nested_dirs=()

for dir in "$@"; do
    if [ ! -f "$dir/makefile" ] && [ ! -f "$dir/GNUmakefile" ] && [ ! -f "$dir/Makefile" ]; then
        nested_dirs+=("$dir")
        continue
    fi

    leaf=$(MAKEFLAGS= MFLAGS= "$make_cmd" -s -j1 -C "$dir" _makefw_is_test_leaf 2>/dev/null | tail -n 1)
    if [ "$leaf" = "1" ]; then
        test_dirs+=("$dir")
    else
        nested_dirs+=("$dir")
    fi
done

run_ordered_tests() {
    local count="${#test_dirs[@]}"
    local next_start=0
    local next_print=0
    local running=0
    local failed=0
    local i
    local dir
    local out_file
    local status_file
    local status
    local printed_any

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    while [ "$next_print" -lt "$count" ]; do
        while [ "$next_start" -lt "$count" ] && [ "$running" -lt "$jobs" ]; do
            i="$next_start"
            dir="${test_dirs[$i]}"
            out_file="$tmp_root/test-$i.out"
            status_file="$tmp_root/test-$i.status"
            (
                MAKEFLAGS= MFLAGS= MAKEFW_TEST_RUN_JOBS="$jobs" \
                    "$make_cmd" -j1 -C "$dir" "$target" > "$out_file" 2>&1
                printf '%s\n' "$?" > "$status_file"
            ) &
            next_start=$((next_start + 1))
            running=$((running + 1))
        done

        printed_any=0
        while [ "$next_print" -lt "$count" ] && [ -f "$tmp_root/test-$next_print.status" ]; do
            out_file="$tmp_root/test-$next_print.out"
            status_file="$tmp_root/test-$next_print.status"
            if [ -f "$out_file" ]; then
                cat "$out_file"
            fi
            status=$(cat "$status_file")
            if [ "$status" -ne 0 ]; then
                failed="$status"
            fi
            next_print=$((next_print + 1))
            running=$((running - 1))
            printed_any=1
        done

        if [ "$next_print" -lt "$count" ] && [ "$printed_any" -eq 0 ]; then
            sleep 0.05
        fi
    done

    return "$failed"
}

run_nested_dirs() {
    local dir

    for dir in "${nested_dirs[@]}"; do
        if [ ! -f "$dir/makefile" ] && [ ! -f "$dir/GNUmakefile" ] && [ ! -f "$dir/Makefile" ]; then
            echo "Skipping $dir (no makefile found)"
        else
            MAKEFLAGS= MFLAGS= MAKEFW_TEST_RUN_JOBS="$jobs" "$make_cmd" -j1 -C "$dir" "$target" || return "$?"
        fi
    done
}

run_ordered_tests || exit "$?"
run_nested_dirs
