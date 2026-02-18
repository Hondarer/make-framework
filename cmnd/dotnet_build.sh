#!/bin/bash

# dotnet build のラッパースクリプト
# dotnet build wrapper script
#
# dotnet build の出力から着色を除去し、warning と error のみ着色する。
# Strips default coloring from dotnet build output and colorizes only warnings and errors.
#
# パイプ経由で dotnet build を実行するため、ターミナルロガーは自動的に無効化され、
# 無着色のクラシックロガー出力が得られる。この出力に対して sed で着色を付与する。
# Running dotnet build through a pipe automatically disables the terminal logger,
# producing uncolored classic logger output. sed then adds coloring.
#
# 着色ルール / Coloring rules:
#   - ": warning " を含む行 → 黄色 (Yellow)
#   - ": error " を含む行   → 赤色 (Red)
#   - サマリの警告行 (1件以上) → 黄色 (Yellow)
#   - サマリのエラー行 (1件以上) → 赤色 (Red)
#
# Usage:
#   dotnet_build.sh [dotnet build arguments...]
#
# Example:
#   dotnet_build.sh -c RelWithDebInfo -o ./lib

set -o pipefail

dotnet build "$@" 2>&1 | sed \
  -e 's/\(.*: warning .*\)/\x1b[33m\1\x1b[0m/' \
  -e 's/\(.*: error .*\)/\x1b[31m\1\x1b[0m/' \
  -e 's/\(.*[1-9][0-9]* 個の警告\)/\x1b[33m\1\x1b[0m/' \
  -e 's/\(.*[1-9][0-9]* Warning(s)\)/\x1b[33m\1\x1b[0m/' \
  -e '/[1-9][0-9]* エラー/s/\(.*エラー\)/\x1b[31m\1\x1b[0m/' \
  -e '/[1-9][0-9]* Error(s)/s/\(.*Error(s)\)/\x1b[31m\1\x1b[0m/'
