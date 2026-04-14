# makepart.mk / makechild.mk / makelocal.mk について

## 概要

makefw フレームワークでは、ビルド設定のカスタマイズに 3 種類の設定ファイルを提供しています。
これらのファイルにより、最終階層の makefile を一切編集することなく、プロジェクト固有の設定を柔軟に管理できます。

| ファイル | スコープ | 適用対象 |
|---------|---------|---------|
| `makepart.mk` | 階層継承 (親→子に伝播) | 自ディレクトリ + 子階層すべて |
| `makechild.mk` | 子階層限定 (自身は除く) | 子階層以降のみ (自ディレクトリは除く) |
| `makelocal.mk` | 自ディレクトリ限定 | 自ディレクトリのみ |

## makepart.mk

### 役割

`makepart.mk` は、makefw フレームワークにおける主要なカスタマイズ手段です。
最終階層の makefile はすべて統一テンプレート (`__template.mk`) で統一されており、プロジェクト固有の設定はすべて `makepart.mk` に記述します。

```makefile
# makefile テンプレート (__template.mk)
# すべての最終階層 makefile で使用する標準テンプレート
# 本ファイルの編集は禁止する。makepart.mk を作成して拡張・カスタマイズすること。
```

### 階層継承の仕組み

`makepart.mk` は `prepare.mk` により、ワークスペースルートからカレントディレクトリまでの各階層のものが順次インクルードされます。
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

いずれの設定もカレントディレクトリのビルドに適用されます。

### 検索と読み込みの仕組み

`prepare.mk` 内で、カレントディレクトリからワークスペースルート (`.workspaceRoot` ファイルが存在するディレクトリ) まで遡って `makepart.mk` を検索し、逆順 (親階層から) にインクルードします。

```makefile
# prepare.mk 内の処理 (概要)
MAKEPART_MK := $(shell \
    dir=`pwd`; \
    while [ "$$dir" != "/" ]; do \
        if [ -f "$$dir/makepart.mk" ]; then \
            echo "$$dir/makepart.mk"; \
        fi; \
        if [ -f "$$dir/.workspaceRoot" ]; then \
            break; \
        fi; \
        dir=$${dir%/*}; \
        if [ -z "$$dir" ]; then dir=/; fi; \
    done \
)

# 逆順にして親階層から順次 include
_reverse = $(if $(1),$(call _reverse,$(wordlist 2,$(words $(1)),$(1))) $(firstword $(1)))
MAKEPART_MK := $(strip $(call _reverse,$(MAKEPART_MK)))
```

### 主な設定項目

| 変数 | 説明 | 例 |
|------|------|-----|
| `LIBS` | リンクするライブラリ | `LIBS += calcbase` |
| `LIBSDIR` | ライブラリ検索パス | `LIBSDIR += $(MYAPP_DIR)/test/lib` |
| `INCDIR` | インクルード検索パス | `INCDIR += $(MYAPP_DIR)/prod/include` |
| `DEFINES` | `-D` に変換される define 群 | `DEFINES += FEATURE_X` |
| `CFLAGS` | C コンパイラフラグ | `CFLAGS += -DMYAPP_VERSION=\"1.0.0\"` |
| `CXXFLAGS` | C++ コンパイラフラグ | `CXXFLAGS += -std=c++17` |
| `OUTPUT_DIR` | 出力先ディレクトリ | `OUTPUT_DIR := $(MYAPP_DIR)/prod/bin` |
| `LIB_TYPE` | ライブラリ種別 | `LIB_TYPE = shared` (デフォルトは static) |
| `LINK_TEST` | テストフレームワークリンク | `LINK_TEST = 1` |
| `TEST_SRCS` | テスト対象ソースファイル | `TEST_SRCS := $(MYAPP_DIR)/prod/.../add.c` |

### 記述例

**例1: 動的ライブラリの指定**

```makefile
# prod/calc/libsrc/calc/makepart.mk
LIBS += calcbase

ifeq ($(OS),Windows_NT)
    # Windows: DLL エクスポート定義
    CFLAGS   += /DCALC_EXPORTS
    CXXFLAGS += /DCALC_EXPORTS
endif

# 生成されるライブラリを動的ライブラリ (shared) とする (デフォルトは static)
LIB_TYPE = shared
```

**例2: 実行体の出力先統一**

```makefile
# app/calc/prod/src/makepart.mk
OUTPUT_DIR := $(MYAPP_DIR)/prod/bin
```

**例3: テスト共通設定**

```makefile
# app/calc/test/makepart.mk
LINK_TEST = 1

ifeq ($(OS),Windows_NT)
    CFLAGS   += /DCALC_STATIC
    CXXFLAGS += /DCALC_STATIC
endif

LIBSDIR += \
    $(TESTFW_DIR)/lib \
    $(MYAPP_DIR)/test/lib
```

**例4: テスト対象ソースの指定**

```makefile
# app/calc/test/src/libcalcbaseTest/addTest/makepart.mk
TEST_SRCS := \
    $(MYAPP_DIR)/prod/libsrc/calcbase/add.c
```

**例5: app 直下で IntelliSense 用の正本を持つ**

```makefile
# app/calc/makepart.mk
INCDIR += \
    $(MYAPP_DIR)/prod/include \
    $(MYAPP_DIR)/test/include \
    $(MYAPP_DIR)/../com_util/prod/include \
    $(TESTFW_DIR)/gtest/include \
    $(TESTFW_DIR)/include
```

この `INCDIR` / `DEFINES` は make のビルド設定だけでなく、`.vscode/c_cpp_properties.json` を更新する際の正本としても扱います。  
ただし `.vscode` の `defines` には `TARGET_ARCH=target_arch` の特殊条件があり、実ビルド時の値ではなく同期スクリプト側の dummy 値が使われます。

## makechild.mk

### 役割

`makechild.mk` は、**自身より1つ下の階層以降** にのみ適用される設定ファイルです。
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

各 `makepart.mk` のインクルード直後に、同ディレクトリの `makechild.mk` が存在すれば続けてインクルードされます。
ただしカレントディレクトリの `makechild.mk` は除外されます。

```makefile
# prepare.mk 内の処理
define _include_makepart_and_child
$(eval include $(1))$(if $(filter-out $(CURDIR)/makepart.mk,$(1)),$(eval -include $(patsubst %/makepart.mk,%/makechild.mk,$(1))))
endef

$(foreach makepart, $(MAKEPART_MK), $(call _include_makepart_and_child,$(makepart)))
```

- `$(filter-out $(CURDIR)/makepart.mk,$(1))` でカレントディレクトリを除外
- `$(patsubst %/makepart.mk,%/makechild.mk,$(1))` でパスを `makechild.mk` に変換
- `-include` を使用することで、ファイルが存在しない場合もエラーにならない

### 記述例

**例1: 子ディレクトリ全体に共通フラグを追加**

```makefile
# prod/myapp/makechild.mk
# myapp/ の子ディレクトリすべてに適用、myapp/ 自身には適用されない
CFLAGS += -DMYAPP_CHILD_BUILD
```

**例2: 子ディレクトリ全体への出力先設定**

```makefile
# prod/myapp/makechild.mk
# myapp/ 以下のすべてのビルドの出力先を統一 (myapp/ 自身は除く)
OUTPUT_DIR := $(WORKSPACE_DIR)/bin/myapp
```

## makelocal.mk

### 役割

`makelocal.mk` は、自ディレクトリに限定される設定ファイルです。
`makepart.mk` の階層継承とは異なり、定義した内容は子階層に継承されません。

特定のディレクトリのみに適用したい設定 (フック、ローカルフラグなど) を `makepart.mk` に定義すると、そのディレクトリ以下のすべてのサブフォルダでも有効になってしまいます。
このような場合に `makelocal.mk` を使用します。

### 実装

`prepare.mk` の最後で、カレントディレクトリの `makelocal.mk` を読み込みます。

```makefile
# prepare.mk の最後
-include $(CURDIR)/makelocal.mk
```

- `-include` を使用することで、ファイルが存在しない場合もエラーにならない
- `$(CURDIR)` はカレントディレクトリを指すため、継承は発生しない

### 記述例

**例1: ディレクトリ固有の変数設定**

```makefile
# prod/myapp/src/myapp/makelocal.mk
# このディレクトリのみに適用
EXTRA_LDFLAGS := -lspeciallib
```

**例2: フックターゲットの定義**

```makefile
# prod/myapp/libsrc/generated/makelocal.mk
.PHONY: pre-build
pre-build:
    @echo "Generating code..."
    python $(WORKSPACE_DIR)/tools/codegen.py
```

**例3: 走査 makefile のローカル順序指定**

```makefile
# prod/myapp/makelocal.mk
# このディレクトリの走査順のみを上書き
SUBDIRS := \
    libsrc \
    src
```

`prod/test` 配下の中間階層走査 makefile では、`SUBDIRS` を `makelocal.mk` に置くことで
継承なしで順序だけを制御できます。

## MYAPP_DIR

### 概要

`MYAPP_DIR` は、ビルド対象の app のルートディレクトリを指す変数です。  
`app/{appname}/` 配下の `makepart.mk` / `makechild.mk` / `makelocal.mk` で使用でき、`$(WORKSPACE_DIR)/app/{appname}/...` の代わりに `$(MYAPP_DIR)/...` と記述できます。

これにより、app 内の設定を「app 単位」で記述でき、将来 app 単位でサブモジュール化した場合も app 内の記述を変更せずに済みます。

### 有効範囲

| 場所 | MYAPP_DIR | 説明 |
|------|:---:|------|
| `app/calc/makepart.mk` | ✓ | `/path/to/workspace/app/calc` |
| `app/calc/prod/libsrc/calcbase/makepart.mk` | ✓ | `/path/to/workspace/app/calc` |
| `app/com_util/test/src/.../makepart.mk` | ✓ | `/path/to/workspace/app/com_util` |
| `app/makepart.mk` | ✗ | app/ 直下 — `$(WORKSPACE_DIR)` を使用 |
| `makepart.mk` (ルート) | ✗ | ルート — `$(WORKSPACE_DIR)` を使用 |
| `framework/` 配下 | ✗ | フレームワーク — 対象外 |

無効範囲で `$(MYAPP_DIR)` を参照すると、Make の `$(error ...)` により明示的なエラーが発生します。

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
INCDIR += $(MYAPP_DIR)/../com_util/prod/include
```

`$(MYAPP_DIR)/../com_util/...` の `..` は、ビルド時に `realpath -m` で正規化され、コンパイラには `..` を含まない絶対パスが渡されます。

#### repo 全体の参照

```makefile
# app/makepart.mk (app/ 直下)
# MYAPP_DIR は無効なため、WORKSPACE_DIR を使用
INCDIR += $(WORKSPACE_DIR)/framework/testfw/include
```

### 内部動作

1. `prepare.mk` が `CURDIR` から `app/<appname>` を抽出し、`MYAPP_DIR` に絶対パスを設定
2. `makepart.mk` / `makechild.mk` / `makelocal.mk` の読み込み後、パス系変数 (`INCDIR`, `LIBSDIR`, `OUTPUT_DIR`, `TEST_SRCS`, `ADD_SRCS`) を一括正規化
3. 正規化は `realpath -m` (Linux) / `realpath -m` + `cygpath -m` (Windows) で実行
4. コンパイラに渡されるパスは常に `..` を含まない絶対パス

## インクルード順序

3 種類の設定ファイルは、`prepare.mk` 内で以下の順序でインクルードされます。

```
1. prepare.mk
   +-- /a/makepart.mk          (親: 自ディレクトリ含む継承)
   +-- /a/makechild.mk         (親: 子階層以降に適用 ← makepart.mk の直後)
   +-- /a/b/makepart.mk        (中間: 継承)
   +-- /a/b/makechild.mk       (中間: 子階層以降に適用 ← makepart.mk の直後)
   +-- /a/b/c/makepart.mk      (カレント: 継承)
   ※ /a/b/c/makechild.mk は除く (カレントディレクトリのため)
   +-- makelocal.mk            (自ディレクトリのみ、継承なし)

2. makemain.mk
   +-- テンプレート (makelibsrc_c_cpp.mk など)
```

各ディレクトリレベルごとに `makepart.mk` → `makechild.mk` の順でインクルードされ、最後にカレントディレクトリの `makelocal.mk` が読み込まれます。

## 配置の指針

| 設定項目 | 配置先 | 理由 |
|---------|--------|------|
| `LIBS`, `LIBSDIR` | makepart.mk | 自ディレクトリ含む子階層に継承させたい |
| `CFLAGS`, `CXXFLAGS` | makepart.mk | 共通のコンパイルオプション (自身も含む) |
| `OUTPUT_DIR` | makepart.mk | 出力先の統一 |
| `LIB_TYPE` | makepart.mk | ライブラリ種別の指定 |
| `TEST_SRCS` | makepart.mk | テスト対象ソースの指定 |
| 子のみに適用するフラグ | makechild.mk | 自ディレクトリには適用させたくない |
| 子のみへの出力先設定 | makechild.mk | 自ディレクトリのビルドは別設定にしたい |
| フックターゲット | makelocal.mk | 自ディレクトリのみに限定 |
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
- `CFLAGS += -DCHILD_ONLY_FLAG` は**適用されない** (makechild.mk は自身を除く)
- `MY_LOCAL_VAR := 1` が適用される (makelocal.mk)

`prod/myapp/libsrc/mylib/` でビルドした場合:
- `LIBS += mybaselib` が適用される (makepart.mk が継承)
- `CFLAGS += -DCHILD_ONLY_FLAG` が**適用される** (makechild.mk が子階層に適用)
- `MY_LOCAL_VAR := 1` は**適用されない** (makelocal.mk は自ディレクトリ限定)
