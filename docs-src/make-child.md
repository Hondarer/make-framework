# makechild.mk 仕様

## 概要

`makechild.mk` は、**自身より1つ下の階層以降**にのみ適用される設定ファイルです。
定義した内容は自ディレクトリには適用されず、子階層以降にのみ有効です。

## 3種類の設定ファイルの比較

| ファイル | スコープ | 適用対象 |
|---------|---------|---------|
| `makepart.mk` | 階層継承 (親→子に伝播) | 自ディレクトリ + 子階層すべて |
| `makechild.mk` | 子階層限定 (自身は除く) | 子階層以降のみ (自ディレクトリは除く) |
| `makelocal.mk` | 自ディレクトリ限定 | 自ディレクトリのみ |

## 背景

`makepart.mk` は自ディレクトリを含む子階層すべてに継承されます。
`makelocal.mk` は自ディレクトリのみに適用されます。

しかし、「自ディレクトリには適用したくないが、すべての子ディレクトリには共通して適用したい」設定を記述する手段がありませんでした。例えば:

- あるディレクトリ以下のすべての子ビルドに共通のフラグを追加したい
- 自ディレクトリのビルドには影響させず、子ディレクトリにのみフックを設定したい

このような場合に `makechild.mk` を使用します。

## インクルード順序

各ディレクトリレベルごとに `makepart.mk` の直後に同ディレクトリの `makechild.mk` がインクルードされます。
これにより、同一ディレクトリの `makepart.mk` による設定の直後に `makechild.mk` による子向けオーバーライドが適用されます。

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

## スコープの詳細

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

## 実装

### prepare.mk での読み込み処理

各 `makepart.mk` のインクルード直後に、同ディレクトリの `makechild.mk` が存在すれば続けてインクルードします。
ただしカレントディレクトリの `makechild.mk` は除きます。

```makefile
define _include_makepart_and_child
$(eval include $(1))$(if $(filter-out $(CURDIR)/makepart.mk,$(1)),$(eval -include $(patsubst %/makepart.mk,%/makechild.mk,$(1))))
endef

$(foreach makepart, $(MAKEPART_MK), $(call _include_makepart_and_child,$(makepart)))
```

- `$(filter-out $(CURDIR)/makepart.mk,$(1))` でカレントディレクトリを除外
- `$(patsubst %/makepart.mk,%/makechild.mk,$(1))` でパスを `makechild.mk` に変換
- `-include` を使用することで、ファイルが存在しない場合もエラーにならない
- 各ディレクトリの `makepart.mk` の直後にその `makechild.mk` が適用されるため、設定の上書き順が直感的

## 使用例

### 例1: 子ディレクトリ全体に共通フラグを追加

```makefile
# prod/myapp/makechild.mk
# myapp/ の子ディレクトリすべてに適用、myapp/ 自身には適用されない
CFLAGS += -DMYAPP_CHILD_BUILD
```

### 例2: makepart.mk と makechild.mk の併用

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

### 例3: 子ディレクトリ全体への出力先設定

```makefile
# prod/myapp/makechild.mk
# myapp/ 以下のすべてのビルドの出力先を統一 (myapp/ 自身は除く)
OUTPUT_DIR := $(WORKSPACE_FOLDER)/bin/myapp
```

## 配置の指針

| 設定項目 | 配置先 | 理由 |
|---------|--------|------|
| `LIBS`, `LIBSDIR` | makepart.mk | 自ディレクトリ含む子階層に継承させたい |
| `CFLAGS`, `CXXFLAGS` | makepart.mk | 共通のコンパイルオプション (自身も含む) |
| 子のみに適用するフラグ | makechild.mk | 自ディレクトリには適用させたくない |
| 子のみへの出力先設定 | makechild.mk | 自ディレクトリのビルドは別設定にしたい |
| フックターゲット | makelocal.mk | 自ディレクトリのみに限定 |
| ローカル変数 | makelocal.mk | 継承させたくない設定 |
