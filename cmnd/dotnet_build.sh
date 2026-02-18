#!/bin/bash

# dotnet build のラッパースクリプト
# dotnet build wrapper script
#
# 正常終了 (warning/error なし、終了コード 0) の場合は出力を抑制する。
# warning/error が検出された場合、またはビルド失敗の場合は、
# バッファしていた全出力を着色して表示する。
#
# Suppresses output on clean success (no warnings/errors, exit code 0).
# When warnings/errors are detected or build fails,
# flushes all buffered output with colorization.
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

# dotnet build を実行し、出力をシェル変数にバッファ
# Run dotnet build and buffer output in a shell variable
buf=$(dotnet build "$@" 2>&1)
rc=$?

# warning/error が検出された場合、またはビルド失敗の場合のみ表示
# Display output only when warnings/errors are detected or build failed
if [ $rc -ne 0 ] || echo "$buf" | grep -qE ': (warning|error) '; then
    echo "$buf" | sed \
      -e 's/\(.*: warning .*\)/\x1b[33m\1\x1b[0m/' \
      -e 's/\(.*: error .*\)/\x1b[31m\1\x1b[0m/' \
      -e 's/\(.*[1-9][0-9]* 個の警告\)/\x1b[33m\1\x1b[0m/' \
      -e 's/\(.*[1-9][0-9]* Warning(s)\)/\x1b[33m\1\x1b[0m/' \
      -e '/[1-9][0-9]* エラー/s/\(.*エラー\)/\x1b[31m\1\x1b[0m/' \
      -e '/[1-9][0-9]* Error(s)/s/\(.*Error(s)\)/\x1b[31m\1\x1b[0m/'
fi

exit $rc
