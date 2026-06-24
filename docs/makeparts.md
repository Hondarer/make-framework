# makepart.mk / makechild.mk / makelocal.mk について

## 概要

makefw フレームワークでは、ビルド設定のカスタマイズに 3 種類の設定ファイルを提供しています。  
これらのファイルにより、最終階層の makefile を一切編集することなく、プロジェクト固有の設定を柔軟に管理できます。

| ファイル | スコープ | 適用対象 |
|---------|---------|---------|
| `makepart.mk` | 階層継承 (親→子に伝播) | 自ディレクトリ + 子階層すべて |
| `makechild.mk` | 子階層限定 (自身は除く) | 子階層以降のみ (自ディレクトリは除く) |
| `makelocal.mk` | 自ディレクトリ限定 | 自ディレクトリのみ |
| `appdeps.mk` | app 直下依存宣言 | 自 app と依存 app の `prod/include` / `prod/lib` / `test/include` / `test/lib` 自動解決 |

これらのファイルは、記述する内容がある場合にだけ作成すれば十分です。  
設定が不要なときは、空のファイルを作成する必要はありません。

## makepart.mk

### 役割

`makepart.mk` は、makefw フレームワークにおける主要なカスタマイズ手段です。  
最終階層の makefile はすべて統一テンプレート (`__template.mk`) で統一されており、プロジェクト固有の設定はすべて `makepart.mk` に記述します。

```makefile
# app 配下 makefile テンプレート (__template.mk)
# すべての app/<app_name>/.../makefile で使用する標準テンプレート
# 本ファイルの直接編集は禁止する。
```

### 階層継承の仕組み

`makepart.mk` は `prepare.mk` により、ワークスペース ルートからカレント ディレクトリまでの各階層のものが順次インクルードされます。  
親階層で定義した設定が子階層に継承されるため、共通設定を上位に、固有設定を下位に配置できます。

```
prod/
+-- makepart.mk          # LIBS += baselib (子階層すべてに継承)
+-- myapp/
    +-- makepart.mk      # OUTPUT_DIR = ... (子階層すべてに継承)
    +-- libsrc/
        +-- mylib/
            +-- makefile # 上記すべての設定が有効
```

上記の例で `prod/myapp/libsrc/mylib/` でビルドを実行すると、インクルード順は以下のようになります。

1. `prod/makepart.mk`
2. `prod/myapp/makepart.mk`

いずれの設定もカレント ディレクトリのビルドに適用されます。

### 検索と読み込みの仕組み

`prepare.mk` は、カレント ディレクトリからワークスペース ルート (`.workspaceRoot` ファイルが存在するディレクトリ) まで遡って `makepart.mk` / `makechild.mk` を検索し、親階層から順にインクルードします。

再帰 make では、親 make が検索結果を環境変数として子 make へ渡します。
子 make は、親の検索結果に親の `makechild.mk` と自身の `makepart.mk` を追加するため、階層全体を検索し直しません。
末端ディレクトリで make を直接実行した場合や、継承した情報とカレント ディレクトリが一致しない場合は、従来どおりワークスペース ルートまで検索します。

```makefile
# 子 make での処理 (概要)
MAKE_INCLUDE_MK := $(MAKEFW_CONFIG_CACHE_FILES)
MAKE_INCLUDE_MK += $(wildcard $(親ディレクトリ)/makechild.mk)
MAKE_INCLUDE_MK += $(wildcard $(CURDIR)/makepart.mk)
```

### 主な設定項目

| 変数 | 説明 | 例 |
|------|------|-----|
| `LIBS` | リンクするライブラリ | `LIBS += calcbase` |
| `LIBSDIR` | ライブラリ検索パス | `LIBSDIR += $(MYAPP_DIR)/prod/lib` |
| `INCDIR` | インクルード検索パス | `INCDIR += $(MYAPP_DIR)/prod/include` |
| `DEFINES` | `-D` に変換される define 群 | `DEFINES += FEATURE_X` |
| `CFLAGS` | C コンパイラ フラグ | `CFLAGS += -DMYAPP_VERSION=\"1.0.0\"` |
| `CXXFLAGS` | C++ コンパイラ フラグ | `CXXFLAGS += -std=c++17` |
| `OUTPUT_DIR` | 出力先ディレクトリ | `OUTPUT_DIR := $(MYAPP_DIR)/prod/bin` |
| `LIB_TYPE` | ライブラリ種別 | `LIB_TYPE = shared` (デフォルトは static、`both` で両方生成) |
| `LINK_INPUTS` | リンカーへ直接渡す追加入力 (EXE / DLL) | `LINK_INPUTS += path/to/prebuilt.res` |
| `LINK_TEST` | テスト フレームワーク リンク | `LINK_TEST = 1` |
| `TEST_SRCS` | テスト対象ソース ファイル | `TEST_SRCS := $(MYAPP_DIR)/prod/.../add.c` |

### 記述例

**例 1: 動的ライブラリの指定**

```makefile
# app/calc/prod/libsrc/calc/makepart.mk
LIBS += calcbase

ifeq ($(OS),Windows_NT)
    # Windows: DLL エクスポート定義
    CFLAGS   += /DCALC_EXPORTS
    CXXFLAGS += /DCALC_EXPORTS
endif

# 生成されるライブラリを動的ライブラリ (shared) とする (デフォルトは static)
LIB_TYPE = shared
```

**例 1b: shared と static の両方を生成する**

```makefile
# app/calc/prod/libsrc/calc/makepart.mk
LIBS += calcbase

ifeq ($(OS),Windows_NT)
    CFLAGS   += /DCALC_EXPORTS
    CXXFLAGS += /DCALC_EXPORTS
endif

# shared と static の両方を生成する
# - shared: libcalc.so / libcalc.dll (+ libcalc.lib インポート ライブラリ)
# - static: libcalc_static.a / libcalc_static.lib
# 利用者は _static の有無でリンク方式を選択できる
LIB_TYPE = both
```

**例 2: 実行体の出力先統一**

```makefile
# app/calc/prod/src/makepart.mk
OUTPUT_DIR := $(MYAPP_DIR)/prod/bin
```

**例 3: テスト共通設定**

```makefile
# app/calc/test/makepart.mk

ifeq ($(OS),Windows_NT)
    CFLAGS   += /DCALC_STATIC
    CXXFLAGS += /DCALC_STATIC
endif
```

`INCDIR` と `LIBSDIR` の依存 app / test 用のパスは `prepare.mk` が補完するため、個別の `makepart.mk` では Windows 向けの静的定義だけを残せます。

**例 4: テスト対象ソースの指定**

```makefile
# app/calc/test/src/libcalcbaseTest/addTest/makepart.mk
TEST_SRCS := \
    $(MYAPP_DIR)/prod/libsrc/calcbase/add.c
```

**例 5: Windows リソース (.mc / .rc) を埋め込む**

ソース ディレクトリに `.mc` (メッセージ テーブル) または `.rc` を置くだけで、makefw が自動的に `mc.exe` / `rc.exe` で `.res` へコンパイルし、実行体 (EXE) または共有ライブラリ (DLL) のリンクに含めます。
makepart.mk / makelocal.mk への記述は不要です。

```text
src/cmd/myapp/
  myapp.c
  messages.mc   <- 置くだけで自動コンパイル・リンク
```

- Windows 専用です (`mc.exe` / `rc.exe` は Windows SDK のツール)。Linux では無視されます。
- `.mc` は `mc.exe` でヘッダー / `.rc` / `.bin` を生成した後、`rc.exe` で `.res` にします。単体 `.rc` は `rc.exe` で直接 `.res` にします。
- メッセージ コンパイラのフラグは `MCFLAGS` (既定 `-U`)、リソース コンパイラのフラグは `RCFLAGS` で上書きできます。
- 静的ライブラリ (`.lib` / `.a`) は `.res` を保持できないため対象外です。
- 同名 stem の `.mc` と `.rc` を同一ディレクトリに置かないでください (どちらも `<name>.res` を生成し衝突します)。
- `.mc` / `.rc` はビルドのスキップ判定 (署名) の対象です。これらを変更すると次回ビルドで再コンパイル・再リンクが走ります。

生成済みの `.res` など、makefw のコンパイル対象外のファイルを手動でリンカーへ渡したい場合は、`LINK_INPUTS` に直接追加します。

```makefile
# 任意: 外部で用意した .res を直接リンクする (高度なケース)
LINK_INPUTS += path/to/prebuilt.res
```

`LINK_INPUTS` は EXE / DLL リンク時の依存関係と再リンク判定に使われ、リンカー入力として直接渡されます。

**例 6: app 直下で IntelliSense 用の正本を持つ**

```makefile
# app/calc/makepart.mk
# インクルードの検索パス
INCDIR += \
    $(MYAPP_DIR)/../com_util/prod/include \
    $(MYAPP_DIR)/prod/include
```

この `INCDIR` / `DEFINES` は make のビルド設定だけでなく、`.vscode/c_cpp_properties.json` を更新する際の正本としても扱います。  
ただし同期対象の範囲は同一ではありません。`INCDIR` は `app/<name>` 配下のすべての `makepart.mk` が対象で、下位 `makepart.mk` の追加 include も `.vscode/c_cpp_properties.json` に反映されます。  
`DEFINES` は `makepart.mk`、`app/makepart.mk`、`app/<name>/makepart.mk` を正本として扱い、`.vscode` の `defines` には `TARGET_ARCH=target_arch` の特殊条件があるため、実ビルド時の値ではなく同期スクリプト側の dummy 値が使われます。

## appdeps.mk

### 役割

`appdeps.mk` は `app/<name>/` 直下に置く app 間依存の一次情報です。`APP_DEPS` に直接依存する app 名を列挙します。

```makefile
# app/porter/appdeps.mk
APP_DEPS := com_util
```

### 挙動

- `prepare.mk` は自 app と `APP_DEPS` の再帰依存を解決する
- `app/makefile` は `APP_DEPS` を使って `SUBDIRS` の build 順序を自動決定する
- 解決済み app ごとに `app/<name>/prod/include` と `app/<name>/prod/lib` を自動追加する
- `/test/` 配下では同じ依存閉包に対して `app/<name>/test/include` と `app/<name>/test/lib` を自動追加する
- 自 app の `app/<name>/prod/include_internal` を自動追加する
- `app/makepart.mk` が `/test/` 配下のビルドに対して `framework/testfw/lib` と `LINK_TEST = 1` を付与する
- 依存 app の `prod/include_internal` は自動追加しない
- 依存 app ディレクトリが存在しない場合は定義エラーとして make を停止する
- 循環依存があっても訪問済み管理で無限ループしない

### 運用ルール

- `APP_DEPS` には直接依存だけを書く
- build 順だけに必要な依存も `APP_DEPS` に書く
- `../otherapp/prod/include` や `../otherapp/prod/lib` を `makepart.mk` に手書きしない
- 自 app の `prod/include`、`prod/include_internal`、`prod/lib` は自動追加されるため、app 直下 `makepart.mk` には通常書かない

## makechild.mk

### 役割

`makechild.mk` は、**自身より 1 つ下の階層以降** にのみ適用される設定ファイルです。  
定義した内容は自ディレクトリには適用されず、子階層以降にのみ有効です。

`makepart.mk` は自ディレクトリを含む子階層すべてに継承されますが、「自ディレクトリには適用したくないが、すべての子ディレクトリには共通して適用したい」設定を記述するのが `makechild.mk` の役割です。

### スコープの詳細

以下のディレクトリ構成を例に説明します。

```
prod/
+-- makechild.mk          # ← (A)
+-- myapp/
    +-- makechild.mk      # ← (B)
    +-- libsrc/
        +-- mylib/
            +-- makefile  # ← ここでビルド実行
```

`prod/myapp/libsrc/mylib/` でビルドを実行した場合:

| ファイル | 適用されるか |
|---------|------------|
| `prod/makechild.mk` (A) | **適用される** (`mylib/` は `prod/` の子孫) |
| `prod/myapp/makechild.mk` (B) | **適用される** (`mylib/` は `myapp/` の子孫) |

`prod/myapp/` でビルドを実行した場合:

| ファイル | 適用されるか |
|---------|------------|
| `prod/makechild.mk` (A) | **適用される** (`myapp/` は `prod/` の子) |
| `prod/myapp/makechild.mk` (B) | **適用されない** (自ディレクトリは除く) |

### 実装

各ディレクトリ レベルごとに、`makepart.mk`、`makechild.mk` の順でインクルードされます。  
ただしカレント ディレクトリの `makechild.mk` は除外されます。

```makefile
# prepare.mk 内の処理
define _include_make_config
$(eval include $(1))
endef

$(foreach make_config, $(MAKE_INCLUDE_MK), $(call _include_make_config,$(make_config)))
```

- `makechild.mk` は検索時点でカレント ディレクトリを除外
- `makepart.mk` と `makechild.mk` は実在するファイルだけを include
- 同一階層では `makepart.mk` の直後に `makechild.mk` を include

### 記述例

**例 1: 子ディレクトリ全体に共通フラグを追加**

```makefile
# prod/myapp/makechild.mk
# myapp/ の子ディレクトリすべてに適用、myapp/ 自身には適用されない
CFLAGS += -DMYAPP_CHILD_BUILD
```

**例 2: 子ディレクトリ全体への出力先設定**

```makefile
# prod/myapp/makechild.mk
# myapp/ 以下のすべてのビルドの出力先を統一 (myapp/ 自身は除く)
OUTPUT_DIR := $(WORKSPACE_DIR)/bin/myapp
```

**例 3: サブフォルダーコンパイル方式の設定**

```makefile
# app/subfolder-sample/prod/libsrc/libsubfolder-sample/makechild.mk
# 各サブフォルダーはコンパイルのみとし、リンクはライブラリルートで行う
NO_LINK = 1
```

`NO_LINK = 1` を `makechild.mk` に設定することで、カレント ディレクトリ (`libsubfolder-sample/`) は  
全サブフォルダーのオブジェクトを収集してリンクし、子ディレクトリ (`audio/` 等) はコンパイルのみとなります。  
詳細は [サブフォルダーコンパイル](../../../app/c-modernization-kit/docs/subfolder-compilation.md) を参照してください。

## makelocal.mk

### 役割

`makelocal.mk` は、自ディレクトリに限定される設定ファイルです。  
`makepart.mk` の階層継承とは異なり、定義した内容は子階層に継承されません。

特定のディレクトリのみに適用したい設定 (フック、ローカル フラグなど) を `makepart.mk` に定義すると、そのディレクトリ以下のすべてのサブフォルダーでも有効になってしまいます。  
このような場合に `makelocal.mk` を使用します。

### 実装

`prepare.mk` の最後で、カレント ディレクトリの `makelocal.mk` を読み込みます。

```makefile
# prepare.mk の最後
-include $(CURDIR)/makelocal.mk
```

- `-include` を使用することで、ファイルが存在しない場合もエラーにならない
- `$(CURDIR)` はカレント ディレクトリを指すため、継承は発生しない

### 記述例

**例 1: ディレクトリ固有の変数設定**

```makefile
# prod/myapp/src/myapp/makelocal.mk
# このディレクトリのみに適用
EXTRA_LDFLAGS := -lspeciallib
```

**例 2: フック ターゲットの定義**

```makefile
# prod/myapp/libsrc/generated/makelocal.mk
.PHONY: pre-build
pre-build:
    @echo "Generating code..."
    python $(WORKSPACE_DIR)/tools/codegen.py
```

**例 3: 走査 makefile のローカル順序指定**

```makefile
# prod/myapp/makelocal.mk
# このディレクトリの走査順のみを上書き
SUBDIRS := \
    libsrc \
    src
```

`prod/test` 配下の中間階層走査 makefile では、`SUBDIRS` を `makelocal.mk` に置くことで  
継承なしで順序だけを制御できます。

## MYAPP_DIR / APP_DIR

### 概要

`MYAPP_DIR` は、ビルド対象の app のルート ディレクトリを指す変数です。  
`app/{appname}/` 配下の `makepart.mk` / `makechild.mk` / `makelocal.mk` で使用でき、`$(WORKSPACE_DIR)/app/{appname}/...` の代わりに `$(MYAPP_DIR)/...` と記述できます。

`APP_DIR` は、`app/` のルート ディレクトリを指す変数です。  
同じ有効範囲で使用でき、他 app への参照を `$(APP_DIR)/{otherapp}/...` と記述できます。

これにより、app 内の設定を「app 単位」で記述でき、将来 app 単位でサブモジュール化した場合も app 内の記述を変更せずに済みます。

### 有効範囲

| 場所 | MYAPP_DIR | APP_DIR | 説明 |
|------|:---:|:---:|------|
| `app/calc/makepart.mk` | ✓ | ✓ | `MYAPP_DIR=/path/to/workspace/app/calc`, `APP_DIR=/path/to/workspace/app` |
| `app/calc/prod/libsrc/calcbase/makepart.mk` | ✓ | ✓ | `MYAPP_DIR=/path/to/workspace/app/calc`, `APP_DIR=/path/to/workspace/app` |
| `app/com_util/test/src/.../makepart.mk` | ✓ | ✓ | `MYAPP_DIR=/path/to/workspace/app/com_util`, `APP_DIR=/path/to/workspace/app` |
| `app/makepart.mk` | ✗ | ✗ | app/ 直下 — `$(WORKSPACE_DIR)` を使用 |
| `makepart.mk` (ルート) | ✗ | ✗ | ルート — `$(WORKSPACE_DIR)` を使用 |
| `framework/` 配下 | ✗ | ✗ | フレームワーク — 対象外 |

無効範囲で `$(MYAPP_DIR)` または `$(APP_DIR)` を参照すると、Make の `$(error ...)` により明示的なエラーが発生します。

### 記述ルール

#### 自 app 内の参照

```makefile
# app/calc/makepart.mk
INCDIR += $(MYAPP_DIR)/prod/include
OUTPUT_DIR := $(MYAPP_DIR)/prod/bin
```

#### 他 app の参照 (cross-app)

```makefile
# app/calc/makepart.mk
INCDIR += $(APP_DIR)/com_util/prod/include
```

既存の `$(MYAPP_DIR)/../com_util/...` もビルド時に `realpath -m` で正規化されますが、新規記述では `$(APP_DIR)/com_util/...` を使用します。

#### repo 全体の参照

```makefile
# app/makepart.mk (app/ 直下)
# MYAPP_DIR / APP_DIR は無効なため、WORKSPACE_DIR を使用
INCDIR += $(WORKSPACE_DIR)/framework/testfw/include
```

### 内部動作

1. `prepare.mk` が `CURDIR` から `app/<appname>` を抽出し、`APP_DIR` と `MYAPP_DIR` に絶対パスを設定
2. `makepart.mk` / `makechild.mk` / `makelocal.mk` の読み込み後、パス系変数 (`INCDIR`, `LIBSDIR`, `OUTPUT_DIR`, `TEST_SRCS`, `ADD_SRCS`) を一括正規化
3. 正規化は `realpath -m` (Linux) / `realpath -m` + `cygpath -m` (Windows) で実行
4. コンパイラに渡されるパスは常に `..` を含まない絶対パス

## インクルード順序

3 種類の設定ファイルは、`prepare.mk` 内で以下の順序でインクルードされます。

```
1. prepare.mk
   +-- /a/makepart.mk          (親: 自ディレクトリ含む継承)
   +-- /a/makechild.mk         (親: 子階層以降に適用)
   +-- /a/b/makepart.mk        (中間: 継承)
   +-- /a/b/makechild.mk       (中間: 子階層以降に適用)
   +-- /a/b/c/makepart.mk      (カレント: 継承)
   ※ /a/b/c/makechild.mk は除く (カレントディレクトリのため)
   +-- makelocal.mk            (自ディレクトリのみ、継承なし)

2. makemain.mk
   +-- テンプレート (makelibsrc_c_cpp.mk など)  ※ MAKEFW_BUILD=1 の場合のみ
   ※ MAKEFW_BUILD が未設定の場合は直下のソース有無で自動判定し、ソースが存在すればテンプレートを include する
```

各ディレクトリ レベルごとに `makepart.mk` → `makechild.mk` の順でインクルードされ、最後にカレント ディレクトリの `makelocal.mk` が読み込まれます。

## 配置の指針

| 設定項目 | 配置先 | 理由 |
|---------|--------|------|
| `LIBS`, `LIBSDIR` | makepart.mk | 自ディレクトリ含む子階層に継承させたい |
| `CFLAGS`, `CXXFLAGS` | makepart.mk | 共通のコンパイル オプション (自身も含む) |
| `OUTPUT_DIR` | makepart.mk | 出力先の統一 |
| `LIB_TYPE` | makepart.mk | ライブラリ種別の指定 |
| `TEST_SRCS` | makepart.mk | テスト対象ソースの指定 |
| 子のみに適用するフラグ | makechild.mk | 自ディレクトリには適用させたくない |
| 子のみへの出力先設定 | makechild.mk | 自ディレクトリのビルドは別設定にしたい |
| フック ターゲット | makelocal.mk | 自ディレクトリのみに限定 |
| ローカル変数 | makelocal.mk | 継承させたくない設定 |
| `SUBDIRS` の順序指定 | makelocal.mk | 走査順を自ディレクトリだけで変えたい |

## 併用例

```makefile
# prod/myapp/makepart.mk
# myapp/ 自身も含む、子階層にも継承される設定
LIBS += mybaselib
```

```makefile
# prod/myapp/makechild.mk
# myapp/ の子ディレクトリのみに適用
CFLAGS += -DCHILD_ONLY_FLAG
```

```makefile
# prod/myapp/makelocal.mk
# myapp/ 自身のみに適用
MY_LOCAL_VAR := 1
```

この構成により、`prod/myapp/` でビルドした場合:

- `LIBS += mybaselib` が適用される (makepart.mk)
- `CFLAGS += -DCHILD_ONLY_FLAG` は **適用されない** (makechild.mk は自身を除く)
- `MY_LOCAL_VAR := 1` が適用される (makelocal.mk)

`prod/myapp/libsrc/mylib/` でビルドした場合:

- `LIBS += mybaselib` が適用される (makepart.mk が継承)
- `CFLAGS += -DCHILD_ONLY_FLAG` が **適用される** (makechild.mk が子階層に適用)
- `MY_LOCAL_VAR := 1` は **適用されない** (makelocal.mk は自ディレクトリ限定)

## ホスト環境プローブと同期評価 (MAKEFW_SYNC_EVAL)

`bin/sync_c_cpp_properties.sh` は `.vscode/c_cpp_properties.json` の同期のために、ホスト OS に関係なく Linux 構成 (`PLATFORM_LINUX := 1`) と Windows 構成 (`PLATFORM_WINDOWS := 1`) の両方で各 `makepart.mk` を評価します。
このため、Windows ホスト上でも `ifdef PLATFORM_LINUX` ブロックが評価されます (逆も同様)。

この同期評価では、一時 makefile に `MAKEFW_SYNC_EVAL := 1` が定義されます。
`makepart.mk` で `$(shell ...)` によるホスト環境のプローブ (`pkg-config` など) と `$(error)` を組み合わせる場合は、必ず `ifndef MAKEFW_SYNC_EVAL` でガードし、実ビルド時のみ前提条件チェックを行ってください。
ガードがないと、対象プラットフォームのコマンドやライブラリが存在しないホストでの同期評価が `$(error)` で失敗し、ビルド後の同期チェック全体がエラー終了します。

```makefile
# app/service-sample/prod/src/cmd/makepart.mk
ifdef PLATFORM_LINUX
    # libsystemd を直接リンクする
    # ホスト環境のプローブは実ビルド時 (MAKEFW_SYNC_EVAL 未定義時) のみ行う
    ifndef MAKEFW_SYNC_EVAL
        ifneq ($(shell pkg-config --exists libsystemd && echo 1),1)
            $(error libsystemd の開発ファイルが見つかりません)
        endif
    endif
    LIBS += systemd
endif
```

## TEST_SRCS / ADD_SRCS の留意事項

### ビルド システムによるソース ファイルの分類

`TEST_SRCS` と `ADD_SRCS` に指定したソース ファイルは、`make test` 時に `_collect_srcs.mk` が以下の 3 種類に自動分類し、テストのビルド ディレクトリへ取り込む。

| 分類 | 説明 | 条件 |
|------|------|------|
| `DIRECT_SRCS` | テスト フォルダーに既存の実体ファイル | カレント ディレクトリに実ファイルが存在し、かつシンボリック リンクでない |
| `LINK_SRCS` | シンボリック リンクで引き込むファイル | Linux 環境で、inject ファイルおよびフィルター ファイルがない場合 |
| `CP_SRCS` | コピーで引き込むファイル | Windows 環境の場合、または inject / フィルター ファイルが存在する場合 |

通常の関数単体テスト (Linux 環境、inject なし) では `TEST_SRCS` に指定したファイルは `LINK_SRCS` として処理され、テスト ビルド ディレクトリ内の当該ファイル名は `prod/` にある実体ファイルへのシンボリック リンクとなる。

### ビルド ディレクトリ内のファイルを直接変更しないこと

`make test` のたびにビルド ディレクトリ内の `LINK_SRCS` / `CP_SRCS` は再生成される。そのため、ビルド ディレクトリ内のファイルを直接変更しても、次回の `make test` で上書きされ変更が失われる。

**ソース コードを変更する場合は、`prod/` にある実体ファイルを変更すること。**

例として `app/calc/test/src/libcalcbaseTest/addTest/add.c` は `app/calc/prod/libsrc/calcbase/add.c` へのシンボリック リンクである。このファイルを変更したい場合は `app/calc/prod/libsrc/calcbase/add.c` を変更する。
