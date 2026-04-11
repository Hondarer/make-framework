# makefile の `PLATFORM_*` コーディングガイドライン

## 概要

makefile における OS 判定は、`framework/makefw/makefiles/prepare.mk` が定義する `PLATFORM_WINDOWS` / `PLATFORM_LINUX` / `PLATFORM_UNKNOWN` に集約します。

利用側の makefile は `$(OS)`、`Windows_NT`、`uname -s` を直接判定せず、`PLATFORM_*` ベースで分岐してください。

`PLATFORM_UNKNOWN` は `prepare.mk` で早期エラーにする前提です。  
そのため、通常の makefile では Linux と Windows のみを対象に、明示的に `PLATFORM_*` を判定します。

C 側の `#if defined(PLATFORM_LINUX)` に対応する make 側の正規形は、`ifdef PLATFORM_LINUX` です。

## 基本ルール

### OS 判定は `PLATFORM_*` を使う

- Linux 判定: `PLATFORM_LINUX`
- Windows 判定: `PLATFORM_WINDOWS`
- 未知の環境: `PLATFORM_UNKNOWN`

`$(OS)` や `Windows_NT` をアプリケーション側の makefile に直接書かないでください。

`PLATFORM_*` は「選択されたものだけ `1` で定義し、非選択肢は未定義」とします。  
そのため、make ディレクティブでは `ifdef PLATFORM_LINUX` のように書きます。

```makefile
ifdef PLATFORM_LINUX
    # Linux 向け処理
else ifdef PLATFORM_WINDOWS
    # Windows 向け処理
endif
```

### OS 意味の `else` を使わない

Linux/Windows 二択でも、Windows 側を単なる `else` にしません。  
必ず `else ifdef PLATFORM_WINDOWS` と明示します。

```makefile
ifdef PLATFORM_LINUX
    LIBS += pthread
else ifdef PLATFORM_WINDOWS
    LIBS += ws2_32
endif
```

### 分岐順は Linux 優先

C/C++ 側の `PLATFORM_*` ルールと同様に、原則として `Linux -> Windows` の順で分岐します。

ただし、Windows 専用処理しかない場合は `ifdef PLATFORM_WINDOWS` 単独とします。

```makefile
ifdef PLATFORM_WINDOWS
    CFLAGS += /DMYLIB_EXPORTS
endif
```

## 禁止する書き方

以下の新規使用を禁止します。

- `ifeq ($(OS),Windows_NT)`
- `ifneq ($(OS),Windows_NT)`
- `$(filter Windows_NT,$(OS))`
- `uname -s`
- Windows 意味の素の `else`
- `ifeq ($(PLATFORM_WINDOWS),1)`
- `ifeq ($(PLATFORM_LINUX),1)`
- `ifeq ($(PLATFORM_UNKNOWN),1)`
- `$(filter 1,$(PLATFORM_WINDOWS))`
- `$(filter 1,$(PLATFORM_LINUX))`

既存コードを修正する場合も、新しい分岐追加時は `PLATFORM_*` に寄せてください。

## Make 関数内での書き方

`define` マクロや `$(if ...)` の中でも、OS 判定は `PLATFORM_*` を使います。

```makefile
$(if $(PLATFORM_LINUX),\
    $(1),)
```

```makefile
$(if $(PLATFORM_WINDOWS),\
    true,)
```

`$(filter Windows_NT,$(OS))` や `$(filter 1,$(PLATFORM_LINUX))` のような既存書式は使いません。

## 代表パターン

### Linux 専用ライブラリの追加

```makefile
ifdef PLATFORM_LINUX
    LIBS += pthread dl
endif
```

### Windows 専用 define の追加

```makefile
ifdef PLATFORM_WINDOWS
    CFLAGS   += /DMYLIB_EXPORTS
    CXXFLAGS += /DMYLIB_EXPORTS
endif
```

### 実行体拡張子の切り替え

```makefile
ifdef PLATFORM_WINDOWS
    TARGET := $(TARGET).exe
endif
```

### 関数形式でのサブディレクトリフィルタ

```makefile
define _os_filter_subdir
$(strip \
    $(if $(filter linux,$(call _dir_lc_name,$(1))),\
        $(if $(PLATFORM_LINUX),$(1),),\
    $(if $(filter windows,$(call _dir_lc_name,$(1))),\
        $(if $(PLATFORM_WINDOWS),$(1),),\
    $(1))))
endef
```

## 例外

`$(OS)` や `uname -s` を読んでよいのは、プラットフォームを一度だけ確定する `framework/makefw/makefiles/prepare.mk` に限定します。

利用側の makefile は、その結果として export された `PLATFORM_*` のみを参照してください。

## 関連する保守コマンド

C/C++ 側の `#if defined(PLATFORM_LINUX)` / `#elif defined(PLATFORM_WINDOWS)` のコメント整形と二択分岐の正規化には、次の保守コマンドを利用できます。

```bash
python framework/makefw/bin/fix_if_comments.py --dry-run <path>...
python framework/makefw/bin/fix_if_comments.py <path>...
```

詳細は [fix_if_comments.md](fix_if_comments.md) を参照してください。
