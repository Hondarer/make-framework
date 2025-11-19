#!/bin/bash

# このスクリプトのパス
SCRIPT_DIR=$(dirname "$0")

# ワークスペースのディレクトリ
WORKSPACE_FOLDER=$SCRIPT_DIR/../../

# c_cpp_properties.json のパス
c_cpp_properties="$WORKSPACE_FOLDER/.vscode/c_cpp_properties.json"

# OS 判定
# MinGW/MSYS の場合は "Win32"、それ以外は "Linux"
OS_NAME=$(uname)
if [[ "$OS_NAME" == MINGW* || "$OS_NAME" == MSYS* ]]; then
    CONFIG_NAME="Win32"
else
    CONFIG_NAME="Linux"
fi

# 指定された設定の defines の値を抽出
# 1. awk を使用して c_cpp_properties.json ファイルから指定された設定の defines の値を抽出
# 2. 行末のコメントを無視
# 3. 出力時の前後の不要な空白を除去
defines=$(awk -v config_name="$CONFIG_NAME" '
    BEGIN { in_config=0; in_defines=0 }

    # 指定された設定名を見つけたら、設定の開始
    $0 ~ "\"name\":[[:space:]]*\"" config_name "\"" {
        in_config=1
        next
    }

    # 新しい設定が始まったら、対象設定を終了
    in_config && /"name":[[:space:]]*"[^"]+"/ && $0 !~ "\"name\":[[:space:]]*\"" config_name "\"" {
        in_config=0
        in_defines=0
        next
    }

    # 対象設定内で defines を見つけたら
    in_config && /"defines":[[:space:]]*\[/ {
        in_defines=1
        # 同じ行に配列の内容がある場合の処理
        if (match($0, /\[.*\]/)) {
            str = substr($0, RSTART+1, RLENGTH-2)
            # カンマで分割
            split(str, items, ",")
            for (i in items) {
                sub(/\/\/.*/, "", items[i]) # コメント削除
                gsub(/"|^\[|\]$/, "", items[i])
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", items[i])
                if (items[i] != "") print items[i]
            }
            in_defines=0
        }
        next
    }
    
    # defines 配列の終了
    in_defines && /\]/ {
        in_defines=0
        next
    }
    
    # defines 配列内の値を処理
    in_defines {
        sub(/\/\/.*/, "", $0) # 行末のコメントを削除
        gsub(/"|,/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 != "") print $0
    }
    
    # configurations の終了で対象設定も終了
    /^[[:space:]]*\}[[:space:]]*$/ && in_config {
        in_config=0
        in_defines=0
    }
' "$c_cpp_properties")

# 結果を出力
echo "$defines" | while IFS= read -r define; do
    echo "$define"
done
