#!/bin/bash
# 再コンパイルが必要なソースを抽出するスクリプト
# 引数: $1=ソースリスト (スペース区切り), $2=OBJDIR, $3=WORKSPACE_DIR

SRCS="$1"
OBJDIR="$2"
WORKSPACE_DIR="$3"

for src in $SRCS; do
    base=$(basename "$src" | sed 's/\.[^.]*$//')
    obj="$OBJDIR/$base.obj"
    dep="$OBJDIR/$base.d"

    # .obj が存在しない、または .c/.cpp が新しい、または .d が存在しない
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ] || [ ! -f "$dep" ]; then
        echo "$src"
        continue
    fi

    # .d 内のワークスペース内ヘッダーを grep で高速抽出
    # 末尾のコロンを除去し、重複を排除
    headers=$(grep -o "$WORKSPACE_DIR[^ \\]*" "$dep" 2>/dev/null | sed 's/:$//' | sort -u)

    dirty=0
    for h in $headers; do
        if [ -f "$h" ] && [ "$h" -nt "$obj" ]; then
            dirty=1
            break
        fi
    done

    if [ $dirty -eq 1 ]; then
        echo "$src"
    fi
done

