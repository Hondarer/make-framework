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
ws_lower="${WORKSPACE_DIR//\\//}"
ws_lower="${ws_lower,,}"
ws_lower="${ws_lower%/}/"

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
    # read -a は空白で分割し、パス名展開を行わない。
    # -r を指定せず、make が保護した空白と行継続のバックスラッシュを解釈する。
    # 末尾がコロンのトークン (先頭行のターゲットと、ヘッダーごとの空ターゲット行) は
    # 依存の並びに現れるヘッダーの重複なので読み飛ばす。
    # MSYS ではファイル情報の取得が 1 回 0.5 [ms] 前後かかり、テストでは gtest の
    # ヘッダーが数十個並ぶため、取得回数を抑える。-nt は存在しないファイルに対して
    # 偽を返すため、-f による存在確認も省く。
    dirty=0
    while IFS=$' \t\r' read -a tokens || (( ${#tokens[@]} > 0 )); do
        for h in "${tokens[@]}"; do
            [[ "$h" == *: ]] && continue
            [[ "${h,,}" == "$ws_lower"* ]] || continue
            if [[ "$h" -nt "$obj" ]]; then
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
