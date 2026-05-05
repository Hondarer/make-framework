#!/bin/bash
# normalize_paths.sh - パスリストを一括で正規化する
# Usage: normalize_paths.sh path1 path2 ...
# Output: 正規化済みパスをスペース区切りで出力
#
# Windows (cygpath あり): realpath -m → cygpath -m (各1回の呼び出し)
# Linux/その他: realpath -m のみ (1回の呼び出し)

# 引数がなければ空文字を返す
if [ $# -eq 0 ]; then
    exit 0
fi

# realpath -m で一括正規化 (失敗したパスはそのまま出力)
# 改行区切りで出力される
resolved=$(realpath -m "$@" 2>/dev/null)
if [ -z "$resolved" ]; then
    # realpath が完全に失敗した場合は元のパスを使用
    resolved=$(printf '%s\n' "$@")
fi

# cygpath の存在確認 (Windows 判定)
if command -v cygpath >/dev/null 2>&1; then
    # Windows: cygpath -m で一括変換
    # 改行区切りの入力を受け取り、スペース区切りで出力
    echo "$resolved" | xargs cygpath -m 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
else
    # Linux: 改行をスペースに変換
    echo "$resolved" | tr '\n' ' ' | sed 's/ $//'
fi
