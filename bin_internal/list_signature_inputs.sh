#!/bin/bash

# 省略判定の対象とする makefw の入力の絶対パスを、1 行に 1 つ名前順に出力する。
# 範囲はこのスクリプトだけで定義し、次の 2 つの判定が共有する。
#   - resolve_app_deps.sh --signature (app 直下)
#   - framework/testfw/bin_internal/exec_test_c_cpp.sh の compute_test_signature (テスト ディレクトリ単位)
#
# 対象は makefiles/ 直下のすべてのファイルと、bin_internal/ 直下の *.sh、*.py、*.ps1 すべて。
# makefw はテストの有無にかかわらずすべての app のビルドの入力であり、コンパイル オプションを
# 変えると、テスト ソースに変更がなくてもテストの実行ファイルが作り直される。
# ビルドとテストに影響しないスクリプトも含めるのは、一覧の更新漏れで古い成果物や結果を残さないため。

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit
makefw_dir=$(cd "$script_dir/.." && pwd -P) || exit

{
    for path in "$makefw_dir"/makefiles/* \
        "$script_dir"/*.sh "$script_dir"/*.py "$script_dir"/*.ps1; do
        [ -f "$path" ] && printf '%s\n' "$path"
    done
} | LC_ALL=C sort
