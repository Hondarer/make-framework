# ビルド構成の指定方法

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

`RelWithDebInfo` は、通常開発・テスト・性能調査の既定構成です。  
最適化を有効にしつつデバッグ情報を生成し、Linux ではフレーム ポインターを保持してスタック トレースやプロファイリングを安定させます。

`Release` は、LTO (Link Time Optimization) を有効にするため、ビルド時間やリンク時間が増える場合があります。  
Linux では `-flto` を使うため、既定の `ar` が使われている場合は `gcc-ar` に切り替えます。  
MSVC では `/GL` と `/LTCG` を組み合わせます。

## テスト ビルドでの扱い

`LINK_TEST=1` のテスト対象では、ステップ実行とカバレッジ計測を優先します。  
そのため、通常の `CONFIG` が `RelWithDebInfo` や `Release` であっても、テスト対象ソースには最適化抑制とカバレッジ用の設定が適用されます。

- Linux: `-O0 -g -coverage` を使用し、`-flto` はリンク オプションから除外します。
- MSVC: `/Od /Ob0 /Zi` を使用し、`/LTCG` はリンク オプションから除外します。

本番性能の確認には、`test` 配下ではなく `prod` 配下を `CONFIG=Release` でビルドした成果物を使用します。

`make test` は、app 単位 (`make_test.stamp`) と leaf ディレクトリ単位 (`test.stamp`) の 2 段階で、  
依存関係が変化していない場合にテスト実行を省略します。  
app 単位は途中で 1 つでも失敗すると次回は全体を再実行しますが、leaf 単位のスタンプはテスト対象フォルダーごとに個別へ維持されるため、  
失敗箇所を修正した後の再実行では、変更されていない leaf だけが引き続きスキップされます。  
詳細は `framework/testfw/docs/how-to-test.md` の「再テストのスキップ」を参照してください。

## ビルド署名に含まれる入力

app 直下の `make` / `make test` / `make with-cov` は、実行のたびに `framework/makefw/bin/resolve_app_deps.sh --signature` でビルド署名 (`BUILD_SIGNATURE`) を計算し、直前の実行時の値と比較します。  
`make` と `make with-cov` は `make_build.stamp` と、`make test` は `make_test.stamp` と突き合わせます。  
署名が前回と一致し、かつ直近のビルドが成功していれば、サブディレクトリへの再帰そのものを省略します。

```text
INFO: Skipping build (dependencies are unchanged and clean)
```

署名には次が含まれます。

- app 直下の `makefile` / `makepart.mk` / `makelocal.mk` / `appdeps.mk`
- 依存閉包に含まれる各 app の `prod/` 配下のソース、ヘッダー、make ファイル
- `test/` 配下 (`assured.stamp` がある app では `test/libsrc` のモックだけ)
- ワークスペース直下の `Directory.Build.props` / `Directory.Build.targets`
- `CONFIG` / `MSVC_CRT` / `TARGET_ARCH` / `CFLAGS` / `CXXFLAGS` / `LDFLAGS` / `DEFINES` / `LIBS` の値

サブディレクトリへの再帰が省略されると、`makepart.mk` の `$(shell)` でサブディレクトリの make 読み込み時に実行される処理も実行されません。  
`app/cjson` / `app/sqlite` / `app/lua` のように、`packages/` の配布アーカイブを `bin/extract_package.py` で展開し、`patches/` のパッチを適用してから prod/ を構成する app では、展開処理自体がこの `$(shell)` の中で実行されます。  
そのため、これら 3 つの入力そのものが変化してもビルド署名には反映されない、という欠陥がかつて存在しました。

これを避けるため、ビルド署名には次も明示的に含めます (対象 app にのみ存在する分だけが加わります)。

- `patches/*.patch`
- `packages/` 配下の配布アーカイブ (`*.zip`, `*.tar.gz`, `*.tgz`, `*.tar.xz`, `*.tar.bz2`, `*.tbz2`)
- `bin/*.py`, `bin/*.sh`

`packages/README.md` や `patches/README.md` のような運用手順の文書は対象に含めません。  
`bin/extract_package.py` と `framework/makefw/bin/apply_patches.py` はいずれも README.md を参照せず、実際の展開・パッチ適用に使うのはファイル名を正規表現やファイル名昇順で選んだアーカイブ本体・パッチ本体だけだからです。  
署名は「ビルド入力かどうか」を基準に含めるため、文書だけを変更しても再ビルドは実行されません。

## assured.stamp による保証済み app の扱い

`app/example/assured.stamp` は、その app が品質保証済みであることを表します。  
ルートからのビルド確認に保証済み app を含めたまま、確認時間を短くするために使います。

```text
app/example/assured.stamp
```

ファイルがあれば有効です。  
ファイル内容は参照しません。  
make はこのファイルを生成しません。  
Git の無視対象にもしません。方針としてコミットできます。

効果は `app/example` 直下の `make` / `make test` / `make clean` に限ります。  
`prod/` や `test/`、`test/src` 配下での直接 make は妨げません。  
保証済みでも個別のテスト実行や、`prod` 直下の `make clean` といった救済は、配下で従来どおり実行できます。

### test/src の省略

app 直下の `make` と `make test`、および `make with-cov` の `test` 側は、製品とモックだけをコンパイルし、`test/src` のコンパイルとテスト実行を行いません。

```text
INFO: Skipping test/src (assured.stamp is present)
```

`MAKEFW_TEST_FORCE=1` では解除しません。  
app 直下でテストを再開するときは stamp を外します。

stamp を置いたときと外したときは、`make_build.stamp` の署名が変わるため、次回の app 直下 `make` は再ビルドします。  
stamp があるあいだは、ビルド署名から `test/src` を外すため、テスト ソースの変更では製品とモックを再ビルドしません。  
app 直下の `make test` は `make_test.stamp` を更新しません。

### 成功時の clean 省略

直近の app 直下 `make` が成功しているとき (`make_build.stamp` があるとき)、app 直下の `make clean` は成果物も `make_build.stamp` も削除しません。

```text
INFO: Skipping clean (assured.stamp is present and make succeeded)
```

`make_build.stamp` を残すため、ソースを更新したあとの app 直下 `make` は、署名比較により必要な再ビルドだけを行います。  
`make_build.stamp` が無いとき (失敗途中など) は、app 直下の `make clean` も従来どおり削除します。

構成切り替えのように、本来 `make clean` が必要な操作では、app 直下の `clean` が省略されます。  
その場合は stamp を削除してから `make clean` するか、`prod/` や `test/` 直下で `make clean` します。

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

Linux の make には CPU 予算と 16 の小さい方を割り当てます。  
Windows の make には `ceil(sqrt(2 * CPU 数))` を割り当て、上限を 12 とします。  
MSBuild の `-m` には `floor(CPU 数 / make の並列度)` を割り当て、1 から 16 の範囲に制限します。  
MSVC の `/MP` にはその値をさらに 2 で割った `floor(floor(CPU 数 / make の並列度) / 2)` を割り当て、1 から 16 の範囲に制限します。  
Windows では make の外側の並列度を増やしつつ、1 つの `cl.exe` が生成する子プロセス数を抑えることで、CPU の利用効率とコンパイル時のスタック・メモリ使用量を調整します。

論理 CPU が 72 個ある場合の自動設定は次のとおりです。

| OS | make | GCC | MSVC | MSBuild |
|---|---:|---:|---:|---:|
| Linux | `-j16` | make の並列度を使用 | - | `-m:4` |
| Windows | `-j12` | - | `/MP3` | `-m:6` |

引数なし、`default`、`build`、`clean`、`rebuild`、`test` では自動設定を使用します。  
`make test` は内部で 2 フェーズに分かれます。Phase 1 (ビルド フェーズ、ターゲット `_test_build`) はテスト バイナリのコンパイルとリンクのみを自動設定の並列度で実行し、Phase 2 (実行フェーズ、ターゲット `_test_run`) はテストの実行順を維持するため `-j1` で実行します。  
これにより、出力順序を保ったまま、支配的なコンパイルとリンクの所要を並列化します。  
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
