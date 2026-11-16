<!--
生成元: agree-before-implement スキル
文書種別: 最終仕様 (design)
最終更新日時: 2026-11-16 08:10:00 JST
最終更新エージェント: claude code / セッション ID: session_01KJc53T14fddkwQBRc7ZPQt
稼働 OS: Windows
上流文書: `261116-makefw-subdir-rebuild-race-discussion.md` (検討用 Markdown)。削除されている場合があります。
再開手順: このファイルを開いたエージェントは、作業の前に agree-before-implement スキルを読み込んでください。上流文書が存在する場合は、上流文書の再開手順に従って進行位置を確認し、判断の経緯を上流文書の Q&A で確認します。存在しない場合は、この文書を単体の最終仕様として扱います。最終更新エージェントのセッション情報や稼働 OS・最終更新日時が参照可能であれば再開時のコンテキストや環境差分の把握に利用し、別エージェントや別環境・別 OS からの引き継ぎ、担当変更によりセッションが見つからない場合も異常とせず、文書の記載から継続してください。
-->

# makefw サブディレクトリ走査の並列ビルド失敗の修正 最終仕様

ファイル名: `261116-makefw-subdir-rebuild-race-design.md`

## 目的と範囲

Linux の CI で、サブディレクトリを持つライブラリのビルドが次のメッセージで不定期に失敗しました。  
この文書は、その原因と、makefw に加える修正を定めます。

```text
make[6]: *** '../../lib/libmock_cplat.a' に必要なターゲット 'crt/obj/mock_cplat_ftell.o' を make するルールがありません.  中止.
```

対象は `framework/makefw` です。  
`app/` 配下の makefile、ソース、テストは変更しません。

修正は次の 3 点です。

1. 自動 PCH を使うオブジェクトが、`make` のたびに再コンパイルされる問題を直します。
2. 親の make が、サブディレクトリの再帰 make の完了を待たずにオブジェクトを確認する問題を直します。
3. 1 回の `make` で同じサブディレクトリを 2 回たどる構造を、1 回にします。

## 原因

失敗は、makefw にある 2 つの問題が重なって起きます。  
どちらも Linux/GCC だけの問題です。

### 自動 PCH を使うオブジェクトが毎回再コンパイルされる

コンパイルの規則は、依存ファイル (`.d`) をオブジェクトの前提にしています。

```makefile
$(OBJDIR)/%.o: %.c $(OBJDIR)/%.d ...
```

自動 PCH を使うコンパイルでは、コンパイルが成功した後に `gcc_pch.py record` が `.d` へ PCH の依存を追記します。  
この追記で `.d` の更新日時がオブジェクトより新しくなり、make は次の評価でオブジェクトを古いと判定します。  
その結果、自動 PCH を使うオブジェクトは `make` のたびに再コンパイルされ、成果物も再リンクされます。  
サブディレクトリを持たないディレクトリでも同じです。

### 親の make がサブディレクトリの make の完了を待たない

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

### 同じサブディレクトリを 2 回たどる構造

サブディレクトリを持つライブラリと実行体では、1 回の `make` で各サブディレクトリを 2 回たどります。

1. `makemain.mk` の `build: $(SUBDIRS)` が、`build` の前提として各サブディレクトリをビルドします。
2. `build` のレシピ (`_MAKEFW_LEAF_PARALLEL_RECIPE`) が、並列度を決めて同じディレクトリの `make _build_impl` を起動し直します。その make の中で、リンクの規則の前提 `$(SUBDIRS)` が各サブディレクトリをもう一度たどります。

2 回目は本来は何もしませんが、自動 PCH を使うオブジェクトの再コンパイルがここで起き、親の確認との競合につながりました。  
2 回目は、サブディレクトリごとの make の起動と makefile の読み込みの分だけ、ビルド時間も増やします。

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

### テスト

対象: `framework/makefw/bin_test/gcc_pch_selftest.py` (変更)、`framework/makefw/bin_test/subdir_build_selftest.py` (新規)

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
| 成果物が正しい | サブディレクトリのソースの更新、削除、復元の後に、成果物が再リンクされる。 |

Table: subdir_build_selftest.py の確認内容

### 文書

対象: `framework/makefw/docs/subfolder-compilation.md`、`framework/makefw/docs/build-configurations.md`

- `subfolder-compilation.md` の「オブジェクト ファイルの自動収集」に、サブディレクトリのオブジェクトは、属するサブディレクトリの再帰 make の完了後に確認することを追記します。「ライブラリのサブディレクトリ対応」の「ビルドの流れ」に、`make` はサブディレクトリを 1 回だけたどり、その後に親がリンクすることを追記します。
- `build-configurations.md` の「GCC は共通の include 接頭辞を .gch として再利用する」に、`.d` へ PCH の依存を追記した後、`.d` の更新日時をオブジェクトに合わせることと、その理由を追記します。

## 受入条件

1. 自動 PCH が使われる構成で、変更なしの `make` の再実行が、コンパイルもリンクも行わない。
2. 共通ヘッダーの更新、`.d` の削除、ソースの更新では、該当するソースが再コンパイルされ、成果物が再リンクされる。
3. 1 回の `make` で、各サブディレクトリの make の起動が 1 回である。
4. オブジェクトが存在しない時間を 0.3 秒に広げた状態で、次の 2 つが失敗しない。
    - 変更なしの `make` の再実行 (自動 PCH あり)
    - サブディレクトリのソースを更新した後の `make test` (自動 PCH なし)
5. サブディレクトリの中での `make`、`make test`、`make clean` が、変更前と同じ結果になる。
6. makefw の `bin_test/` のうち、変更に関係するテストが成功する。
7. 変更した Markdown が、`text_style_jp.py --dry-run` で指摘なしになる。

## 検証

検証は 2 段階で行います。

### 局所検証

エージェントが、修正した makefw を WSL 側の一時ディレクトリへ複製して実行します。  
リポジトリの作業ツリーではビルドしません。

- 受入条件 1 から 5 を、サブディレクトリを持つ小さなライブラリで確認します。
- 次のテストを実行します。
    - `bin_test/gcc_pch_selftest.py`
    - `bin_test/subdir_build_selftest.py`
    - `bin_test/link_objects_selftest.py`
    - `bin_test/test_path_spaces.py`
    - `bin_test/test_gen_goal.py`

### 全体の確認

リポジトリ全体の `make`、`make test`、`make bin-test` と CI は、ユーザーが実行して確認します。

> [!IMPORTANT]
> 「サブディレクトリを 1 回だけたどる」変更は Windows にも適用されますが、局所検証と追加するテストは Linux だけで実行します。  
> Windows での動作は、全体の確認 (ユーザーの `make` と CI の Windows ジョブ) で確認します。

## 知見の反映計画

| 知見 | 反映先 |
| --- | --- |
| 自動 PCH の依存の追記で `.d` をオブジェクトより新しくしてはならない理由 | `gcc_pch.py` の `record()` のコメント、`build-configurations.md` |
| サブディレクトリのオブジェクトは、再帰 make の完了後に確認する必要がある理由 (上書き中はオブジェクトが一時的に存在しない) | 2 つのテンプレートのコメント、`subfolder-compilation.md` |
| `build` の経路ではサブディレクトリを 1 回だけたどり、起動し直した make ではたどらないこと | `_flags.mk` と 2 つのテンプレートのコメント、`subfolder-compilation.md` |

Table: 知見と反映先

## 作業上の条件

- `framework/makefw` はサブモジュールです。ステージングとコミットは、ユーザーから個別に指示された場合にだけ行います。
- 対策元の残課題一覧 (`app/porter/docs/prompts/current/261115-porter-multicast-src-contract-backlog.md`) の BL-002 は、実装と局所検証の完了時、および全体の確認の完了時に更新します。
