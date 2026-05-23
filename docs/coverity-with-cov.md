# with-cov による Coverity 収集

## 概要

`with-cov` は通常の `make` と同じ成果物を生成しつつ、解析対象 app の `prod` だけを `cov-build` 経由で実行する入口です。  
解析結果はワークスペース共通の `app/idir` に蓄積されます。

## 入口

次の 3 か所で `with-cov` を実行できます。

```bash
make with-cov
make -C app with-cov
make -C app/<appname> with-cov
```

- ルート `make with-cov`
  - `framework/testfw` は通常ビルド
  - `app` 配下は対象 app だけ Coverity 収集
  - `skills` も通常の `make` と同様に実行
- `make -C app with-cov`
  - app の依存順は通常の `make -C app` と同じ
  - `coverity.mk` がある app だけ `with-cov` を呼ぶ
  - それ以外の app は通常ビルド
- `make -C app/<appname> with-cov`
  - `prod` は Coverity 経由
  - `test` は通常どおり `make -C test`

## 必須設定

### COVERITY_HOME

`with-cov` 実行時だけ必須です。通常の `make`、`make test`、`make doxy` には影響しません。

```bash
export COVERITY_HOME=/opt/coverity
```

`$COVERITY_HOME/bin/cov-build` が存在しない場合、`with-cov` は開始前に失敗します。

### app/<appname>/coverity.mk

解析対象 app は `coverity.mk` を app 直下に置きます。

```make
COVERITY_TOOLCHAIN := c_cpp
```

または

```make
COVERITY_TOOLCHAIN := dotnet
```

- `coverity.mk` がある app だけ解析対象です
- `make -C app/<appname> with-cov` では `coverity.mk` が必須です
- `COVERITY_TOOLCHAIN` は `c_cpp` または `dotnet` 以外を許可しません

## 収集動作

解析対象 app の `prod` は次の形式で収集されます。

```bash
cov-build --append-log --dir app/idir make -C prod
```

- `--dir` は常にワークスペースの `app/idir`
- `--append-log` により `app/idir/build-log.txt` は追記されます
- `test` や `clean` は `cov-build` を通しません

`app/idir` は app ごとの一時ディレクトリではなく、ワークスペース全体の集約先です。  
複数 app を連続実行すると、同じ `app/idir` に emit が蓄積されます。
`make -C app with-cov` のような一括実行では、対象 app ごとの `cov-build` が同じ `app/idir` に順次追記されます。

この設計では `app/idir` 自体を Coverity のマージ先として扱います。  
app ごとに別 idir を作って後段で `cov-manage-emit import` する方式は採りません。

## skip 挙動

`app/<appname>/makefile` の `with-cov` は通常の `make` と同じ署名比較を使います。

- `make_build.stamp` が一致する場合は build を skip
- build が skip された app では Coverity 収集も追加実行しない
- `make test` の skip 判定は既存どおり `make_test.stamp`

このため、依存関係が未変更で clean な状態では、`with-cov` は追加のビルドコストを発生させません。

## clean の扱い

- `make -C app clean`
  - 既存の app clean に加えて `app/idir` を削除します
- `make clean`
  - ルートから `make -C app clean` が呼ばれるため、最終的に `app/idir` も削除されます
- `make -C app/<appname> clean`
  - app 単位の既存 clean だけを実行し、`app/idir` は削除しません

`clean` を `cov-build` 経由で流すと、すでに `app/idir` に蓄積された emit を壊す可能性があります。  
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

Linux で `app/calc` などの C/C++ app を `with-cov` 対象にする場合は、まず GCC 系の設定を登録します。

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
Linux で `calc` と `calc.net` を対象にする場合は、少なくとも GCC 系と C# 系が表示される状態にします。
Windows で同じ構成を対象にする場合は、少なくとも MSVC 系と C# 系が表示される状態にします。

必要であれば、各 compiler configuration を次のコマンドで個別にテストできます。

```bash
"$COVERITY_HOME/bin/cov-test-configuration" --help
```

実際のオプションは Coverity のバージョンと compiler configuration の内容に合わせて調整してください。

### 迷ったときの整理

- Linux で `app/calc` だけ解析する
  - `cov-configure --gcc`
- Linux で `app/calc` と `app/calc.net` の両方を解析する
  - `cov-configure --gcc`
  - `cov-configure --cs`
- Windows で `app/calc` だけ解析する
  - `cov-configure --msvc`
- Windows で `app/calc` と `app/calc.net` の両方を解析する
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
