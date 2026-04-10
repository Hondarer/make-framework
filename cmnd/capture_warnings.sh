#!/bin/bash

# コンパイラ/リンカ出力から警告行を抽出してファイルに記録する
# Extract warning lines from compiler/linker output and save to a file
#
# stdin をそのまま stdout に流しつつ (ターミナル出力を保持)、
# warning 行を warn_file に抽出する。
# Passes stdin through to stdout unchanged (preserving terminal output),
# while extracting warning lines to warn_file.
#
# 警告がなければ warn_file は作成しない。
# Does not create warn_file when no warnings are found.
#
# ANSI エスケープは warn_file には含めない (プレーンテキスト)。
# ANSI escape codes are stripped from warn_file (plain text output).
#
# Usage:
#   ... 2>&1 | $(ICONV) | capture_warnings.sh <warn_file>

warn_file="$1"
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# stdin を stdout にパススルーしつつ tmpfile に保存
# Pass stdin through to stdout while saving to tmpfile
tee "$tmpfile"

# ANSI エスケープを除去して warning 行を抽出 (英語・日本語対応)
# Strip ANSI escapes and extract warning lines (English and Japanese)
sed 's/\x1b\[[0-9;]*[mK]//g' "$tmpfile" | grep -E ': (warning|警告)[ :]' > "$warn_file" 2>/dev/null || true

# 警告がなければ warn_file を削除
# Remove warn_file if no warnings were found
if [ ! -s "$warn_file" ]; then
    rm -f "$warn_file"
fi
