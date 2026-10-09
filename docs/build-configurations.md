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

## テスト ビルドでの扱い

`LINK_TEST=1` のテスト対象では、ステップ実行とカバレッジ計測を優先します。  
そのため、通常の `CONFIG` が `RelWithDebInfo` や `Release` であっても、テスト対象ソースには最適化抑制とカバレッジ用の設定が適用されます。

- Linux: `-O0 -g -coverage -fprofile-update=atomic` を使用し、`-flto` はリンク オプションから除外します。`-fprofile-update=atomic` は、多スレッド テストでカバレッジ カウンターの更新が競合して gcov が負の実行回数を出力し、gcovr が読み取りに失敗することを防ぎます。
- MSVC: `/Od /Ob0 /Zi` を使用し、`/LTCG` はリンク オプションから除外します。

本番性能の確認には、`test` 配下ではなく `prod` 配下を `CONFIG=Release` でビルドした成果物を使用します。

`make test` は、app 単位 (`make_test.stamp`) と leaf ディレクトリ単位 (`test.stamp`) の 2 段階で、依存関係が変化していない場合にテスト実行を省略します。  
app 単位は途中で 1 つでも失敗すると次回は全体を再実行しますが、leaf 単位のスタンプはテスト対象フォルダーごとに個別に維持されるため、失敗箇所を修正した後の再実行では、変更されていない leaf だけが引き続きスキップされます。  
詳細は `framework/testfw/docs/how-to-test.md` の「再テストのスキップ」を参照してください。

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

解決のタイミング、子 make への継承、一括出力は、`python framework/makefw/bin_internal/app_paths_selftest.py` で局所確認します。

```text
INFO: Skipping build (dependencies are unchanged and clean)
```

署名には次が含まれます。

- app 直下の `makefile` / `makepart.mk` / `makelocal.mk` / `appdeps.mk`
- 依存閉包に含まれる各 app の `prod/` 配下のソース、ヘッダー、make ファイル
- `test/` 配下 (`app/<name>.assured.stamp` の省略が有効な対象 app では `test/libsrc` のモックだけ)
- ワークスペース直下の `Directory.Build.props` / `Directory.Build.targets`
- `CONFIG` / `MSVC_CRT` / `TARGET_ARCH` / `CFLAGS` / `CXXFLAGS` / `LDFLAGS` / `DEFINES` / `LIBS` の値

サブディレクトリへの再帰が省略されると、`makepart.mk` の `$(shell)` でサブディレクトリの make 読み込み時に実行される処理も実行されません。  
`app/cjson` / `app/sqlite` / `app/lua` のように、`packages/` の配布アーカイブを `bin_internal/extract_package.py` で展開し、`patches/` のパッチを適用してから prod/ を構成する app では、展開処理自体がこの `$(shell)` の中で実行されます。  
そのため、これら 3 つの入力そのものが変化してもビルド署名には反映されない、という欠陥がかつて存在しました。

これを避けるため、ビルド署名には次も明示的に含めます (対象 app にのみ存在する分だけが加わります)。

- `patches/*.patch`
- `packages/` 配下の配布アーカイブ (`*.zip`, `*.tar.gz`, `*.tgz`, `*.tar.xz`, `*.tar.bz2`, `*.tbz2`)
- `bin_internal/*.py`, `bin_internal/*.sh`

`packages/README.md` や `patches/README.md` のような運用手順の文書は対象に含めません。  
`bin_internal/extract_package.py` と `framework/makefw/bin_internal/apply_patches.py` はいずれも README.md を参照せず、実際の展開・パッチ適用に使うのはファイル名を正規表現やファイル名昇順で選んだアーカイブ本体・パッチ本体だけだからです。  
署名は「ビルド入力かどうか」を基準に含めるため、文書だけを変更しても再ビルドは実行されません。

## assured.stamp による保証済み app の扱い

`app/<name>.assured.stamp` は、サブモジュールの app が記録したコミットのままであることを示すスタンプです。  
ルートからのビルド確認にその app を含めたまま、`test/src` のコンパイルとテスト実行、および成功済みビルドの `clean` を省きます。

ファイルは `app/` 直下に置きます。app ディレクトリの中には置きません。  
名前は `<name>.assured.stamp` です。`app/cplat` なら `app/cplat.assured.stamp` です。

中身は、その app のコミット ハッシュ 1 個です。make はこのファイルを作りません。  
次のコマンドで、現在の HEAD を書き込めます。

```bash
git -C app/cplat rev-parse HEAD > app/cplat.assured.stamp
```

ワークスペースの `.gitignore` は `*.assured.stamp` を無視します。コミット対象にしません。

省略が有効になるのは、次をすべて満たすときだけです。

- 対象 app がワークスペースのサブモジュールである
- スタンプのハッシュが、そのサブモジュールの HEAD と一致する
- 作業ツリーに追加、削除、変更がない (未追跡の追加、インデックスへ載せた追加、追跡ファイルの変更と削除を含む。`.gitignore` されたビルド成果物は含めない)

1 つでも欠けるときは省略せず、通常の `make` / `make test` / `make clean` を行います。  
ハッシュ不一致や差分があるだけのときは警告しません。  
対象 app がサブモジュールではないときにスタンプがあると、警告を出して省略しません。

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

## 運用上の注意

- 構成を切り替える場合、既存の `obj` や成果物が残っていると古い構成のオブジェクトと混在する場合があります。
- 特に `Release` の LTO を確認する場合は、対象モジュールで一度 `make CONFIG=Release clean` を実行してからビルドします。
- 全体 `make clean` は高コストなため、通常は変更対象の app や prod/test 直下に限定します。
- 既定構成を一時的に変えたい場合は、コマンド ラインで `CONFIG=...` を指定します。恒久的な変更が必要な場合のみ、上位の `makepart.mk` などで定義します。
