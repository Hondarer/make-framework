#!/bin/bash

# c_cpp_properties.json から defines と includePath を一度に抽出するスクリプト
# Extract both defines and includePath from c_cpp_properties.json in a single invocation
# プロセス生成削減のため、get_defines.sh と get_include_paths.sh を統合
# Consolidates get_defines.sh and get_include_paths.sh to reduce process creation
#
# Usage:
#   get_config.sh defines       - defines のみ出力
#   get_config.sh include_paths - includePath のみ出力

# このスクリプトのパス
SCRIPT_DIR=$(dirname "$0")

# ワークスペースのディレクトリ
WORKSPACE_FOLDER=$SCRIPT_DIR/../../

# c_cpp_properties.json のパス
c_cpp_properties="$WORKSPACE_FOLDER/.vscode/c_cpp_properties.json"

# ファイルが存在しない場合は何も出力せず終了
if [ ! -f "$c_cpp_properties" ]; then
    exit 0
fi

# OS 判定
# MinGW/MSYS の場合は "Win32"、それ以外は "Linux"
OS_NAME=$(uname)
if [[ "$OS_NAME" == MINGW* || "$OS_NAME" == MSYS* ]]; then
    CONFIG_NAME="Win32"
else
    CONFIG_NAME="Linux"
fi

mode="${1:-defines}"

if [ "$mode" = "defines" ]; then
    # 指定された設定の defines の値を抽出
    awk -v config_name="$CONFIG_NAME" '
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
    ' "$c_cpp_properties"

elif [ "$mode" = "include_paths" ]; then
    # includePath の値を抽出
    include_paths=$(awk -v workspace_root="$WORKSPACE_FOLDER" '
        /"includePath": \[/,/\]/ {
            if ($0 ~ /"includePath": \[/) { in_include_path=1; next }
            if (in_include_path && $0 ~ /\]/) { in_include_path=0; next }
            if (in_include_path) {
                sub(/\/\/.*/, "", $0) # 行末のコメントを削除
                gsub(/"|,/, "", $0)
                gsub(/\$\{workspaceFolder\}/, workspace_root, $0)
                gsub(/^[ \t]+|[ \t]+$/, "", $0)
                if ($0 != workspace_root "/**") print $0
            }
        }
    ' "$c_cpp_properties")

    # 結果を絶対パスに変換して出力
    echo "$include_paths" | while IFS= read -r path; do
        if [ -n "$path" ]; then
            abs_path=$(readlink -f "$path" 2>/dev/null || echo "$path")
            echo "$abs_path"
        fi
    done
fi
