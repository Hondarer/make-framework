#!/bin/bash
# normalize_paths.sh - パスリストを一括で正規化する
# Usage: normalize_paths.sh path1 path2 ...
# Output: 正規化済みパスをスペース区切りで出力
#
# 環境変数:
#   PLATFORM_WINDOWS=1 : Windows として処理 (cygpath 使用)
#   未設定             : Linux として処理 (realpath のみ)
#
# Windows: realpath -m → cygpath -m (各1回の呼び出し)
# Linux:   realpath -m のみ (1回の呼び出し)

# 引数がなければ空文字を返す
if [ $# -eq 0 ]; then
    exit 0
fi

# realpath -m で一括正規化 (失敗したパスはそのまま出力)
resolved=$(realpath -m "$@" 2>/dev/null)
if [ -z "$resolved" ]; then
    resolved=$(printf '%s\n' "$@")
fi

# PLATFORM_WINDOWS 環境変数で判定 (command -v の呼び出しを省略)
if [ -n "$PLATFORM_WINDOWS" ]; then
    # Windows: cygpath -m で一括変換
    echo "$resolved" | xargs cygpath -m 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
else
    # Linux: 改行をスペースに変換
    echo "$resolved" | tr '\n' ' ' | sed 's/ $//'
fi
