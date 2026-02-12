#!/bin/sh
# MSVC の /showIncludes 出力を GNU Make の .d 形式に変換
# Convert MSVC /showIncludes output to GNU Make .d format
#
# 使用方法 (Usage):
#   cl /showIncludes ... 2>&1 | sh msvc_dep.sh target.obj source.c target.d

target="$1"
source="$2"
depfile="$3"

# 引数チェック
if [ -z "$target" ] || [ -z "$source" ] || [ -z "$depfile" ]; then
    echo "Error: Required arguments not provided" >&2
    echo "Usage: sh msvc_dep.sh target.obj source.c target.d" >&2
    exit 1
fi

# CP932 エンコードの日本語プレフィックスを構築
# "メモ: インクルード ファイル:" の CP932 (Shift-JIS) バイト列
# Build CP932-encoded Japanese prefix for "メモ: インクルード ファイル:"
cp932_prefix=$(printf '\x83\x81\x83\x82: \x83\x43\x83\x93\x83\x4e\x83\x8b\x81\x5b\x83\x68 \x83\x74\x83\x40\x83\x43\x83\x8b:')

# awk スクリプトを実行 (LC_ALL=C でバイトモード動作)
# Run awk in byte mode (LC_ALL=C) to handle both UTF-8 and CP932 input
LC_ALL=C awk -v target="$target" -v source="$source" -v depfile="$depfile" -v cp932_prefix="$cp932_prefix" '
BEGIN {
    # 依存関係ファイルのヘッダーを作成
    printf "%s: %s", target, source > depfile

    # 依存ファイルのリストを保存 (空ルール生成用)
    deps_count = 0
}

{
    # 日本語プレフィックスを削除 (UTF-8)
    header = ""
    if (match($0, /^メモ: インクルード ファイル: */)) {
        header = substr($0, RSTART + RLENGTH)
    }
    # 英語プレフィックスを削除
    else if (match($0, /^Note: including file: */)) {
        header = substr($0, RSTART + RLENGTH)
    }
    # 日本語プレフィックスを削除 (CP932)
    # CP932 の 2 バイト目が regex メタ文字 [ と衝突するため index() で固定文字列マッチ
    # Use index() for fixed-string match because CP932 second bytes may collide with regex metacharacters
    else if (index($0, cp932_prefix) == 1) {
        header = substr($0, length(cp932_prefix) + 1)
        sub(/^ */, "", header)
    }

    if (header != "") {
        # バックスラッシュをスラッシュに統一
        gsub(/\\/, "/", header)

        # スペースをエスケープ (Make の依存関係ファイルではスペースは特殊文字)
        gsub(/ /, "\\ ", header)

        # 依存関係を出力
        printf " \\\n  %s", header >> depfile

        # 空ルール生成用に保存
        deps[deps_count++] = header
    }
    else {
        # 依存関係解析対象でない行は標準出力に出力
        print
    }
}

END {
    # 末尾に改行を追加
    print "" >> depfile

    # GCC 互換の空ルールを追加 (ヘッダファイルが削除された場合のエラー回避)
    for (i = 0; i < deps_count; i++) {
        print "" >> depfile
        print deps[i] ":" >> depfile
    }

    # .d ファイルを閉じる
    close(depfile)
}
'

# .d ファイルのタイムスタンプを .obj ファイルと同じにする
# (ビルドのたびに .d が更新されることによる無限ループを防ぐ)
# Set .d file timestamp to match .obj file
# (prevents infinite rebuild loop due to .d being updated every build)
if [ -f "$target" ]; then
    touch -r "$target" "$depfile"
fi
