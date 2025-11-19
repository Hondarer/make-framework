#!/usr/bin/awk -f
# MSVC の /showIncludes 出力を GNU Make の .d 形式に変換
# Convert MSVC /showIncludes output to GNU Make .d format
#
# 使用方法 (Usage):
#   cl /showIncludes ... 2>&1 | awk -f msvc_dep.awk -v target=target.obj -v source=source.c -v depfile=target.d

BEGIN {
    # 引数チェック
    if (target == "" || source == "" || depfile == "") {
        print "Error: Required variables not set" > "/dev/stderr"
        print "Usage: awk -f msvc_dep.awk -v target=target.obj -v source=source.c -v depfile=target.d" > "/dev/stderr"
        exit 1
    }

    # 依存関係ファイルのヘッダーを作成
    printf "%s: %s", target, source > depfile

    # 依存ファイルのリストを保存 (空ルール生成用)
    deps_count = 0
}

{
    # 日本語プレフィックスを削除
    header = ""
    if (match($0, /^メモ: インクルード ファイル: */)) {
        header = substr($0, RSTART + RLENGTH)
    }
    # 英語プレフィックスを削除
    else if (match($0, /^Note: including file: */)) {
        header = substr($0, RSTART + RLENGTH)
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

    # .d ファイルのタイムスタンプを .obj ファイルと同じにする
    # (ビルドのたびに .d が更新されることによる無限ループを防ぐ)
    # Set .d file timestamp to match .obj file
    # (prevents infinite rebuild loop due to .d being updated every build)
    system("test -f \"" target "\" && touch -r \"" target "\" \"" depfile "\"")
}
