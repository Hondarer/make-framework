#!/bin/bash
#set -x

# NOTE: settings.json に以下記載すれば環境変数を設定できるが、
#       統合ターミナル外から make された場合を考慮して、自身で files.encoding の内容を得る。
# 
#     "terminal.integrated.env.linux": {
#         "VSCODE_FILES_ENCODING": "${config:files.encoding}"
#     } // ターミナルの VSCODE_FILES_ENCODING 環境変数に files.encoding の内容を設定する

# NOTE: jq コマンドは、json フォーマットを厳密にチェックするので
#       setting.json 記載時に注意が必要。末尾にカンマがある等で失敗する。
#       sed を使った実装をデフォルトにしているが、この場合、setting.json の改行位置に注意。

# このスクリプトのパス
SCRIPT_DIR=$(dirname "$0")

# ワークスペースのディレクトリ
WORKSPACE_FOLDER=$SCRIPT_DIR/../../

# LANG 環境変数の言語指定部分を取得 (デフォルトは "ja_JP")
default_lang=$(echo "$LANG" | sed -E 's/\..*//' | grep -E '^[a-zA-Z]+(-[a-zA-Z]+)?$' || echo "ja_JP")

# ワークスペースの .vscode/settings.json のパス
VSCODE_SETTINGS="$WORKSPACE_FOLDER/.vscode/settings.json"

# グローバル settings.json のパス
GLOBAL_SETTINGS="$HOME/.config/Code/User/settings.json"

# ファイルが存在し files.encoding 項目が存在するかチェックする関数
get_files_encoding() {
  local settings_file=$1
  if [ -f "$settings_file" ]; then
    #encoding=$(jq -r '."files.encoding"' "$settings_file")
    encoding=$(grep -o '"files.encoding"[[:space:]]*:[[:space:]]*"[^"]*"' "$settings_file" | sed -E 's/.*"files.encoding"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    if [ "$encoding" != "" ] && [ "$encoding" != "null" ]; then
      echo "$default_lang.$encoding"
      return 0
    fi
  fi
  return 1
}

# 優先順位に従って files.encoding の値を取得
if get_files_encoding "$VSCODE_SETTINGS"; then
  exit 0
elif get_files_encoding "$GLOBAL_SETTINGS"; then
  exit 0
else
  echo "$default_lang.utf8"
fi
