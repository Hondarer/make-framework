<!--
生成元: agree-before-implement スキル
文書種別: 最終仕様 (design)
最終更新日時: 2026-11-26 01:35:00 JST
最終更新エージェント: claude code (主セッション session_01KJc53UFydnbt2gLXTJC1ZC)
稼働 OS: Linux (WSL)
上流文書: `261125-makefw-backlog-overview.md` (全体管理文書)、`261125-makefw-backlog-discussion.md` (検討用 Markdown)、`261125-makefw-backlog-lightadr.md` (簡易 ADR)。いずれも削除されている場合があります。
再開手順: このファイルを開いたエージェントは、作業の前に agree-before-implement スキルを読み込んでください。上流文書の全体管理文書が存在する場合は、その再開手順に従って進行位置を確認し、決定事項を簡易 ADR で、判断の経緯を検討用 Markdown の Q&A で確認します。存在しない場合は、この文書を単体の最終仕様として扱います。最終更新エージェントのセッション情報や稼働 OS・最終更新日時が参照可能であれば再開時のコンテキストや環境差分の把握に利用し、別エージェントや別環境・別 OS からの引き継ぎ、担当変更によりセッションが見つからない場合も異常とせず、文書の記載から継続してください。
-->

# makefw の残課題の対策 最終仕様

ファイル名: `261125-makefw-backlog-design.md`

## 概要

`framework/makefw` の次の 4 つの残課題を対策します。

| 課題 | 内容 | 対策の要点 |
| --- | --- | --- |
| BL-001 | テスト ディレクトリへ引き込むソースの引き込み方 (リンクとコピー) が切り替わると、以前のビルドの残骸のためにビルドが失敗する、またはコピー元の編集が反映されない | 解析時に残骸を検出し、配置の規則を必ず実行させて置き換える |
| BL-029 | `bin_test` の Python の `encoding` の指定漏れ | 6 か所に `encoding="utf-8"` を加える |
| BL-030 | `test_path_spaces.py` が統合ワークスペースの外で `FileNotFoundError` になる | 必要なファイルがなければ理由を付けて飛ばす |
| BL-002 | mock のヘッダーの変更後の MSVC の差分ビルドで、古いオブジェクトが残る | Windows の再現結果で原因を特定し、makefw に欠陥があれば修正と再現テストまで行う |

対策元は、`framework/makefw/docs/prompts/current/261120-makefw-inject-source-switch-backlog.md` の BL-001 と、`app/general/docs/prompts/current/261123-remaining-backlog-items-backlog.md` の BL-002、BL-029、BL-030 です。

## 変更対象

| ファイル | 課題 | 変更の種類 |
| --- | --- | --- |
| `framework/makefw/makefiles/_collect_srcs.mk` | BL-001 | 分類の変更、置き換えを強制する名前の一覧の追加 |
| `framework/makefw/makefiles/makesrc_c_cpp.mk` | BL-001 | 配置の規則の変更 |
| `framework/makefw/makefiles/makelibsrc_c_cpp.mk` | BL-001 | 配置の規則の変更 (`makesrc_c_cpp.mk` と同じ内容) |
| `framework/makefw/bin_test/source_classification_selftest.py` | BL-001 | 期待値の変更、切り替わりの確認の追加 |
| `framework/makefw/docs/makeparts.md` | BL-001 | 分類の説明の更新 |
| `framework/makefw/bin_test/app_paths_selftest.py` | BL-029 | `encoding` の追加 |
| `framework/makefw/bin_test/test_path_spaces.py` | BL-029、BL-030 | `encoding` の追加、飛ばす処理の追加 |
| `framework/makefw/bin_internal/msvc_compile.ps1`、`_msvc_pch.ps1`、`find_dirty_srcs.sh`、`framework/makefw/makefiles/_msvc_compile.mk`、`framework/makefw/bin_test/msvc_pch_selftest.ps1` のいずれか | BL-002 | Windows の再現結果で決まる (「BL-002」の章) |

## BL-001 引き込み方の切り替わりへの追従

### 用語

- **引き込み**: `TEST_SRCS` と `ADD_SRCS` に指定したソースを、カレント ディレクトリへ同じファイル名で配置することです。
- **外部のソース**: 参照先のディレクトリがカレント ディレクトリと異なるソースです。参照先のディレクトリが存在しない指定も含みます。判定は `_path_functions.mk` の `_makefw_source_dirs_of_kind` で、種別 `external` と `missing` です。
- **配置の規則**: 引き込みを行う規則です。リンクの規則 (`generate_link_src_rule`、`ln -sf`) と、コピーの規則 (`generate_cp_src_rule`、`cp -p` またはフィルター、および inject の結合) があります。

### 分類の仕様

`_collect_srcs.mk` は、`TEST_SRCS` と `ADD_SRCS` を次の順に分類します。

1. inject ファイル (`<名前>.inject.<拡張子>`) またはフィルター ファイル (`<名前>.filter.sh`) があるソースを `CP_SRCS` にします (既存)。
2. 残りのうち、カレント ディレクトリに同名の通常のファイル (シンボリック リンクでない) があるものを、`DIRECT_SRCS` の候補にします (既存)。
3. **候補のうち、外部のソースを `DIRECT_SRCS` から外します (変更)。** これまで Windows だけで行っていた判定を、両 OS で行います。同名のローカル実体は、以前の引き込みが残したものとして扱います。
4. 残りを `LINK_SRCS` にします (既存)。手順 3 で外したソースは `LINK_SRCS` に入ります。
5. Windows では `LINK_SRCS` をすべて `CP_SRCS` へ移します (既存)。

この結果、`DIRECT_SRCS` は「カレント ディレクトリにあるソースを指す指定」だけになります。

> [!IMPORTANT]
> Linux で、外部のソースと同名の通常のファイルをテスト ディレクトリに置いてコピー元より優先させる使い方 (ローカル実体の優先) は、廃止します。このファイルは次のビルドでリンクへ置き換わります。同名のファイルは従来から `make clean` で削除されており、リポジトリにこの使い方の例はありません。

> [!NOTE]
> 参照先のディレクトリが存在しない指定は、Linux でも `LINK_SRCS` に入り、既存の `_MISSING_LINK_SRCS` の検査で `Source files not found for LINK_SRCS` のエラーになります。これまでは、同名のローカル実体があればそれをコンパイルしていました。

### 置き換えの強制の仕様

配置の規則は、ターゲットのファイルが存在し、前提条件より新しければ実行されません。以前の引き込みの残骸は、この判定をすり抜けます。そこで Linux では、解析時に次の 2 つの一覧を求め、該当する配置の規則に、常に実行させる前提条件を加えます。

| 一覧の変数 | 内容 | 対象の事象 |
| --- | --- | --- |
| `_MAKEFW_FORCED_COPY_TARGETS` | `CP_SRCS` のファイル名のうち、カレント ディレクトリにシンボリック リンクとして存在するもの | リンクからコピーへの切り替わり (inject ファイルまたはフィルター ファイルの追加) |
| `_MAKEFW_FORCED_LINK_TARGETS` | 分類の手順 3 で外したソースのファイル名 (カレント ディレクトリに通常のファイルとして存在するもの) | コピーからリンクへの切り替わり (inject ファイルまたはフィルター ファイルの削除) |

- 両方の一覧は Linux だけで求めます。Windows では空です。
- `_MAKEFW_FORCED_COPY_TARGETS` のリンクの検出には、既存の `_makefw_source_link_names` と `_makefw_source_link_scan` を使います。`DIRECT_SRCS` の判定ですでに走査した場合は、その結果を再利用し、走査は解析 1 回につき最大 1 回にします。`CP_SRCS` が空なら走査しません。
- 常に実行させる前提条件は、空の規則を持つ `.PHONY` のターゲット `_makefw_force_placement` です。
- ファイルの削除と置き換えは、レシピの中だけで行います。解析時にはファイルを変更しないため、`make -n` (ドライ ラン) はファイルを変えません。
- 置き換えが起きたビルドでは、配置したファイルに依存するオブジェクトが再コンパイルされます。次のビルドからは、通常の更新時刻の判定に戻ります。

### _collect_srcs.mk の変更

- 先頭の「出力 (ソース ファイルの扱い)」のコメントを、上記の分類の仕様に合わせます。`DIRECT_SRCS` は「カレント ディレクトリにあるソースを指す指定」、`EXTERNAL_SRCS` は「外部のソースと同名のローカル実体があり、`DIRECT_SRCS` から外したソース」とし、出力に `_MAKEFW_FORCED_COPY_TARGETS` と `_MAKEFW_FORCED_LINK_TARGETS` を加えます。
- `DIRECT_SRCS` の判定の Step 2 の直後に、Step 3 として次を加えます。

    ```make
    # Step 3: 外部のソースと同名のローカル実体を除外する
    # 以前の引き込み (コピー) が残したものとして扱い、引き込み直す。
    _EXTERNAL_SOURCE_DIRS := $(call _makefw_source_dirs_of_kind,$(DIRECT_SRCS),external missing)
    EXTERNAL_SRCS := $(call _makefw_sources_in_dirs,$(DIRECT_SRCS),$(_EXTERNAL_SOURCE_DIRS))
    DIRECT_SRCS := $(filter-out $(EXTERNAL_SRCS),$(DIRECT_SRCS))
    ```

- `ifdef PLATFORM_WINDOWS` のブロックから、`EXTERNAL_SRCS` を求めて `CP_SRCS` へ加える 4 行を削除します。Step 3 で外したソースは `LINK_SRCS` に入り、同じブロックの `CP_SRCS += $(LINK_SRCS)` でコピーの対象になるためです。
- Linux の `_MISSING_LINK_SRCS` の検査の後に、次の処理を加えます (実装の形は同等であればよい)。

    ```make
    # 以前の引き込みの残骸を、配置の規則で必ず置き換えさせる (Linux)
    _MAKEFW_FORCED_COPY_TARGETS :=
    _MAKEFW_FORCED_LINK_TARGETS :=
    ifdef PLATFORM_LINUX
        ifneq ($(strip $(CP_SRCS)),)
            ifeq ($(origin _DIRECT_SYMLINK_NAMES),undefined)
                _DIRECT_SYMLINK_NAMES := $(call _makefw_source_link_names,$(_makefw_source_link_scan))
            endif
            _MAKEFW_FORCED_COPY_TARGETS := $(patsubst ./%,%,$(filter $(addprefix ./,$(notdir $(CP_SRCS))),$(_DIRECT_SYMLINK_NAMES)))
        endif
        _MAKEFW_FORCED_LINK_TARGETS := $(notdir $(filter $(EXTERNAL_SRCS),$(LINK_SRCS)))
    endif
    ```

    `_DIRECT_SYMLINK_NAMES` は既存の Step 2 の変数です。名前が走査結果の共有を表すように、`_SOURCE_LINK_NAMES` などへ改名してもかまいません。

### makesrc_c_cpp.mk と makelibsrc_c_cpp.mk の変更

2 つのテンプレートに同じ変更を入れます。

- `generate_link_src_rule`: 前提条件に `$(if $(filter $(1),$(_MAKEFW_FORCED_LINK_TARGETS)),_makefw_force_placement)` を加えます。レシピの `ln -sf $(2) $(1)` は、通常のファイルを置き換えるため変更しません。
- `generate_cp_src_rule`:
    - 前提条件の末尾に `$(if $(filter $(1),$(_MAKEFW_FORCED_COPY_TARGETS)),_makefw_force_placement)` を加えます。
    - レシピの先頭に `@rm -f $(1)` を加えます。コピー先がリンクの場合に、`cp` が同じファイルと判定して失敗すること、およびフィルターのリダイレクトがリンクを辿ってコピー元を書き換えることを防ぎます。コピー先が通常のファイルの場合も、従来どおり上書きと同じ結果になります。両 OS で同じレシピです。
- `generate_cp_src_rule` の `$(foreach ...)` の直前に、次を置きます。既定のゴールより後に定義されるため、既定のゴールは変わりません。

    ```make
    # 以前の引き込みの残骸を置き換えるため、配置の規則を必ず実行させる
    .PHONY: _makefw_force_placement
    _makefw_force_placement:
    ```

### docs/makeparts.md の変更

- 「外部ソースは配置後も元ソースの更新を追跡します」の節: 「Linux ではローカルの同名実体を優先して」の文を、「外部ソースと同名のローカル実体は、以前の引き込みが残したものとして扱い、Linux ではリンクへ、Windows ではコピーへ、次のビルドで置き換えます」という趣旨に改めます。
- 「ビルド システムによるソース ファイルの分類」の表: `DIRECT_SRCS` の条件を「指定したソースがカレント ディレクトリにある」に改めます。
- 同じ節に、inject ファイルやフィルター ファイルを追加・削除すると、次のビルドで引き込み方が切り替わり、以前のリンクやコピーは自動で置き換わることを追記します。

### テストの追加 (bin_test/source_classification_selftest.py)

- 既存の末尾の確認 (`native platform local-file precedence`) の Linux の期待値を `DIRECT=0 COPY=0 LINK=80` に改め、`build` の後に、そのファイルがリンクに置き換わったことを確認します。Windows の期待値 (`DIRECT=0 COPY=80 LINK=0`) は変えません。表示は `PASS: local file with an external source name is replaced` などに改めます。
- 関数 `check_source_switch(root, home, env)` を追加し、`main()` から呼びます。Windows では `SKIP: 引き込み方の切り替わり (Windows は常にコピーで引き込みます)` を出力して返します。
- 確認は、ライブラリのテンプレート (`app/probe/prod/libsrc/switch`) と実行体のテンプレート (`app/probe/prod/src/switch`、`main.c` を置く) の 2 つのディレクトリで、それぞれ外部の `a.c` と `b.c` を `ADD_SRCS` で引き込み、次の順に行います。更新時刻の比較が必要な箇所では、既存と同じく `time.sleep(1.1)` を挟みます。

| 段階 | 操作 | 確認 |
| --- | --- | --- |
| 1 | `build` | `a.c` と `b.c` がシンボリック リンク |
| 2 | `a.inject.c` を追加した後に外部の `a.c` を編集し、`make -n build` | `a.c` がシンボリック リンクのまま (ドライ ランはファイルを変えない) |
| 3 | `build` | 成功し、`a.c` が通常のファイルで、段階 2 の編集後の内容と、末尾の `#include "a.inject.c"` がある |
| 4 | `build` を再実行 | オブジェクトの更新時刻が変わらない |
| 5 | 外部の `a.c` を編集し、`build` | ローカルの `a.c` に編集後の内容と inject の結合がある |
| 6 | `b.c.filter.sh` (`sed 's/return 2/return 20/'`) を追加し、`build` | 外部の `b.c` の内容が変わらない。ローカルの `b.c` が通常のファイルで、`return 20` を含む |
| 7 | `a.inject.c` と `b.c.filter.sh` を削除し、`build` | 成功し、`a.c` と `b.c` がシンボリック リンク |
| 8 | 外部の `b.c` を編集し、`build` | ローカルの `b.c` (リンク) を通して編集後の内容が見え、`b` のオブジェクトが再コンパイルされる |

> [!NOTE]
> 段階 3 はリンクからコピーへの切り替わり (`cp: ... are the same file` の失敗と、inject ファイルの追加後にコピー元を編集した場合にコピーの規則が起動しない取りこぼし)、段階 5 はコピーの通常の更新、段階 6 はフィルターによるコピー元の破損、段階 7 と 8 はコピーからリンクへの切り替わりを確認します。

## BL-029 bin_test の文字コードの指定

- `bin_test/app_paths_selftest.py` の 71、72、143 行目の `read_text()` を `read_text(encoding="utf-8")` にします。
- `bin_test/test_path_spaces.py` の 123、156、174 行目の `warning.read_text(errors="replace")` を `warning.read_text(encoding="utf-8", errors="replace")` にします。

> [!NOTE]
> `errors="replace"` の除去は、この対策の範囲外です。この案件の残課題一覧に記録しています。

## BL-030 統合ワークスペースの外での test_path_spaces.py

`bin_test/test_path_spaces.py` の `test_environment_sync_preserves_paths` の先頭で、読み取る次の 6 つのファイルの存在を確認します。いずれかがなければ、`self.skipTest(f"統合ワークスペースのファイルがありません: {missing}")` で飛ばします。

- `<workspace>/app/general/bin/sync-app-env.sh`
- `<workspace>/.vscode/` の `c_cpp_properties.json`、`.env.linux`、`.env.windows`、`settings.json`、`pub_markdown.config.yaml`

`<workspace>` は既存の `MAKEFW.parents[1]` です。ファイル名の並びは、存在の確認と複製の処理で同じ定義を使い、二重に書かないようにします。

## BL-002 MSVC の差分ビルドで古いオブジェクトが残る問題

### 進め方

1. Windows 側の Claude Code が、全体管理文書の「Windows 側への依頼手順 (BL-002)」で再現と記録を行います。
2. 結果を次の仮説に当てはめ、原因を特定します。
3. 原因と、それに応じた具体的な修正内容と再現テストを、この章の「確定した修正」に追記します。追記した内容は、実施の前に承認を受けます。
4. 承認後、Windows 側の Claude Code が修正と再現テストの追加を行い、主エージェントが結果を確認します。

> [!IMPORTANT]
> この最終仕様の承認は、BL-001、BL-029、BL-030 の実施と、BL-002 の上記の進め方を対象とします。BL-002 の具体的な修正は、手順 3 の追記と承認を経るまで実施しません。

### 仮説と対応の分岐

| 仮説 | 内容 | 見分け方 | 原因と確定した場合の対応 |
| --- | --- | --- | --- |
| H1 | `.d` に `mock_cplat.h` が記録されていない (`/sourceDependencies` の JSON に出ない、または PCH の JSON が加えられていない) | `obj/md/mock_cplat_expand_format.d` と `.cc.json`、`auto_*.pch.deps.json` の `Includes` | `msvc_compile.ps1` の `.d` の生成を直す |
| H2 | `.d` には記録されているが、`find_dirty_srcs.sh` の照合に失敗している (大文字小文字、空白の保護、ワークスペースの接頭辞の表記) | `find_dirty_srcs.sh` の単独の実行結果と `WORKSPACE_DIR` の表記 | `find_dirty_srcs.sh` または `.d` の書き出しの表記を直す |
| H3 | 判定は正しいが、ヘッダーの更新時刻が進んでいない | `ls -l --time-style=full-iso` によるヘッダー、`.obj`、`.d` の比較 | makefw の外の要因として結論を記録し、残課題を閉じる |
| H4 | 判定は正しいが、このディレクトリのコンパイルの規則が起動していない | `make -n` の出力 | `_msvc_compile.mk` またはサブディレクトリの走査を直す |
| H5 | 再コンパイルは起きるが、PCH (`auto_*.pch`) が作り直されず、変更前のヘッダーの内容でコンパイルされている | 差分ビルドの後の `.pch` の更新時刻と、`grep -a` による `.obj` と `.pch` の中の `/INCLUDE:` の確認 | `_msvc_pch.ps1` の作り直しの判定を直す |
| なし | 再現しない | 手順のすべてで古いオブジェクトが残らない | 確認した手順と結果を記録し、残課題の扱い (閉じるか、再発時の調査に残すか) をユーザーに確認する |

再現テストは、原因が makefw にある場合に `bin_test/msvc_pch_selftest.ps1` へ追加します。ヘッダーを別のディレクトリに置き、`-I` 経由の `<...>` で取り込み、PCH を使う構成で、ヘッダーを変えた差分ビルドの後に、取り込むオブジェクトが作り直されて変更後の内容になることを確認します。修正の規模が大きい場合は、追記の時点で範囲をあらためて確認します。

### 確定した修正

makefw のコードは変更しません。Windows 側の再現の結果、仮説のどれにも当てはまらず、事象は再現しませんでした (分岐「なし」)。

- 手順 4 (更新時刻だけを進める): `find_dirty_srcs.sh` が `mock_cplat.cc` と `mock_cplat_expand_format.cc` を作り直しの対象として出力し、差分ビルドで両方が再コンパイルされました。
- 手順 5 (ヘッダーに `MOCK_CPLAT_LINK_IMPL(makefw_bl002_probe)` を追加): 作り直されたオブジェクトが `/INCLUDE:_mock_impl_makefw_bl002_probe` を持ち、期待どおり `LNK2001` で失敗しました。
- 手順 6 (ヘッダーを元に戻す): 差分ビルドとテストが成功し、`LNK2001` は残りませんでした。`grep` で古い記号を持つ `.obj` と `.pch` は 0 件でした。

元の事象は、再発時に調べる残課題として、この案件の残課題一覧へ送ります。再現テスト (`msvc_pch_selftest.ps1` への追加) は行いません。受入条件 AC-7 は、修正がないため対象外です。

## 受入条件

| ID | 課題 | 条件 |
| --- | --- | --- |
| AC-1 | BL-001 | Linux で `source_classification_selftest.py` の `check_source_switch` が、ライブラリと実行体の両方のテンプレートで、段階 1 から 8 のすべてを満たす |
| AC-2 | BL-001 | Linux で、外部のソースと同名のローカル実体が `DIRECT_SRCS` にならず (`DIRECT=0 COPY=0 LINK=80`)、`build` でリンクへ置き換わる。Windows の分類 (`DIRECT=0 COPY=80 LINK=0`) と、既存の 80 本の分類・反復ビルド・更新・`clean` の確認が変わらず成功する |
| AC-3 | BL-001 | `make -n` が、置き換えの対象があってもファイルを変更しない (AC-1 の段階 2、既存のドライ ランの確認) |
| AC-4 | BL-001 | `app/cplat` を Linux と Windows でビルドし、テストが成功する。対象範囲の `.warn` に内容がない |
| AC-5 | BL-029 | `framework/makefw/bin_test` のすべての Python テストが、`python3 -X warn_default_encoding -W error::EncodingWarning` で `EncodingWarning` なく成功する。構文木の走査で、`encoding` のないテキスト入出力が 0 件 |
| AC-6 | BL-030 | `framework/makefw` だけを一時ディレクトリへ複製して `test_path_spaces.py` を実行すると、`FileNotFoundError` にならず、`test_environment_sync_preserves_paths` が理由付きで飛ばされる。統合ワークスペースでは飛ばされずに成功する |
| AC-7 | BL-002 | 「確定した修正」に追記する条件 (原因が makefw にある場合は、再現手順で古いオブジェクトが残らず、追加した再現テストが Windows で成功すること) |
| AC-8 | 文書 | 変更した Markdown が `text_style_jp.py --dry-run` で指摘なし |

## 検証手順

### Linux

並行する `make` がない状態で、リポジトリのルートから 1 本ずつ実行します。

1. 切り替わりと分類: `python3 -X warn_default_encoding -W error::EncodingWarning framework/makefw/bin_test/source_classification_selftest.py` (AC-1 から AC-3)
2. 変更した 2 ファイル: `python3 -X warn_default_encoding -W error::EncodingWarning framework/makefw/bin_test/app_paths_selftest.py` と、同じオプションでの `framework/makefw/bin_test/test_path_spaces.py`
3. `bin_test` の全体: `framework/makefw/bin_test/*.py` を、同じオプションで 1 本ずつ実行する (AC-5)
4. 構文木の走査: `framework/makefw/bin_test/*.py` の `open`、`read_text`、`write_text`、テキスト モードの `subprocess` で、`encoding` のないものを列挙し、0 件を確認する (AC-5)
5. 単独の作業ツリー: `framework/makefw` を一時ディレクトリ (たとえば `<tmp>/standalone/makefw`) へ `cp -r` で複製し、`python3 <tmp>/standalone/makefw/bin_test/test_path_spaces.py -v` で該当のテストが `skipped` になることを確認する (AC-6)。Git の作業ツリーの追加は行いません
6. 実プロジェクト: `make -C app/cplat` と `make -C app/cplat test` を実行し、`app/cplat` 配下の `.warn` を確認する (AC-4)。`app/cplat` は inject を使うテスト (`test/src/libcplatTest/console/consoleTest` など) を含みます
7. 文書: `python3 framework/docsfw/bin/text_style_jp.py --dry-run framework/makefw/docs/makeparts.md`。指摘があれば内容を確認して `--in-place` (AC-8)

> [!NOTE]
> テンプレートの変更はすべての app のビルドに及びます。framework と複数 app にまたがる全体のテストは、コストを説明してユーザーに確認したうえで行います。

### Windows (Windows 側の Claude Code へ依頼)

Linux での検証の後、変更を Windows 側の作業ツリーへ反映して、Git Bash でリポジトリのルートから 1 本ずつ実行します。

1. `python framework/makefw/bin_test/source_classification_selftest.py` (Windows の分類が変わらないこと、`check_source_switch` が `SKIP:` を出力すること。AC-2)
2. `make -C app/cplat` と `make -C app/cplat test`。`app/cplat` 配下の `.warn` を確認する (AC-4)
3. BL-002 の再現テストを追加した場合は、`powershell -NoProfile -ExecutionPolicy Bypass -File framework/makefw/bin_test/msvc_pch_selftest.ps1` (AC-7)

持ち帰るデータ: 各コマンドの終了コードと出力の末尾、内容のある `.warn` の一覧。

## 正本ドキュメントとコード コメントへの反映計画

| 反映先 | 内容 |
| --- | --- |
| `framework/makefw/docs/makeparts.md` | 外部のソースと同名のローカル実体の扱い (両 OS で置き換える)、`DIRECT_SRCS` の条件、引き込み方の切り替わりが次のビルドで自動的に反映されること |
| `framework/makefw/makefiles/_collect_srcs.mk` のコメント | 分類の手順 3 の理由 (同名のローカル実体を以前の引き込みの残骸として扱う)、置き換えを強制する 2 つの一覧の意味 |
| `generate_cp_src_rule` のコメント (2 つのテンプレート) | レシピの先頭の削除の理由 (コピー先が古いリンクの場合の `cp` の失敗と、リダイレクトによるコピー元の書き換えの防止) |
| `_makefw_force_placement` のコメント (2 つのテンプレート) | 解析時に検出した残骸を、レシピでだけ置き換える (ドライ ランでファイルを変えない) こと |
| BL-002 の確定した修正の対象 | なし (再現しなかったため、コードとコメントは変更しない) |

> [!NOTE]
> 対策元の残課題一覧で手作業の後始末として案内していた内容 (古いリンクを手で削除する手順) は、正本へは記載しません。
