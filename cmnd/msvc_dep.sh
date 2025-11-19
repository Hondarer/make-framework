#!/bin/sh
# MSVC の /showIncludes 出力を GNU Make の .d 形式に変換
# Convert MSVC /showIncludes output to GNU Make .d format
#
# 使用方法 (Usage):
#   cl /showIncludes ... 2>&1 | sh msvc_dep.sh target.obj source.c target.d
#
# このスクリプトは awk を呼び出すラッパーです。
# 実際の処理は msvc_dep.awk で行われます。

target="$1"
source="$2"
depfile="$3"

# スクリプトのディレクトリを取得
script_dir=$(dirname "$0")

# awk を呼び出して処理
awk -f "$script_dir/msvc_dep.awk" -v target="$target" -v source="$source" -v depfile="$depfile"

# .d ファイルのタイムスタンプを .obj ファイルと同じにする
# (ビルドのたびに .d が更新されることによる無限ループを防ぐ)
# Set .d file timestamp to match .obj file
# (prevents infinite rebuild loop due to .d being updated every build)
if [ -f "$target" ]; then
    touch -r "$target" "$depfile"
fi
