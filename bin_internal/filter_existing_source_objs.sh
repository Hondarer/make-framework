#!/usr/bin/env bash

set -u

platform="$1"
scope="$2"
crt_subdir="${3:-}"

# オブジェクトの生成元となるソースが残っているかを判定する。
#
# 手書きのソース (<dir>/<stem>.c) に加えて、flex/bison やアプリ独自のコード生成器が
# <dir>/gen/ へ出力したソースも根拠として認める。認めない場合、ライブラリや実行体の
# サブディレクトリへ .l / .y を置いたときに、そこから作られたオブジェクトが
# リンクを行うディレクトリまで届かない。
#
# ただし gen/ を根拠にできるのはサブディレクトリだけとする。リンクを行う
# ディレクトリ自身 (src_dir が ".") の gen/ 由来オブジェクトは、
# _flex_bison_compile.mk が MAKEFW_EXTRA_OBJS 経由でリンク入力へ加えるため、
# ここでも拾うと同じオブジェクトを二重にリンクしてしまう。
has_source() {
    local src_dir="$1"
    local stem="$2"

    if [ -f "$src_dir/$stem.c" ] || [ -f "$src_dir/$stem.cc" ] || [ -f "$src_dir/$stem.cpp" ]; then
        return 0
    fi
    if [ "$src_dir" = "." ]; then
        return 1
    fi
    [ -f "$src_dir/gen/$stem.c" ] || [ -f "$src_dir/gen/$stem.cc" ] || [ -f "$src_dir/gen/$stem.cpp" ]
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
