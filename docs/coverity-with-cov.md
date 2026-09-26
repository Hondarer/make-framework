# with-cov による Coverity 収集

## 概要

`with-cov` は、解析対象 app の `prod` を `cov-build` 経由でビルドする、分析専用の仕組みです。  
構文解析や自動生成を伴う app では、解析対象のソースがリンクまでのビルド過程で生成されるため、`prod` は通常の `make` と同じくリンクまで行います。  
一方で `test` (モックとテスト コード) はビルドせず、`make_build.stamp` と `make_test.stamp` も更新しません。  
`test` のビルドや実行が必要な場合は、通常の `make` や `make test` を別に実行してください。  
解析結果はワークスペース共通の `app/idir` に蓄積されます。

## Coverity を make にあわせて収集する方法

### app/\<appname\>/prod/coverity.mk の設定

解析対象 app は `coverity.mk` を app/\<appname\>/prod 配下に置きます。

```make
COVERITY_TOOLCHAIN := c_cpp
```

または

```make
COVERITY_TOOLCHAIN := dotnet
```

- `coverity.mk` がある app だけを解析対象と認識します (`app/<appname>/prod/coverity.mk` を参照)
- `make -C app/<appname> with-cov` では `prod/coverity.mk` が必須です
- `COVERITY_TOOLCHAIN` は `c_cpp` または `dotnet` 以外を許可しません

### COVERITY_HOME の設定

Coverity のインストール ディレクトリを事前に設定します。

```bash
export COVERITY_HOME=/opt/coverity
```

`$COVERITY_HOME/bin/cov-build` が存在しない場合、`with-cov` は開始前に失敗します。  
通常の `make`、`make test`、`make doxy` には影響しないため、Coverity が設定されていない環境では設定不要です。

### cov-configure の実行

[cov-configure の例](#cov-configure-の例) を参照して設定を行ってください。

### make の実行

次の 3 か所で `with-cov` を実行できます。

> [!TIP]
> 通常はプロジェクト ルートで `make with-cov` を実行します。

> [!IMPORTANT]
> 本フレームワークでは `cov-build` が必要な場合に、`make` 内部で自動的に `cov-build` を経由します。
> `make` コマンドそのものには `cov-build` は不要です。

```bash
make with-cov
make -C app with-cov または cd app && make with-cov && cd ..
make -C app/<appname> with-cov または cd app/<appname> && make with-cov && cd ../..
```

- ルート `make with-cov`
    - 一般的な CI で利用するシナリオ
    - `framework/testfw` は通常ビルド
    - `app` 配下は対象 app だけ Coverity 収集
    - `skills` も通常の `make` と同様に実行
- `make -C app with-cov`
    - app の依存順は通常の `make -C app` と同じ
    - 対象は、`prod/coverity.mk` がある app と、それらが (推移的に) 依存する app だけです
    - `prod/coverity.mk` がある app は `with-cov` を呼ぶ
    - 依存先で `prod/coverity.mk` がない app は、生成ヘッダーやライブラリを供給するため、`prod` だけを通常どおり `make` する
    - どの対象 app にも依存されない、`prod/coverity.mk` のない app は `make` しない
    - `prod/coverity.mk` のある app が 1 つもない場合は、何もしない
- `make -C app/<appname> with-cov`
    - `prod` だけを Coverity 経由でビルドする
    - `test` は対象外 (ビルドしない)

## 収集動作

解析対象 app の `prod` は次の形式で収集されます。

```bash
cov-build --append-log --dir app/idir make -C prod
```

- `--dir` は常にワークスペースの `app/idir`
- `--append-log` により `app/idir/build-log.txt` は追記されます
- `test` や `clean` は `cov-build` を通しません
- 対象 app の一覧は `framework/makefw/bin/resolve_app_deps.sh --coverity-apps` で確認できます

`app/idir` は app ごとの一時ディレクトリではなく、ワークスペース全体の集約先です。  
複数 app を連続実行すると、同じ `app/idir` に emit が蓄積されます。  
`make -C app with-cov` のような一括実行では、対象 app ごとの `cov-build` が同じ `app/idir` に順次追記されます。

## skip 挙動

`app/<appname>/makefile` の `with-cov` は、通常の `make` のような署名比較によるビルド スキップを行いません。  
Coverity 収集は `prod` のビルドを観測することが前提であり、ビルドが行われなければ何も収集されないためです。

- `prod/coverity.mk` がある app は、収集の直前に `prod` の成果物と `make_build.stamp` を削除します。`assured.stamp` の有無や `make_build.stamp` の一致に関係なく、`prod` を必ず再ビルドします。
- `prod` は通常の `make` と同じく、リンクまで行います。
- `test` (モックとテスト コード) はビルドしません。`assured.stamp` の有無にも影響されません。
- `make_build.stamp` と `make_test.stamp` は更新しません。`test` をビルドしていない状態を「ビルド済み」と扱わないためです。

このため、`with-cov` を実行した app は、続く通常の `make` で `test` のビルドと `make_build.stamp` の作成が行われます。  
依存先として `prod` だけを `make` した app (`prod/coverity.mk` がない app) も同様に、`make_build.stamp` は更新されません。

## clean の扱い

- `make -C app clean`
    - 既存の app clean に加えて `app/idir` を削除します
- `make clean`
    - ルートから `make -C app clean` が呼ばれるため、最終的に `app/idir` も削除されます
- `make -C app/<appname> clean`
    - app 単位の既存 clean だけを実行し、`app/idir` は削除しません

`make with-cov` は、`prod/coverity.mk` がある app で、収集の直前に `prod` だけを clean し、`make_build.stamp` を削除します。  
この clean は `__ensure-coverity` による前提検査のあと、`cov-build` の外で実行します。  
`with-cov` は `test` を扱わないため、`test` は clean しません。  
`assured.stamp` の有無に関係なく実行するため、`with-cov` の前に利用者が `make clean` する必要はありません。  
一方、`assured.stamp` と `make_build.stamp` がある app の通常の `make clean` は、従来どおり成果物と stamp を削除しません。  
省略条件の詳細は [成功時の clean 省略](build-configurations.md#成功時の-clean-省略) を参照してください。

`clean` を `cov-build` 経由で実行すると、すでに `app/idir` に蓄積された解析データを破損させる可能性があります。  
そのため `with-cov` でも `clean` は通常の `make` と分離して扱います。

## cov-configure の例

`with-cov` は `cov-configure` を自動実行しません。必要な設定は事前に行ってください。  
`c_cpp` と `dotnet` を同じ `make with-cov` で連続実行する場合も、必要な compiler configuration が事前に登録済みであることを前提にします。

### 事前登録の考え方

- `cov-configure` は `cov-build` のたびに毎回実行するものではありません
- 解析対象の toolchain が変わっても、必要な compiler configuration があらかじめ登録済みなら、そのまま `make with-cov` を実行できます
- このワークスペースでは `COVERITY_TOOLCHAIN := c_cpp` と `COVERITY_TOOLCHAIN := dotnet` を使い分けますが、`c_cpp` 側は実際のコンパイラが Linux と Windows で異なります
- そのため、利用する OS ごとに必要な C/C++ compiler configuration を先に登録しておきます

### Linux での事前登録手順

Linux で `app/example` などの C/C++ app を `with-cov` 対象にする場合は、まず GCC 系の設定を登録します。

```bash
export COVERITY_HOME=/opt/coverity
"$COVERITY_HOME/bin/cov-configure" --gcc
```

.NET app も同じ Linux 環境で対象にする場合は、続けて C# の設定を登録します。

```bash
"$COVERITY_HOME/bin/cov-configure" --cs
```

Linux 上で `calc` と `calc.net` の両方を `make with-cov` したい場合の最小手順は次のとおりです。

```bash
export COVERITY_HOME=/opt/coverity
"$COVERITY_HOME/bin/cov-configure" --gcc
"$COVERITY_HOME/bin/cov-configure" --cs
make with-cov
```

### Windows での事前登録手順

Windows で C/C++ app を `with-cov` 対象にする場合は、まず MSVC のビルド環境を有効にしてから `cov-configure --msvc` を実行します。  
このワークスペースでは `Start-VSCode-With-Env.cmd` で GNU Make と MSVC の環境を整える前提です。

```bat
set COVERITY_HOME=C:\coverity
"%COVERITY_HOME%\bin\cov-configure.exe" --msvc
```

Windows で .NET app も対象にする場合は、続けて C# の設定を登録します。

```bat
"%COVERITY_HOME%\bin\cov-configure.exe" --cs
```

Windows 上で `calc` と `calc.net` の両方を `make with-cov` したい場合の最小手順は次のとおりです。

```bat
set COVERITY_HOME=C:\coverity
"%COVERITY_HOME%\bin\cov-configure.exe" --msvc
"%COVERITY_HOME%\bin\cov-configure.exe" --cs
make with-cov
```

### 登録内容の確認手順

登録済み compiler configuration は次のコマンドで確認できます。

```bash
"$COVERITY_HOME/bin/cov-configure" --list-configured-compilers text
```

Windows では次の形です。

```bat
"%COVERITY_HOME%\bin\cov-configure.exe" --list-configured-compilers text
```

出力には configured compiler の一覧が表示されます。  
Linux で C と C# を対象にする場合は、少なくとも GCC 系と C# 系が表示される状態にします。  
Windows で C と C# を対象にする場合は、少なくとも MSVC 系と C# 系が表示される状態にします。

必要であれば、各 compiler configuration を次のコマンドで個別にテストできます。

```bash
"$COVERITY_HOME/bin/cov-test-configuration" --help
```

実際のオプションは Coverity のバージョンと compiler configuration の内容に合わせて調整してください。

### 迷ったときの整理

- Linux で `app/example` だけを解析する場合:
    - `cov-configure --gcc`
- Linux で `app/example` と `app/example.net` の両方を解析する場合:
    - `cov-configure --gcc`
    - `cov-configure --cs`
- Windows で `app/example` だけを解析する場合:
    - `cov-configure --msvc`
- Windows で `app/example` と `app/example.net` の両方を解析する場合:
    - `cov-configure --msvc`
    - `cov-configure --cs`

### C/C++

```bash
"$COVERITY_HOME/bin/cov-configure" --gcc
```

MSVC を使う場合の例:

```bash
"$COVERITY_HOME/bin/cov-configure" --msvc
```

### .NET / MSBuild

```bash
"$COVERITY_HOME/bin/cov-configure" --cs
```

実際に必要なオプションは、利用する Coverity のバージョンとビルド環境に合わせて調整してください。
