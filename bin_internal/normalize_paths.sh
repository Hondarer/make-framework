#!/bin/bash
# normalize_paths.sh - パス リストを一括で正規化する
# Usage: normalize_paths.sh path1 path2 ...
# Output: 正規化済みパスをスペース区切りで出力
#
# 環境変数:
#   PLATFORM_WINDOWS=1 : Windows として処理 (cygpath 使用)
#   未設定             : Linux として処理 (realpath のみ)
#
# Windows: realpath -m → cygpath -m (各 1 回の呼び出し)
# Linux:   realpath -m のみ (1 回の呼び出し)

# --relative はビルド グラフ用にカレント ディレクトリからの相対パスを返す。
# 配置先に含まれる空白が、make のパス リストへ混入することを避ける。
relative=0
if [ "${1:-}" = "--relative" ]; then
    relative=1
    shift
fi

# 引数がなければ空文字を返す
if [ $# -eq 0 ]; then
    exit 0
fi

# realpath -m で一括正規化 (失敗したパスはそのまま出力)
if [ -n "${PLATFORM_WINDOWS:-}" ]; then
    # xargs の既定の分割では空白を含むパスが壊れるため、改行単位で配列へ読む。
    mapfile -t paths < <(cygpath -u "$@")
else
    paths=("$@")
fi
if [ "$relative" -eq 1 ]; then
    resolved=$(realpath -m --relative-to="$(pwd -P)" "${paths[@]}" 2>/dev/null)
else
    resolved=$(realpath -m "${paths[@]}" 2>/dev/null)
fi
if [ -z "$resolved" ]; then
    resolved=$(printf '%s\n' "$@")
fi

# PLATFORM_WINDOWS 環境変数で判定 (command -v の呼び出しを省略)
if [ -n "${PLATFORM_WINDOWS:-}" ] && [ "$relative" -eq 0 ]; then
    # Windows: cygpath -m で一括変換
    mapfile -t paths <<< "$resolved"
    cygpath -m "${paths[@]}" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
else
    # Linux: 改行をスペースに変換
    echo "$resolved" | tr '\n' ' ' | sed 's/ $//'
fi
