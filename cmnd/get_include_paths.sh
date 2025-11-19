#!/bin/bash

# このスクリプトのパス
SCRIPT_DIR=$(dirname "$0")

# ワークスペースのディレクトリ
WORKSPACE_FOLDER=$SCRIPT_DIR/../../

# c_cpp_properties.json のパス
c_cpp_properties="$WORKSPACE_FOLDER/.vscode/c_cpp_properties.json"

# includePath の値を抽出
# 1. awk を使用して c_cpp_properties.json ファイルから includePath の値を抽出
# 2. 行末のコメントを無視
# 3. 出力時の前後の不要な空白を除去
# 4. ${workspaceFolder}/** の行を除去
# 5. ${workspaceFolder} を $WORKSPACE_FOLDER 変数の値に置換
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
    abs_path=$(readlink -f "$path")
    echo "$abs_path"
done
