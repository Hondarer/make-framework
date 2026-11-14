# ビルド構成の指定方法

## 対応環境

makefw は 64 ビット環境専用です。  
32 ビット環境向けのビルド設定、互換処理、回避策は一切提供しません。

## 概要

makefw の C/C++ ビルドでは、`CONFIG` 変数でビルド構成を指定します。  
未指定の場合は `RelWithDebInfo` が使用されます。

```bash
# 既定構成 (RelWithDebInfo)
make

# デバッグ構成
make CONFIG=Debug

# リリース構成
make CONFIG=Release

# 最適化あり + デバッグ情報あり
make CONFIG=RelWithDebInfo
```

`CONFIG` は再帰 make に引き継がれるため、app 直下や prod/test 直下で指定すれば、その配下のビルドに同じ構成が適用されます。

```bash
make -C app/example/prod CONFIG=Release
make -C app/example/test CONFIG=Debug test
```

## 構成ごとの用途

| 構成 | 用途 | Linux の主なフラグ | MSVC の主なフラグ |
|---|---|---|---|
| `Debug` | ステップ実行とデバッグを優先 | `-O0 -g -D_DEBUG` | `/Od /RTC1 /Zi /D_DEBUG` |
| `RelWithDebInfo` | 性能と調査しやすさのバランス | `-O2 -g -fno-omit-frame-pointer -DNDEBUG` | `/O2 /Ob2 /Zi /DNDEBUG` |
| `Release` | 配布・性能測定向け | `-O2 -g -flto -DNDEBUG` | `/O2 /Ob2 /Oy /Zi /GL /DNDEBUG` |

Table: ビルド構成別の用途およびコンパイラ フラグ一覧

`RelWithDebInfo` は、通常開発・テスト・性能調査の既定構成です。  
最適化を有効にしつつデバッグ情報を生成し、Linux ではフレーム ポインターを保持してスタック トレースやプロファイリングを安定させます。

`Release` は、LTO (Link Time Optimization) を有効にするため、ビルド時間やリンク時間が増える場合があります。  
Linux では `-flto` を使うため、既定の `ar` が使われている場合は `gcc-ar` に切り替えます。  
MSVC では `/GL` と `/LTCG` を組み合わせます。

Linux の成果物がディスク容量を圧迫する場合は、`MAKEFW_GCC_DEBUG_COMPRESSION=zlib` を指定します。  
C、C++ のコンパイルとリンクに `-gz=zlib` を追加し、DWARF デバッグ情報を圧縮します。  
警告、最適化、カバレッジの設定は維持します。Windows のフラグには影響しません。  
設定を切り替えるときは、`make clean` で既存の成果物を削除してから再ビルドしてください。

## テスト ビルドでの扱い

`LINK_TEST=1` のテスト対象では、ステップ実行とカバレッジ計測を優先します。  
そのため、通常の `CONFIG` が `RelWithDebInfo` や `Release` であっても、テスト対象ソースには最適化抑制とカバレッジ用の設定が適用されます。

- Linux: `-O0 -g -coverage -fprofile-update=atomic` を使用し、`-flto` はリンク オプションから除外します。`-fprofile-update=atomic` は、多スレッド テストでカバレッジ カウンターの更新が競合して gcov が負の実行回数を出力し、gcovr が読み取りに失敗することを防ぎます。
- MSVC: `/Od /Ob0 /Zi` を使用し、`/LTCG` はリンク オプションから除外します。

`test/libsrc` 配下のモックなどのテスト用ライブラリは、通常の `CONFIG` の最適化でビルドします。  
モックは多数の `ON_CALL` を並べたコンストラクターのような巨大な関数を持つため、コンパイラの上限を超えないように次のフラグを追加します。

- Linux: `-fno-var-tracking-assignments` を使用します。GCC は変数追跡の上限を超えた関数を追跡なしでコンパイルし直し、そのことを備考として出力するためです。gdb でモック内部の変数を表示できない場合がありますが、コンパイル時間と成果物のサイズは小さくなります。
- MSVC: `/bigobj` を使用します。gmock のテンプレート展開でオブジェクトのセクション数が COFF の上限 (65535) を超えると、C1128 でコンパイルが停止するためです。生成されるコードとデバッグ情報は変わりません。

本番性能の確認には、`test` 配下ではなく `prod` 配下を `CONFIG=Release` でビルドした成果物を使用します。

`make test` は、app 単位 (`make_test.stamp`) と leaf ディレクトリ単位 (`test.stamp`) の 2 段階で、依存関係が変化していない場合にテスト実行を省略します。  
app 単位は途中で 1 つでも失敗すると次回は全体を再実行しますが、leaf 単位のスタンプはテスト対象フォルダーごとに個別に維持されるため、失敗箇所を修正した後の再実行では、変更されていない leaf だけが引き続きスキップされます。  
詳細は `framework/testfw/docs/how-to-test.md` の「再テストのスキップ」を参照してください。

`make quicktest` は `make test` と同じ経路でビルドとテストを行い、C/C++ テストの実行とエビデンス生成をバイナリ単位で一括化します。  
スタンプと署名は `make test` と共通で、どちらかが正常終了すると、依存関係が変わるまで他方も省略されます。  
詳細は `framework/testfw/docs/how-to-test.md` の「テスト対象ディレクトリでの make test と make quicktest」を参照してください。

## ソース削除後の再リンク

対応ソースのない残存オブジェクトはリンク入力から除外します。  
前回リンク成功時の入力一覧を `obj/<成果物名>.link.mk` に保存し、一覧の増減で再リンクします。  
Windows は CRT ごとの `obj/md`、`obj/mdd`、`obj/mt`、`obj/mtd` に保存します。  
保存一覧がない場合は一度再リンクするため、導入前の成果物も更新されます。

一覧の読み込みと比較には、新しい外部プロセスを起動しません。  
リンク失敗時は保存一覧を更新せず、次回のビルドで再試行します。  
Linux の静的ライブラリは一時ファイルへ新規作成し、成功後に置換して古いアーカイブ メンバーを除去します。

全入力がなくなった成果物と保存一覧は削除します。  
古いオブジェクト自体は削除しません。  
`TEST_SRCS` や `ADD_SRCS` からの除去後も、コピーやシンボリック リンクが残る場合は自動除外の対象外です。  
この場合は、[TEST_SRCS からソースを除去したときの残存成果物](makeparts.md#test_srcs-からソースを除去したときの残存成果物) の処置を行ってください。

リポジトリ ルートから次のコマンドで確認できます。

```bash
python3 framework/makefw/bin_test/link_objects_selftest.py
```

検証では Linux の実テンプレートと GCC / ar を使います。  
Windows 分岐は MSVC / PowerShell の呼び出しを代行して確認するため、Windows 実機の検証は別途必要です。

## ビルド署名に含まれる入力

app 直下の `make` / `make test` は、実行のたびに `framework/makefw/bin_internal/resolve_app_deps.sh --signature` でビルド署名 (`BUILD_SIGNATURE`) を計算し、直前の実行時の値と比較します。  
`make` は `make_build.stamp` と、`make test` は `make_test.stamp` と突き合わせます。  
署名が前回と一致し、かつ直近のビルドが成功していれば、サブディレクトリへの再帰そのものを省略します。  
`make with-cov` は署名を計算せず、`make_build.stamp` も更新しません (`test` をビルドしないため)。

app 直下の make は、子 make を起動する必要がある場合にだけ依存パスを解決します。  
署名が一致してビルドやテストを省略する場合は、依存パスを解決しません。  
製品とテストのパスをまとめて解決し、同じ app の子 make へ環境変数で渡して再利用します。  
Windows では全パスを 1 回の `cygpath` 呼び出しで変換し、Linux では変換せずに出力します。

解決のタイミング、子 make への継承、一括出力は、`python framework/makefw/bin_test/app_paths_selftest.py` で局所確認します。

```text
INFO: Skipping build (dependencies are unchanged and clean)
```

署名には次が含まれます。

- app 直下の `makefile` / `makepart.mk` / `makelocal.mk` / `appdeps.mk`
- 依存閉包に含まれる各 app の `prod/` 配下のソース、ヘッダー、make ファイル
- `test/` 配下 (`app/<name>.assured.stamp` の省略が有効な対象 app では `test/libsrc` のモックだけ)
- ワークスペース直下の `Directory.Build.props` / `Directory.Build.targets`
- makefw の入力 (後述)
- `test/` を持つ app では、testfw の入力 (後述)
- `CONFIG` / `MSVC_CRT` / `TARGET_ARCH` / `CFLAGS` / `CXXFLAGS` / `LDFLAGS` / `DEFINES` / `LIBS` / `MAKEFW_GCC_DEBUG_COMPRESSION` の値

makefw のテンプレートとスクリプトは、テストの有無にかかわらず、すべての app のビルドの入力です。  
すべての app の `make` と `make test` の署名に、`framework/makefw` の次の入力を含めます。  
コンパイル オプションやリンクの規則を変えると、ソースに変更のない app もビルドとテストを再実行します。

- `makefiles/` 直下のすべてのファイル (テンプレート、テンプレートが読み込む make ファイル、`utf8_manifest.manifest`)
- `bin_internal/` 直下の `*.sh`、`*.py`、`*.ps1` (署名を計算する `resolve_app_deps.sh` 自体を含む)

範囲は `bin_internal/list_signature_inputs.sh` だけで定義し、テスト対象ディレクトリ単位の再テストの判定 ([再テストのスキップ](../../testfw/docs/how-to-test.md#再テストのスキップ)) と共有します。  
ディレクトリと拡張子で範囲を決めるのは、スクリプトの追加で一覧の更新が漏れ、古い成果物を残さないためです。  
`bin/` の開発環境の補助スクリプトと、`bin_internal/` のサブディレクトリは含めません。

testfw のライブラリとスクリプトは、テストのビルドと結果の生成の入力です。  
`make` を実行した app が `test/` を持つ場合は、`make` と `make test` の両方の署名に、`framework/testfw` の次の入力を含めます。  
`make` もテストをビルドするため、`make test` の署名だけに含めると、ライブラリを変えた後の `make` が古いライブラリとリンクしたテストを残します。

- `makefile` / `makepart.mk`
- `libsrc/`、`include/`、`include_internal/`、`include_override/` 配下のソース、ヘッダー、make ファイル (`obj/` などの生成物は含めない)
- `gtest/TARGET_GTEST_VERSION` (Google Test の版。ビルド済みのライブラリは含めない)
- `bin_internal/list_signature_scripts.sh` が出力するスクリプト (範囲は [再テストのスキップ](../../testfw/docs/how-to-test.md#再テストのスキップ) を参照)

testfw がワークスペースの外にある場合や、存在しない場合は、testfw の入力を含めません。

サブディレクトリへの再帰が省略されると、`makepart.mk` の `$(shell)` でサブディレクトリの make 読み込み時に実行される処理も実行されません。  
`app/cjson` / `app/sqlite` / `app/lua` のように、`packages/` の配布アーカイブを `bin_internal/extract_package.py` で展開し、`patches/` のパッチを適用してから prod/ を構成する app では、展開処理自体がこの `$(shell)` の中で実行されます。  
これら 3 つの入力は `prod/` のソースではないため、署名に含めないと、入力を変えても再帰が省略され、展開とパッチの適用が再実行されません。

そのため、ビルド署名には次も明示的に含めます (対象 app にのみ存在する分だけが加わります)。

- `patches/*.patch`
- `packages/` 配下の配布アーカイブ (`*.zip`, `*.tar.gz`, `*.tgz`, `*.tar.xz`, `*.tar.bz2`, `*.tbz2`)
- `bin_internal/*.py`, `bin_internal/*.sh`

`packages/README.md` や `patches/README.md` のような運用手順の文書は対象に含めません。  
`bin_internal/extract_package.py` と `framework/makefw/bin_internal/apply_patches.py` はいずれも README.md を参照せず、実際の展開・パッチ適用に使うのはファイル名を正規表現やファイル名昇順で選んだアーカイブ本体・パッチ本体だけだからです。  
署名は「ビルド入力かどうか」を基準に含めるため、文書だけを変更しても再ビルドは実行されません。

## 生成ソースだけを作る (make gen)

`make gen` は、各 app の `prod/` 配下の生成ソースだけを作ります。通常のソースはコンパイルせず、`test/` もビルドしません。  
フル ビルドをせずに Doxygen の入力をそろえる用途で使います。Doxygen の入力には、`gen/` 配下の生成ソースが含まれるためです。

```bash
# ワークスペース直下、app/ 直下、app/<name>/ 直下のいずれでも実行できる
make gen
```

生成ソースの種類ごとの扱いは、次のとおりです。

| 種類 | 例 | `make gen` での扱い |
| --- | --- | --- |
| `makepart.mk` がパース時にスクリプトで生成する | 配布アーカイブの展開、定義ファイルからの生成 | `prod/` 配下の makefile をパースした時点で生成される |
| ツールだけで生成する規則 | flex / bison、Windows の mc.exe | 生成物を作る。コンパイルは行わない |
| app が自前でビルドした生成器で生成する | `GENDIR_EXTRA_C` の規則が `prod/cbin/` の実行体を前提にする | app の宣言に従い、`prod/` を通常どおりビルドする |

Table: 生成ソースの種類と make gen での扱い

生成ソースは、生成物の置き場所 `$(GENDIR)` (`gen/`) に置きます。  
makefw の生成規則 (flex / bison、mc.exe) は、この場所へ出力します。app が独自の規則で生成する場合も、同じ場所へ出力してください。  
`make gen` の対象と Doxygen の入力を、`gen/` ディレクトリで判別するためです。

自前でビルドした生成器が必要な app は、`appdeps.mk` で `APP_GEN_REQUIRES_BUILD := 1` を宣言します ([appdeps.mk](makeparts.md#appdepsmk) を参照)。  
`app/makefile` の `make gen` は、宣言した app と、その `APP_DEPS` の推移的な依存先について、`prod/` を通常どおり make します。生成器と、生成器がリンクするライブラリを用意するためです。  
それ以外の app では、`prod/` に対してゴール `_gen` を実行し、生成だけを行います。  
対象の app は、`bin_internal/resolve_app_deps.sh --gen-build-apps` で確認できます。

`prod/` 配下のゴール名は `gen` ではなく `_gen` です。末端のディレクトリでは、ターゲット名 `gen` が生成物の置き場所 (`$(GENDIR)`) を作る規則と重なるためです。  
`_gen` は中間ディレクトリから下位のディレクトリへ伝わり、`SUBDIRS` の宣言順も維持します。

`make gen` は署名を計算せず、`make_build.stamp` と `make_test.stamp` も更新しません (`test` をビルドしないため)。  
app 直下で `make gen` を直接実行した場合は、依存先の app を make しません。app 直下の `make` が依存先をビルドしないことと同じです。

宣言のない app で、`GENDIR_EXTRA_C` の規則がビルドした実行体を前提にしていると、`make gen` は実行体を作る規則が見つからずエラーで止まります。この場合は、`appdeps.mk` に宣言を追加します。

動作は `python framework/makefw/bin_test/test_gen_goal.py` で局所確認します。

## assured.stamp による保証済み app の扱い

`app/<name>.assured.stamp` は、サブモジュールの app が記録したコミットのままであることを示すスタンプです。  
ルートからのビルド確認にその app を含めたまま、`test/src` のコンパイルとテスト実行、および成功済みビルドの `clean` を省きます。  
同じスタンプを `framework/<name>.assured.stamp` に置くと、サブモジュールのフレームワークのテストも省略できます (後述の [framework の省略](#framework-の省略))。

ファイルはサブモジュールの親ディレクトリ (`app/` または `framework/`) の直下に置きます。サブモジュールのディレクトリの中には置きません。  
名前は `<name>.assured.stamp` です。`app/cplat` なら `app/cplat.assured.stamp`、`framework/testfw` なら `framework/testfw.assured.stamp` です。

中身は、そのサブモジュールのコミット ハッシュ 1 個です。make はこのファイルを作りません。  
次のコマンドで、現在の HEAD を書き込めます。

```bash
git -C app/cplat rev-parse HEAD > app/cplat.assured.stamp
```

フレームワークを利用するプロジェクトでは、上流で検証済みのコミットを書いたスタンプをコミットし、サブモジュールの参照と一緒に管理します。  
CI は clone したスタンプをそのまま使います。CI の中で HEAD を書き込むと、どのコミットでも一致し、保証の意味がなくなります。  
サブモジュールの参照を更新したときは、検証済みであることを確かめてからスタンプも更新します。参照だけを進めると、ハッシュが一致せず、テストを通常どおり実行します。

c-modernization-kit 自身はフレームワークと app を開発する場であり、常にテストを実行するため、`.gitignore` で `*.assured.stamp` を無視しています。  
このワークスペースでは、スタンプは手元での確認を速める目的に限って使います。

省略が有効になるのは、次をすべて満たすときだけです。

- 対象がワークスペースのサブモジュールである
- スタンプのハッシュが、そのサブモジュールの HEAD と一致する
- 作業ツリーに追加、削除、変更がない (未追跡の追加、インデックスへ載せた追加、追跡ファイルの変更と削除を含む。`.gitignore` されたビルド成果物は含めない)

1 つでも欠けるときは省略せず、通常の `make` / `make test` / `make clean` を行います。  
ハッシュ不一致や差分があるだけのときは警告しません。  
対象がサブモジュールではないときにスタンプがあると、警告を出して省略しません。

```text
Warning: app/calc is not a submodule. Ignoring calc.assured.stamp.
```

効果は `app/<name>` 直下の `make` / `make test` / `make clean` に限ります。  
`prod/` や `test/`、`test/src` 配下での直接 make は妨げません。

### test/src の省略

省略が有効なとき、app 直下の `make` と `make test` は製品とモックだけをコンパイルし、`test/src` のコンパイルとテスト実行を行いません。

```text
INFO: Skipping test/src (assured.stamp matches the commit and the tree is clean)
```

`MAKEFW_TEST_FORCE=1` では解除しません。  
app 直下でテストを再開するときは、スタンプを外すか、別のコミットへ進めるか、作業ツリーに差分を作ります。

省略が有効なあいだは、ビルド署名から `test/src` を外します。  
テスト ソースだけの変更は差分になるため省略は解け、署名に `test/src` が戻り、製品とモックの再ビルド判定にも載ります。  
app 直下の `make test` は、省略中は `make_test.stamp` を更新しません。

### 成功時の clean 省略

app 直下の `make clean` を省略するのは、省略が有効であり、かつ直近の app 直下 `make` が正常終了しているときだけです。  
正常終了は `make_build.stamp` があることです。どちらかが欠けると、成果物と `make_build.stamp` を削除します。

```text
INFO: Skipping clean (assured.stamp matches the commit and make succeeded)
```

`make` はサブディレクトリのビルドへ入る前に `make_build.stamp` を削除し、app 直下の `make` が終了コード 0 で終わったあとにだけ書き戻します。  
I/O エラーやコマンド失敗で終了コードが 0 以外になったとき、およびサブディレクトリのビルドが始まったあとにプロセスが止まったときは、スタンプが残らないため `make clean` は実行されます。  
署名の計算中に止まり、サブディレクトリのビルドがまだ始まっていないときは、前回の正常終了で書いた `make_build.stamp` と成果物がそのまま残るため、clean は省略されます。

`make_build.stamp` を残すため、ソースを更新したあとの app 直下 `make` は、署名比較により必要な再ビルドだけを行います。

`make with-cov` は、この省略を使いません。  
`prod/coverity.mk` がある app では、収集の直前に `prod` の成果物と `make_build.stamp` を削除し、`prod` をリンクまで再ビルドします。  
通常の `make clean` は、上の省略条件を維持します。  
手順は [clean の扱い](coverity-with-cov.md#clean-の扱い) を参照してください。

構成切り替えのように、本来 `make clean` が必要な操作で app 直下の `clean` が省略されるときは、スタンプを削除してから `make clean` するか、`prod/` や `test/` 直下で `make clean` します。

### framework の省略

`framework/<name>.assured.stamp` の判定は、app と同じ `bin_internal/resolve_app_deps.sh --assured` で行います。  
省略が有効なときの動作は、フレームワークごとに次のとおりです。

- `framework/testfw`: testfw 直下の `make test` は、`libsrc/` のライブラリを通常どおりビルドし、`test/` と `bin_test/` のテストを実行しません。ルートの `make test` もこの経路を通ります。
- すべてのフレームワーク: c-modernization-kit の `make bin-test` は、そのフレームワークの `bin_test/` を実行せず、保証済みとして結果に表示します。

```text
INFO: Skipping test and bin_test (testfw.assured.stamp matches the commit and the tree is clean)
```

app 用ライブラリのビルドは省略しないため、利用者の app は、保証済みのフレームワークのライブラリとリンクしてテストできます。

## Windows のランタイム指定

Windows/MSVC では、`MSVC_CRT` で C ランタイムのリンク方式を指定できます。  
未指定の場合は `shared` です。

```bash
# 動的 CRT: /MD または /MDd
make CONFIG=RelWithDebInfo MSVC_CRT=shared

# 静的 CRT: /MT または /MTd
make CONFIG=RelWithDebInfo MSVC_CRT=static
```

`CONFIG=Debug` では `shared` が `/MDd`、`static` が `/MTd` になります。  
`CONFIG=Release` と `CONFIG=RelWithDebInfo` では `shared` が `/MD`、`static` が `/MT` になります。

ランタイム リンク モデルの詳細は `msvc-runtime-linkage.md` を参照してください。

## 並列ビルド

Windows ビルドには Visual Studio 2022 以降が必要です。  
MSVC のコンパイルでは複数のソース ファイルを `cl.exe` に渡し、`/MP` で並列処理します。  
ヘッダー依存関係は `/sourceDependencies` で取得します。

makefw は Linux と Windows のどちらでも、利用可能な論理 CPU 数を CPU 予算として並列度を算出します。  
Linux では `nproc`、Windows では `NUMBER_OF_PROCESSORS` から CPU 予算を取得し、取得できない場合は 6 を使います。  
`MAKEFW_CPU_BUDGET` に正の整数を指定すると、自動検出した CPU 予算を上書きできます。

CPU 使用量の目安を半分程度へ抑えるため、両 OS とも `ceil(CPU 数 / 2)` をコンパイル予算とします。  
make の並列度と、MSVC の `/MP` や MSBuild の `-m` との積が、コンパイル予算に収まるように配分します。

Linux の make にはコンパイル予算を割り当て、上限を 8 とします。  
Windows の make には `ceil(sqrt(2 * CPU 数))` を割り当て、コンパイル予算と 12 を上限とします。  
MSVC の `/MP` と MSBuild の `-m` には `floor(コンパイル予算 / make の並列度)` を割り当て、1 から 16 の範囲に制限します。  
Windows では make の外側の並列度を増やしつつ、1 つの `cl.exe` が生成する子プロセス数を抑えることで、CPU の利用効率とコンパイル時のスタック・メモリ使用量を調整します。

代表的な論理 CPU 数での自動設定は次のとおりです。

| OS | CPU 数 | make | GCC | MSVC | MSBuild |
|---|---:|---:|---:|---:|---:|
| Linux | 8 | `-j4` | make の並列度を使用 | - | `-m:1` |
| Linux | 72 | `-j8` | make の並列度を使用 | - | `-m:4` |
| Windows | 8 | `-j4` | - | `/MP1` | `-m:1` |
| Windows | 72 | `-j12` | - | `/MP3` | `-m:3` |

Table: OS および論理 CPU 数別の並列ビルド設定一覧

引数なし、`default`、`build`、`clean`、`rebuild`、`test` では自動設定を使用します。  
`make test` は内部で 2 フェーズに分かれます。Phase 1 (ビルド フェーズ、ターゲット `_test_build`) はテスト バイナリのコンパイルとリンクのみを自動設定の並列度で実行し、Phase 2 (実行フェーズ、ターゲット `_test_run`) はテストの実行順を維持するため `-j1` で実行します。  
これにより、出力順序を保ったまま、支配的なコンパイルとリンクを並列化します。  
2 フェーズのエントリは `makemain.mk` の `test:` に一元化しており、「任意のディレクトリ単位 (`app/{name}` 単位、その test 配下のサブディレクトリ単位) の `make test` でもビルド並列・実行直列が成立すること」を制約とします。`test:` ターゲットを追加・変更するときはこの制約を維持してください。

コマンド ラインで指定した値は自動算出より優先されます。

```bash
# make の並列度を指定する
make JOBS=4

# make と MSVC の並列度を個別に指定する
make JOBS=4 MAKEFW_CL_MP_JOBS=8

# CPU 予算を指定する
make MAKEFW_CPU_BUDGET=12

# make と MSBuild の並列度を個別に指定する
make JOBS=4 MAKEFW_MSBUILD_JOBS=3

# GNU Make の -j も利用できる
make -j4
```

GNU Make の `-j` をジョブ数なしで指定した場合、make の並列度に上限がないため、MSVC と MSBuild の並列度は 1 とします。  
`MAKEFW_CL_MP_JOBS` または `MAKEFW_MSBUILD_JOBS` を明示した場合は、その値を優先します。

Windows の MSVC コンパイルは、1 回の `cl.exe` に渡すソース本数を既定で 32 本に制限します。  
`MAKEFW_MSVC_SOURCES_PER_BATCH` で本数を変更でき、`MAKEFW_MSVC_BATCH_MAX_CHARS` で既存のコマンド文字数上限 (既定 8000) も変更できます。  
ソース本数を分割しても各ソースの `.obj` は同じ場所へ生成されるため、リンク入力と依存関係の扱いは変わりません。

## MSVC のヒープ不足時の再試行

Windows の `cl.exe` が `fatal error C1060:` (ヒープの領域を使い果たしました) を出力して失敗した場合、`msvc_compile.ps1` は make を直ちに失敗させず、内部で再試行します。  
並列 make で複数の `cl.exe` が同時にメモリを使うと、一時的にヒープ不足になることがあります。  
同じ待ち時間で一斉に再開すると再び同時に失敗しやすいため、待ち時間は回数とともに延ばし、その範囲内の乱数にします。

再試行するのは、終了コードが 0 以外で、かつ出力に `fatal error C1060:` がある場合だけです。  
通常のコンパイル エラーは 1 回で終了します。

既定では失敗後に最大 3 回再試行します (初回を含めて最大 4 回)。  
待ち時間の基準は 2000[ms]、上限は 16000[ms]、下限は 500[ms] です。  
n 回目の再試行の上限は `min(16000, 2000 * 2^(n-1))` [ms] で、実際の待ちはその下限から上限までの乱数です。

再試行中は元の `fatal error C1060` 行を赤字で出力しません。  
待機直前に情報ログを 1 行だけ出力します。  
本文に `error` や `fatal error` を含めないため、再試行で成功した場合はコンパイラ失敗として誤検出されません。

```text
foo.cc: MSVC C1060 compiler heap exhausted; waiting 3.4s then retrying (2/4)
```

再試行上限に達した場合に限り、最後の試行の診断と `Compilation failed with exit code ...` を従来どおり赤字で出力します。

次の環境変数で上書きできます。

- `MAKEFW_MSVC_HEAP_RETRY_MAX`: 失敗後の再試行回数。既定 3。`0` で無効
- `MAKEFW_MSVC_HEAP_RETRY_BASE_MS`: 基準待ち時間 [ms]。既定 2000
- `MAKEFW_MSVC_HEAP_RETRY_CAP_MS`: 待ち時間の上限 [ms]。既定 16000

C1076 や C3859、リンカーのメモリ不足は再試行しません。

## MSVC は共通の include 接頭辞を PCH として再利用する

MSVC の一括コンパイルでは、ソース先頭の共通する `#include` を自動で検出します。  
app の設定追加は不要で、framework の `libsrc`、app の `prod/libsrc` とテストにも同じ処理を適用します。  
Linux の GCC でも、次の節の手順で `.gch` を自動で作ります。

同じディレクトリ、言語、コンパイル設定のソースをまとめます。  
先頭のコメントと空行は読み飛ばしますが、マクロ定義や条件分岐を越えてヘッダーを共有しません。  
指定した境界が先行ヘッダー経由で読み込み済みの場合は、手前の直接 include を境界に選び直します。  
使用できる境界がない場合は、通常のコンパイルへ戻します。  
PCH の作成コストを抑えるため、新規作成は共通ヘッダーを使うソースが `/MP` の並列数の 2 倍以上ある場合に限ります。  
同じ構成の PCH が存在する場合は、少数のソースにも再利用します。  
対象外のソースは従来どおり一括コンパイルします。

PCH と再生成用の依存規則は、ライブラリ ルートの構成別 `obj` 配下に生成します。  
相対パスを正規化し、ヘッダーの探索先とコンパイル設定が一致する場合は、ディレクトリやバッチをまたいで PCH を共有します。  
引用符形式の include がある場合は、ソース ディレクトリも区別します。  
同じ PCH の生成は排他制御し、生成後のコンパイルは並列に実行します。  
コンパイル オプション、通常ソースと `_IN_TEST_SRC` 用の違い、include 接頭辞を識別子に含めます。  
make が直接・間接ヘッダーの日時を比較し、必要な場合だけ PCH を再生成します。  
PCH、依存情報、作成元オブジェクト、共有 PDB が失われた場合も再生成します。  
ソース本体だけの変更では、PCH を作り直さずに利用します。  
各オブジェクトの `.d` には PCH 内のヘッダーと PCH 自体への依存を残します。

比較計測や問題の切り分けで無効化する場合は、環境変数 `MAKEFW_MSVC_PCH=0` を指定します。  
`make with-cov` では、収集ラッパーがこの変数へ `0` を渡すため、収集中は PCH を使いません。  
生成物は `make clean` で構成別の `obj` とともに削除されます。

## GCC は共通の include 接頭辞を .gch として再利用する

Linux では、ソース先頭の無条件な `#include` が一致する翻訳単位に、GCC の `.gch` を自動で付けます。  
app の設定追加は不要です。  
framework の `libsrc`、app の `prod/libsrc`、テストのファイルごとのコンパイルが対象です。

同じディレクトリ、言語、コンパイル設定のソースをまとめます。  
先頭のコメントと空行は読み飛ばします。  
マクロ定義、条件分岐、行継続が現れた位置で接頭辞を止めます。  
インクルード ガードまたは `#pragma once` が無いヘッダーは境界から外し、それ以降も共有しません。  
引用符形式の include は、ソース ディレクトリで解決した絶対パスに直して `.gch` へ入れます。  
解決できないソースは、通常のコンパイルへ戻します。  
`-include` または `-imacros` がすでにあるコンパイルでは、自動の `.gch` を使いません。

新規の `.gch` は、そのグループのソース数が並列数の 2 倍以上のときだけ作ります。  
並列数は `MAKEFW_CL_MP_JOBS` です。  
下限は `MAKEFW_GCC_PCH_MIN_SOURCES` で置き換えられます。  
同じ構成の `.gch` がすでにある場合は、ソース数が下限未満でも再利用します。

生成物はライブラリ ルートの `obj` に置きます。  
名前は `auto_<識別子>.h` と、その `.h.gch` です。  
識別子には、コンパイラの実体パスと更新時刻、言語、正規化したオプション、接頭辞を含めます。  
引用符形式の include があるときは、ソース ディレクトリと include 用の環境変数も識別子に含めます。  
同じ `.gch` の作成は `flock` で直列化し、待ち時間の上限は 600 秒です。  
GCC はヘッダーを更新しても既存の `.gch` を無効にしないため、依存ヘッダーが新しいときは利用前に作り直します。  
ソース本体だけの変更では、作り直さずに利用します。  
各オブジェクトの `.d` には、`.gch` とそこに含まれるヘッダーを追記します。  
作成時の警告は、同じ `obj` の `auto_<識別子>.warn` に残します。  
`make clean` は `obj` ごと削除します。

比較や切り分けで止めるときは、環境変数 `MAKEFW_GCC_PCH=0` を指定します。  
`make with-cov` は収集ラッパーが `MAKEFW_MSVC_PCH=0` と `MAKEFW_GCC_PCH=0` を渡します。  
Coverity の収集では、Windows と Linux のどちらも自動 PCH を使いません。

flex と bison が `gen/` に出したソースは、Linux では依存ファイルを出さない別の規則でコンパイルします。  
この自動 `.gch` には入りません。  
Windows では従来どおり、MSVC の一括コンパイルに含まれます。

対応コンパイラの下限は、これまでどおり GCC 8 です。

## テスト実行の並列数は階層全体で共有する

`_test_run` では、独立した下位グループも並列に実行します。  
グループ自体は実行スロットを取得せず、末端のテストだけが共通スロットを取得します。  
このため、ディレクトリの階層が増えても同時実行する末端テスト数の上限を維持します。

グループの出力順と失敗の伝播には、既存のスケジューラーを使用します。  
app 間の依存管理と、ビルドや clean のグループ実行方式は変更しません。

## 経過時間の表示

ビルドとテストのどこに時間がかかっているかをログから読み取れるように、2 種類の経過時間を表示します。

app やディレクトリを依存の順に実行するスクリプト (`bin_internal/run_ordered_subdir_target.sh`) は、進捗の表示 (`--progress`) が有効な場合に、終了の行へ開始からの経過時間を付けます。

```text
INFO: done [3/17] app/cplat rc=0 elapsed=49:12
```

app 直下の `makefile` (`makefiles/__each_app_template.mk`) は、子の `make` を実行するたびに、その段階の経過時間を 1 行表示します。

```text
INFO: cplat prod elapsed=00:18
INFO: cplat test elapsed=48:40
INFO: cplat test _test_run elapsed=31:05
```

- `prod` と `test` は、既定のゴールでのビルドです。`test _test_run` は、`make test` でのテストの実行です。
- 子の `make` が失敗した場合も、その段階の時間を表示します。
- 署名の一致でビルドやテストを省いた場合と、`gen`、`clean`、`doxy`、`with-cov` のゴールでは表示しません。
- 書式は、1 時間未満が `MM:SS`、1 時間以上が `HH:MM:SS` です。

Windows では、プロセスを 1 つ起動するたびに時間がかかります。  
このため、経過時間は `date` などの外部コマンドやコマンド置換を使わずに求めます。  
テンプレートはシェルの変数 `SECONDS` と組み込みの `printf` を使い、スクリプトは実行の管理のためにすでに取得している時刻を使います。  
`SECONDS` を持たないシェルや、時刻を取得できなかった場合は、表示を省きます。ビルドの結果には影響しません。

## 運用上の注意

- 構成を切り替える場合、既存の `obj` や成果物が残っていると古い構成のオブジェクトと混在する場合があります。
- 特に `Release` の LTO を確認する場合は、対象モジュールで一度 `make CONFIG=Release clean` を実行してからビルドします。
- 全体 `make clean` は高コストなため、通常は変更対象の app や prod/test 直下に限定します。
- 既定構成を一時的に変えたい場合は、コマンド ラインで `CONFIG=...` を指定します。恒久的な変更が必要な場合のみ、上位の `makepart.mk` などで定義します。
