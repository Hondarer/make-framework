#!/usr/bin/env bash

set -u

platform="$1"
scope="$2"
crt_subdir="${3:-}"

has_source() {
    local src_dir="$1"
    local stem="$2"

    [ -f "$src_dir/$stem.c" ] || [ -f "$src_dir/$stem.cc" ] || [ -f "$src_dir/$stem.cpp" ]
}

if [ "$platform" = "linux" ]; then
    if [ "$scope" = "subdirs" ]; then
        find . -path "./obj" -prune -o -path "*/obj/*.o" -not -name "*.inject.o" -type f -print 2>/dev/null
    else
        find . -path "*/obj/*.o" -not -name "*.inject.o" -type f -print 2>/dev/null
    fi | while IFS= read -r obj; do
        src_dir="${obj%/obj/*}"
        obj_name="${obj##*/}"
        stem="${obj_name%.o}"
        if has_source "$src_dir" "$stem"; then
            printf '%s\n' "$obj"
        fi
    done | sort -u
elif [ "$platform" = "windows" ]; then
    if [ -z "$crt_subdir" ]; then
        exit 2
    fi

    find . -path "*/obj/$crt_subdir/*.obj" -not -name "*.inject.obj" -not -name "*.res.obj" -type f -print 2>/dev/null |
        while IFS= read -r obj; do
            src_dir="${obj%/obj/$crt_subdir/*}"
            obj_name="${obj##*/}"
            stem="${obj_name%.obj}"
            if has_source "$src_dir" "$stem"; then
                printf '%s\n' "$obj"
            fi
        done | sort -u
else
    exit 2
fi
