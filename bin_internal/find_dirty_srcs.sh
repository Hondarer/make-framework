#!/bin/bash
# 再コンパイルが必要なソースを抽出するスクリプト
# 引数: $1=ソース リスト (スペース区切り), $2=OBJDIR, $3=WORKSPACE_DIR
#
# Windows (MSYS) では外部コマンドの起動が 1 回数十 [ms] かかる。
# ソースごとに basename / sed / grep / sort を起動すると、ソース数に比例して
# 数秒単位の時間がかかるため、bash の組み込み機能だけで判定する。

SRCS="$1"
OBJDIR="$2"
WORKSPACE_DIR="$3"

# MSVC が生成する .d のパスは小文字化される一方 WORKSPACE_DIR は実際の表記のため、
# 大文字小文字を無視して照合する。Windows の FS は case-insensitive なので
# 抽出した小文字パスでも後続の -f / -nt は正しく評価される。
ws_lower="${WORKSPACE_DIR,,}"

for src in $SRCS; do
    base="${src##*/}"
    base="${base%.*}"
    obj="$OBJDIR/$base.obj"
    dep="$OBJDIR/$base.d"

    # .obj が存在しない、または .c/.cpp が新しい、または .d が存在しない
    if [[ ! -f "$obj" || "$src" -nt "$obj" || ! -f "$dep" ]]; then
        echo "$src"
        continue
    fi

    # .d 内のワークスペース内ヘッダーが .obj より新しければ再コンパイルする。
    # read -a は空白で分割し、パス名展開を行わない。末尾のコロン (空ターゲット行) は除去する。
    dirty=0
    while IFS=$' \t\r' read -r -a tokens || (( ${#tokens[@]} > 0 )); do
        for h in "${tokens[@]}"; do
            h="${h%:}"
            [[ "${h,,}" == "$ws_lower"* ]] || continue
            if [[ -f "$h" && "$h" -nt "$obj" ]]; then
                dirty=1
                break 2
            fi
        done
        tokens=()
    done < "$dep"

    if [[ $dirty -eq 1 ]]; then
        echo "$src"
    fi
done
