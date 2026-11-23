<!--
生成元: agree-before-implement スキル
文書種別: 最終仕様 (design)
最終更新日時: 2026-11-18 02:47:29 JST
最終更新エージェント: claude code (Opus 5.5) / セッション ID: session_01KJc53TxVv1vjB6xMfjiUgc
稼働 OS: Windows
上流文書: `261116-makefw-subdir-rebuild-race-discussion.md` (検討用 Markdown)。削除されている場合があります。
再開手順: このファイルを開いたエージェントは、作業の前に agree-before-implement スキルを読み込んでください。上流文書が存在する場合は、上流文書の再開手順に従って進行位置を確認し、判断の経緯を上流文書の Q&A で確認します。存在しない場合は、この文書を単体の最終仕様として扱います。最終更新エージェントのセッション情報や稼働 OS・最終更新日時が参照可能であれば再開時のコンテキストや環境差分の把握に利用し、別エージェントや別環境・別 OS からの引き継ぎ、担当変更によりセッションが見つからない場合も異常とせず、文書の記載から継続してください。
-->

# makefw サブディレクトリ走査の並列ビルド失敗の修正 最終仕様

ファイル名: `261116-makefw-subdir-rebuild-race-design.md`

版: 3

## 目的と範囲

Linux の CI で、サブディレクトリを持つライブラリのビルドが次のメッセージで不定期に失敗しました。  
この文書は、その原因と、原因の調査で見つかった関連する問題に対する修正を定めます。

```text
make[6]: *** '../../lib/libmock_cplat.a' に必要なターゲット 'crt/obj/mock_cplat_ftell.o' を make するルールがありません.  中止.
```

対象は `framework/makefw` と `framework/testfw` です。  
`app/` 配下の makefile、ソース、テストは変更しません。

修正は次の 7 点です。  
1 番から 3 番が CI の失敗に対する修正で、4 番から 7 番は調査と検証で見つかった問題に対する修正です。

1. 自動 PCH を使うオブジェクトが、`make` のたびに再コンパイルされる問題を直します。
2. 親の make が、サブディレクトリの再帰 make の完了を待たずにオブジェクトを確認する問題を直します。
3. 1 回の `make` で同じサブディレクトリを 2 回たどる構造を、1 回にします。
4. Windows で、何もない状態からの `make test` が、リンクしないサブディレクトリをコンパイルしない問題を直します。
5. テストの起点とサブディレクトリの両方にテスト対象のソースがある構成で、全体のカバレッジにサブディレクトリのソースが入らない問題を直します。
6. `framework/makefw/docs/subfolder-compilation.md` を、現在の実装と実際の出力に合わせて見直します。
7. サブディレクトリの中で並列 `make` を実行したとき、親の成果物の更新がコンパイルの完了を待たない問題を直します。

## 原因

### CI の失敗の原因

失敗は、makefw にある 2 つの問題が重なって起きます。  
どちらも Linux/GCC だけの問題です。

#### 自動 PCH を使うオブジェクトが毎回再コンパイルされる

コンパイルの規則は、依存ファイル (`.d`) をオブジェクトの前提にしています。

```makefile
$(OBJDIR)/%.o: %.c $(OBJDIR)/%.d ...
```

自動 PCH を使うコンパイルでは、コンパイルが成功した後に `gcc_pch.py record` が `.d` へ PCH の依存を追記します。  
この追記で `.d` の更新日時がオブジェクトより新しくなり、make は次の評価でオブジェクトを古いと判定します。  
その結果、自動 PCH を使うオブジェクトは `make` のたびに再コンパイルされ、成果物も再リンクされます。  
サブディレクトリを持たないディレクトリでも同じです。

#### 親の make がサブディレクトリの make の完了を待たない

サブディレクトリを持つライブラリと実行体のリンクの規則は、サブディレクトリの再帰 make と、サブディレクトリのオブジェクトを、同じ規則の前提に並べています。

```makefile
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_OBJS) | ...
```

`MAKEFW_ARTIFACT_DEPS` は `$(SUBDIRS)` (再帰 make を起動する PHONY ターゲット) です。  
`MAKEFW_ARTIFACT_OBJS` には、makefile の読み込み時に存在したサブディレクトリのオブジェクトが含まれます。  
両者の間に順序の指定がないため、並列ビルドでは、親の make が再帰 make の完了を待たずにオブジェクトの存在を確認します。

GCC が既存のオブジェクトを上書きするとき、アセンブラーは出力先を削除してから作り直します。  
その間 (Oracle Linux 8 の測定で約 0.25 ミリ秒) はオブジェクトが存在しません。  
この瞬間に親の確認が当たると、親の makefile にはそのオブジェクトを作る規則がないため、make は「make するルールがありません」で止まります。

> [!NOTE]
> この競合は、自動 PCH と無関係に単独でも起きます。  
> `make test` では、サブディレクトリの再帰 make とリンクの規則が同じ make の中で並列に処理されます。  
> サブディレクトリのソースを更新してから `make test` を実行すると、再コンパイル中のオブジェクトに親の確認が当たる可能性があります。

#### 同じサブディレクトリを 2 回たどる構造

サブディレクトリを持つライブラリと実行体では、1 回の `make` で各サブディレクトリを 2 回たどります。

1. `makemain.mk` の `build: $(SUBDIRS)` が、`build` の前提として各サブディレクトリをビルドします。
2. `build` のレシピ (`_MAKEFW_LEAF_PARALLEL_RECIPE`) が、並列度を決めて同じディレクトリの `make _build_impl` を起動し直します。その make の中で、リンクの規則の前提 `$(SUBDIRS)` が各サブディレクトリをもう一度たどります。

2 回目は本来は何もしませんが、自動 PCH を使うオブジェクトの再コンパイルがここで起き、親の確認との競合につながりました。  
2 回目は、サブディレクトリごとの make の起動と makefile の読み込みの分だけ、ビルド時間も増やします。

### Windows の make test がサブディレクトリをコンパイルしない原因

リンクしないディレクトリ (`NO_LINK` を指定したサブディレクトリ) の `_test_build` は、2 つのテンプレートで次のように定義されています。

```makefile
_test_build: $(OBJS)
```

Windows のコンパイルは `_msvc_compile` ターゲットがまとめて行い、`$(OBJS)` の個別の規則を使いません。  
このため、Windows で `make` を先に実行せずに `make test` を実行すると、サブディレクトリは何もコンパイルされません。  
サブディレクトリのテストは実行されず、起点のテストだけが成功として報告されます。  
その後に `make` を実行しても、`make test` は「変更なし」と判定してテストを省略するため、不足した結果が残ります。

`build` の経路は `$(if $(PLATFORM_WINDOWS),_msvc_compile,$(OBJS))` で切り替えており、`_test_build` だけ切り替えがありません。  
`make` の後に `make test` を実行する手順と CI では起きません。Linux でも起きません。

### 全体のカバレッジにサブディレクトリのソースが入らない原因

`framework/testfw/bin_internal/exec_test_c_cpp.sh` は、起点の `TEST_SRCS` が空の場合にだけ、サブディレクトリの `TEST_SRCS` を集めます。  
起点とサブディレクトリの両方が `TEST_SRCS` を指定する構成では、全体のカバレッジ (`results/all_tests/`) と `summary.md` の MD5 の表が、起点の `TEST_SRCS` だけを対象にします。  
サブディレクトリのソースのカバレッジは、個別のテストの結果にだけ出力されます。

この動作は Linux と Windows で共通です。  
リポジトリの中で該当する構成は、`app/subfolder-sample` のテストだけです。

### サブディレクトリの中での並列 make で親の成果物が再リンクされない原因

リンクしないディレクトリの `_build_main` は、オブジェクトのコンパイルと、親の成果物を更新する make の起動 (`_makefw_parent_artifact`) を、順序なしで同じ規則の前提に並べています。

```makefile
_build_main: $(if $(PLATFORM_WINDOWS),_msvc_compile,$(OBJS)) $(if $(MAKEFW_SHOULD_BUILD_PARENT_ARTIFACT),_makefw_parent_artifact)
```

`_makefw_parent_artifact` は、利用者がサブディレクトリの中で `make` を実行したときだけ前提に加わります。  
並列指定付きで実行すると、親の make がコンパイルの完了を待たずに始まり、更新前のオブジェクトを見てリンクを省略します。  
エラーにはならないため、親の成果物が古いまま残ったことに気付きにくいです。

Linux (Oracle Linux 8) では、ソースを更新したサブディレクトリで `make -j4` を実行すると、4 回中 4 回、再リンクされませんでした。  
Windows では再現しませんでしたが、`_msvc_compile` と `_makefw_parent_artifact` の間に順序がない構造は同じです。

## 変更内容

### gcc_pch.py の record

対象: `framework/makefw/bin_internal/gcc_pch.py` の `record()`

`.d` へ追記した後、`.d` の更新日時をオブジェクトと同じにします。

- `--target` が指定され、そのファイルが存在する場合に、`os.utime()` で `.d` のアクセス日時と更新日時をオブジェクトの値に合わせます。
- `--target` がない場合と、オブジェクトが存在しない場合は、更新日時を変更しません。
- `.d` の内容 (PCH と、PCH 内のヘッダーへの依存) は変更しません。

make は、前提がターゲットより新しい場合にだけターゲットを作り直します。  
更新日時が同じであれば作り直さないため、追記による再コンパイルがなくなります。  
`.d` の削除、ヘッダーの更新、PCH の作り直しによる再コンパイルは、これまでどおり働きます。

コードには、更新日時を合わせる理由と、根拠 (`see: https://www.gnu.org/software/make/manual/html_node/Rule-Syntax.html`) をコメントで残します。

### サブディレクトリのオブジェクトの確認の順序

対象: `framework/makefw/makefiles/makelibsrc_c_cpp.mk`、`framework/makefw/makefiles/makesrc_c_cpp.mk`

サブディレクトリのオブジェクトごとに、「そのオブジェクトが属するサブディレクトリの再帰 make」を順序だけの前提 (order-only prerequisite) とする規則を追加します。

```makefile
# 例: crt/obj/mock_cplat_ftell.o: | crt/
```

- 対象は `SUBDIR_OBJS` の各オブジェクトです。パスの先頭のディレクトリ名から、`$(SUBDIRS)` の該当する要素を求めます。`$(SUBDIRS)` の要素は、自動検出では末尾に `/` が付き、明示指定では付かない場合があるため、両方の書き方に対応します。
- `$(SUBDIRS)` に該当する要素がないオブジェクト (OS による除外などでたどらないサブディレクトリのもの) には、規則を追加しません。
- リンクの規則がサブディレクトリをたどらない make (`MAKEFW_ARTIFACT_ONLY` が指定された make と、次の節の「サブディレクトリを処理済みの make」) では、規則を追加しません。追加すると、たどらないはずのサブディレクトリを前提として起動してしまうためです。
- リンクの規則と、レシピの中のリンク要否の判定 (`_MAKEFW_OBJLIST`) は変更しません。

これにより、make は、サブディレクトリの再帰 make が終わってから、そのサブディレクトリのオブジェクトを確認します。

コードには、順序だけの前提にする理由と、根拠 (`see: https://www.gnu.org/software/make/manual/html_node/Prerequisite-Types.html`) をコメントで残します。

### サブディレクトリを 1 回だけたどる

対象: `framework/makefw/makefiles/_flags.mk`、`framework/makefw/makefiles/makelibsrc_c_cpp.mk`、`framework/makefw/makefiles/makesrc_c_cpp.mk`

`build` の前提としてたどる 1 回目を残し、`build` のレシピが起動し直す make でたどる 2 回目をやめます。

- `_MAKEFW_LEAF_PARALLEL_RECIPE` は、起動し直す make へ、変数 `MAKEFW_SUBDIRS_DONE_DIR` で自ディレクトリのパス (`$(CURDIR)`) を渡します。空白を含むパスでも渡せるよう、値を引用符で囲みます。
- 2 つのテンプレートは、`MAKEFW_SUBDIRS_DONE_DIR` が自ディレクトリのパスと一致する場合に、その make を「サブディレクトリを処理済みの make」と判定します。
- サブディレクトリを処理済みの make では、`MAKEFW_ARTIFACT_DEPS` を `$(SUBDIRS)` ではなく `_makefw_artifact_recheck` にします。`_makefw_artifact_recheck` は既存の PHONY ターゲットで、リンクのレシピを毎回起動して、オブジェクトとの日時の比較でリンクの要否を判定させます。
- `MAKEFW_ARTIFACT_OBJS` は変更しません。ルート直下のソースは、これまでどおりこの make がコンパイルします。

> [!NOTE]
> 値をディレクトリのパスにするのは、コマンド ラインで渡した変数が、その make から起動される下位の make にも引き継がれるためです。  
> パスが一致する make だけが「処理済み」と判定するので、下位のディレクトリの動作は変わりません。

> [!IMPORTANT]
> 変更するのは `build` の経路だけです。  
> `make test` (`_test_build`) の経路は、1 つの make の中でサブディレクトリを 1 回だけたどるため、変更しません。  
> この経路では、サブディレクトリの再帰 make とリンクの規則が並列に処理されるので、前の節の順序だけの前提が競合を防ぎます。

サブディレクトリへ渡るゴール、ビルド前後のフックの順序、`NO_LINK` のサブディレクトリの下にあるサブディレクトリの扱いは変わりません。  
サブディレクトリのフック (`pre-build`、`post-build`) は、これまで 1 回の `make` で 2 回実行されていましたが、1 回になります。

この変更は Windows にも適用されます。  
Windows のリンクの規則も `MAKEFW_ARTIFACT_DEPS` を前提にしているためです。

### リンクしないディレクトリの _test_build

対象: `framework/makefw/makefiles/makelibsrc_c_cpp.mk`、`framework/makefw/makefiles/makesrc_c_cpp.mk`

`NO_LINK` が指定されたディレクトリの `_test_build` の前提を、`build` の経路と同じ切り替えにします。

```makefile
# 変更前
_test_build: $(OBJS)
# 変更後
_test_build: $(if $(PLATFORM_WINDOWS),_msvc_compile,$(OBJS))
```

- Windows では、`make test` が `_msvc_compile` を起動し、サブディレクトリのソースをコンパイルします。
- Linux の前提は `$(OBJS)` のままで、動作は変わりません。
- `SKIP_BUILD` が指定された場合の分岐と、リンクするディレクトリの `_test_build` は変更しません。

### 全体のカバレッジの対象の収集

対象: `framework/testfw/bin_internal/exec_test_c_cpp.sh`

起点の `TEST_SRCS` の有無に関係なく、サブディレクトリの `TEST_SRCS` を集めます。

- サブディレクトリの makefile ごとに `TEST_SRCS` を問い合わせる処理 (`query_test_sources.mk`) は、そのまま使います。変更するのは、この処理を実行する条件です。
- 対象のソースの並びは、起点の `TEST_SRCS` を指定された順のまま先に置き、サブディレクトリから集めたソースをパスの昇順で続けます。すでに含まれているソースは追加しません。
- 起点に `TEST_SRCS` があり、サブディレクトリに `TEST_SRCS` がないテストでは、対象のソースと並びは変更前と同じです。
- 起点の `TEST_SRCS` が空のテストでは、対象のソースと並びは変更前と同じです。

Windows では、カバレッジの計測対象の指定 (OpenCppCoverage の `--sources`) も変更します。

- 変更前は、すべてのソースを「起点のディレクトリ + ファイル名」で指定しています。
- 変更後は、ソースごとに、そのソースを `TEST_SRCS` に指定した makefile のディレクトリを記録し、「そのディレクトリ + ファイル名」で指定します。テスト対象のソースは、指定した makefile のディレクトリへ取り込まれてコンパイルされるためです。
- 起点の `TEST_SRCS` のソースは、変更前と同じ指定になります。

> [!NOTE]
> サブディレクトリの問い合わせは、サブディレクトリの makefile ごとに make を 1 回起動します。  
> この変更により、起点に `TEST_SRCS` があり、かつ makefile を持つサブディレクトリがあるテストでは、テストの実行のたびにこの起動が加わります。  
> サブディレクトリを持たないテストでは、起動は増えません。

テストの省略の判定 (変更がなければテストを実行しない動作) は、集めた後のソースの一覧で行います。  
サブディレクトリのテスト対象のソースを更新した後の `make test` は、テストを再実行します。

### 親の成果物の更新の順序

対象: `framework/makefw/makefiles/makelibsrc_c_cpp.mk`、`framework/makefw/makefiles/makesrc_c_cpp.mk`

`_makefw_parent_artifact` に、コンパイルを順序だけの前提として加えます。

```makefile
_makefw_parent_artifact: | $(if $(PLATFORM_WINDOWS),_msvc_compile,$(OBJS))
```

- Linux と Windows の両方に適用します。
- `_makefw_parent_artifact` が親で行う処理 (`MAKEFW_ARTIFACT_ONLY=1` でのリンクの要否の判定) は変更しません。
- 実行体のテンプレートの `_build_main` に並ぶ `$(LIBSFILES)` は、順序の対象に含めません。親のリンクの依存は、親の make が判定するためです。

コードには、順序が必要な理由をコメントで残します。

### テスト

対象:

- `framework/makefw/bin_test/gcc_pch_selftest.py` (変更)
- `framework/makefw/bin_test/subdir_build_selftest.py` (新規)
- `framework/testfw/bin_test/test_path_spaces.py` (変更)

`gcc_pch_selftest.py` には、`record` の後で `.d` の更新日時がオブジェクトより新しくないことの確認を追加します。

`subdir_build_selftest.py` は、一時ディレクトリにサブディレクトリを持つ小さなライブラリを作り、実際のテンプレートで `make` を実行します。  
`link_objects_selftest.py` と同じく Linux だけで実行します (`BIN_TEST_PLATFORM = "linux"`)。  
確認する内容は次のとおりです。

| 確認 | 内容 |
| --- | --- |
| 再実行で再コンパイルしない | 自動 PCH が使われる構成で、変更なしの `make` の再実行がコンパイルもリンクも行わない。 |
| 必要な再コンパイルは行う | 共通ヘッダーの更新後は PCH を使うソースを再コンパイルし、`.d` を 1 個削除した後はそのソースだけを再コンパイルする。 |
| サブディレクトリを 1 回だけたどる | 1 回の `make` で、各サブディレクトリの make の起動が 1 回である。 |
| 競合しない | オブジェクトが存在しない時間を広げた状態 (コンパイルの前にオブジェクトを消して待つスクリプトを `CC` に指定) で、サブディレクトリのソースを更新した後の `make test` が成功する。 |
| 成果物が正しい | サブディレクトリのソースの更新、削除、復元の後に、成果物が再リンクされる。サブディレクトリの中で `make -j4` を実行したときも、親の成果物が再リンクされる。 |

Table: subdir_build_selftest.py の確認内容

`test_path_spaces.py` には、起点とサブディレクトリの両方に `TEST_SRCS` がある構成のテストを追加します。  
既存の `test_sources_collected_from_child` (起点の `TEST_SRCS` が空の構成) と同じ方式で、一時ディレクトリの構成に対して `exec_test_c_cpp.sh` を実際に実行します。  
Linux と Windows の両方で実行します。確認する内容は次のとおりです。

| 確認 | 内容 |
| --- | --- |
| MD5 の表 | `summary.md` の MD5 の表に、起点のソースとサブディレクトリのソースの両方が入る。 |
| 全体のカバレッジ | `summary.md` のカバレッジの表と `results/all_tests/` の `*.gcov.md` に、両方のソースが入る。 |
| 並び | 起点のソースが先で、サブディレクトリのソースが後に並ぶ。 |

Table: test_path_spaces.py に追加する確認内容

Windows の `--sources` の変更により、既存の `test_sources_collected_from_child` の前提 (サブディレクトリが指定したソースを、起点のディレクトリでコンパイルしている) が成り立たなくなる場合は、ソースを実際の取り込み先でコンパイルする構成へ直します。

追加するテストの単体の実行時間 (Linux と Windows) を計測し、CI の所要時間の増加として、成果物の提示のときに報告します。  
対象は、`subdir_build_selftest.py` と、`test_path_spaces.py` に追加するテストです。

> [!NOTE]
> リンクしないディレクトリの `_test_build` の修正には、専用のテストを追加しません。  
> 確認は、Windows 側の一時複製で、何もない状態からの `make test` を実行して行います。

### 文書

対象: `framework/makefw/docs/subfolder-compilation.md`、`framework/makefw/docs/build-configurations.md`、`framework/makefw/docs/makeparts.md`

#### 修正に伴う追記

- `subfolder-compilation.md` の「オブジェクト ファイルの自動収集」に、サブディレクトリのオブジェクトは、属するサブディレクトリの再帰 make の完了後に確認することを追記します。「ライブラリのサブディレクトリ対応」の「ビルドの流れ」に、`make` はサブディレクトリを 1 回だけたどり、その後に親がリンクすることを追記します。
- `build-configurations.md` の「GCC は共通の include 接頭辞を .gch として再利用する」に、`.d` へ PCH の依存を追記した後、`.d` の更新日時をオブジェクトに合わせることと、その理由を追記します。

#### subfolder-compilation.md の見直し

例は、架空の名前 `app/hierarchy-example` を維持します。  
framework の文書は架空の名前を使い、実在する app のパスを正本にしない規範に従うためです。

| 番号 | 対象の箇所 | 直す内容 |
| --- | --- | --- |
| 1 | 「再帰的 make 処理」の `makemain.mk` の引用 | 現在の実装に合わせます。`SUBDIRS` を明示した場合の直列の処理、OS による除外、`test` の 2 フェーズ (`_test_build`、`_test_run`)、`_gen` を説明します。 |
| 2 | 「TEST_SRCS の自動収集」 | サブディレクトリの makefile ごとに make を起動して `TEST_SRCS` を問い合わせる現在の方式に合わせます。全体のカバレッジの説明は、この文書の「全体のカバレッジの対象の収集」の変更後の動作に合わせます。 |
| 3 | 「makefile の配置」のテンプレートの引用 | 引用をやめ、`makefiles/__template.mk` を複写するよう案内します。 |
| 4 | 架空の例に混ざった実在の名前 | マクロ (`SUBFOLDER_SAMPLE_EXPORTS`、`SUBFOLDER_SAMPLE_API`)、テスト クラス (`subfolder_sampleTest`) などを、架空の名前にそろえます。`docs/makeparts.md` の「例 3」の説明文の `libsubfolder-sample/` も、同じ例のコード ブロックの名前にそろえます。 |
| 5 | 例の中の不整合 | コマンドの出力先を、実際の出力先にそろえます。テストの起点の `TEST_SRCS` の置き場所を、`makelocal.mk` にそろえます。 |
| 6 | 「テスト レポートの構造」の出力例 | `results/` のディレクトリ構造、`summary.md`、`results.md`、`*.gcov.md` の例を、実際の出力と照合して直します。 |

Table: subfolder-compilation.md の見直しの内容

- 実装の引用は、動作の説明に必要な数行の抜粋に絞ります。残りは文章で説明し、正確な内容は実装のファイルを見るよう案内します。
- 6 番の照合に使う実際の出力は、修正後の makefw と testfw を WSL の一時複製に置き、サブディレクトリを持つテストの `make test` を実行して得ます。出力例の名前は、架空の名前に置き換えます。
- HTML のカバレッジ レポート (`all_tests/lcov/`) は、WSL の環境に `genhtml` がないため実際の出力と照合できません。この部分は、実行スクリプトの読解に基づいて記載します。

## 受入条件

1. 自動 PCH が使われる構成で、変更なしの `make` の再実行が、コンパイルもリンクも行わない。
2. 共通ヘッダーの更新、`.d` の削除、ソースの更新では、該当するソースが再コンパイルされ、成果物が再リンクされる。
3. 1 回の `make` で、各サブディレクトリの make の起動が 1 回である。
4. オブジェクトが存在しない時間を 0.3 秒に広げた状態で、次の 2 つが失敗しない。
    - 変更なしの `make` の再実行 (自動 PCH あり)
    - サブディレクトリのソースを更新した後の `make test` (自動 PCH なし)
5. サブディレクトリの中での `make`、`make test`、`make clean` が、変更前と同じ結果になる。
6. Windows で、何もない状態からの `make test` が、サブディレクトリのテストを含むすべてのテストを実行する。
7. 起点とサブディレクトリの両方に `TEST_SRCS` がある構成で、`summary.md` の MD5 の表、カバレッジの表、`results/all_tests/` の `*.gcov.md` に、両方のソースが入る。Linux と Windows の両方で成り立つ。
8. 起点だけ、またはサブディレクトリだけに `TEST_SRCS` がある構成で、全体のカバレッジの対象が変更前と同じである。
9. makefw と testfw の `bin_test/` のうち、変更に関係するテストが成功する。
10. `subfolder-compilation.md` の例に実在する app の名前が残っておらず、「見直しの内容」の 1 番から 6 番が直っている。
11. 変更した Markdown が、`text_style_jp.py --dry-run` で指摘なしになる。
12. サブディレクトリのソースを更新し、そのサブディレクトリで `make -j4` を実行すると、親の成果物が再リンクされる (Linux)。Windows では、同じ操作と、並列指定なしの `make`、`make test` の結果が変更前と変わらない。

## 検証

検証は 2 段階で行います。

### 局所検証

エージェントが、修正した makefw と testfw を一時ディレクトリへ複製して実行します。  
リポジトリの作業ツリーではビルドしません。

Linux の確認は、WSL 側の一時ディレクトリで行います。

- 受入条件 1 から 5 を、サブディレクトリを持つ小さなライブラリで確認します。
- 受入条件 7 と 8 を、サブディレクトリを持つテストで確認します。
- 次のテストを実行します。
    - makefw: `bin_test/gcc_pch_selftest.py`、`bin_test/subdir_build_selftest.py`、`bin_test/link_objects_selftest.py`、`bin_test/test_path_spaces.py`、`bin_test/test_gen_goal.py`
    - testfw: `bin_test/test_path_spaces.py`

Windows の確認は、Windows 側の一時ディレクトリ (リポジトリの外) で行います。

- 受入条件 6 と 7 を、サブディレクトリを持つテストで確認します。
- 受入条件 3 を、サブディレクトリを持つライブラリの `make` で確認します。
- 受入条件 12 を、サブディレクトリを持つライブラリのサブディレクトリの中での `make -j4` で確認します。
    - Windows では競合を再現できないため、修正の効果ではなく、動作が変わらないことを確認します。
- testfw の `bin_test/test_path_spaces.py` を実行します。

> [!NOTE]
> Windows の一時複製は、複製先のパスが長いと、相対パスの解決で 260 文字を超えて失敗します。  
> `subst` で短いドライブ名を割り当てて実行します。

Linux と Windows の確認は、同時には実行しません。

### 全体の確認

リポジトリ全体の `make`、`make test`、`make bin-test` と CI は、ユーザーが実行して確認します。

## 知見の反映計画

| 知見 | 反映先 |
| --- | --- |
| 自動 PCH の依存の追記で `.d` をオブジェクトより新しくしてはならない理由 | `gcc_pch.py` の `record()` のコメント、`build-configurations.md` |
| サブディレクトリのオブジェクトは、再帰 make の完了後に確認する必要がある理由 (上書き中はオブジェクトが一時的に存在しない) | 2 つのテンプレートのコメント、`subfolder-compilation.md` |
| `build` の経路ではサブディレクトリを 1 回だけたどり、起動し直した make ではたどらないこと | `_flags.mk` と 2 つのテンプレートのコメント、`subfolder-compilation.md` |
| Windows のコンパイルは `_msvc_compile` が行うため、オブジェクトを前提にする箇所は OS で切り替える必要があること | 2 つのテンプレートの `_test_build` のコメント |
| サブディレクトリの中での `make` では、親の成果物の更新をコンパイルの完了後に行う必要があること | 2 つのテンプレートの `_makefw_parent_artifact` のコメント |
| 全体のカバレッジの対象は、起点とサブディレクトリの `TEST_SRCS` を合わせたものであること。Windows の計測対象は、ソースが取り込まれたディレクトリで指定すること | `exec_test_c_cpp.sh` のコメント、`subfolder-compilation.md` |

Table: 知見と反映先

## 作業上の条件

- `framework/makefw` と `framework/testfw` はサブモジュールです。ステージングとコミットは、ユーザーから個別に指示された場合にだけ行います。
- 対策元の残課題一覧 (`app/porter/docs/prompts/past/261115-porter-multicast-src-contract-backlog.md`) の BL-002 は、実装と局所検証の完了時、および全体の確認の完了時に更新します。
