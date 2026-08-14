# フック機能

## 概要

本ドキュメントは、`makefiles/_hooks.mk` および関連テンプレートが提供するフック機能を説明します。

### 目的

各ディレクトリの `makelocal.mk` で定義されたカスタム ターゲットを、ビルド プロセスの適切なタイミングで自動的に呼び出します。

### 対象フック

| フック名 | 説明 | 呼び出しタイミング |
|---------|------|------------------|
| `pre-build` | ビルド前処理 | `build` ターゲットの処理開始前 |
| `post-build` | ビルド後処理 | `build` ターゲットの処理完了後 |
| `pre-clean` | クリーン前処理 | `clean` ターゲットの処理開始前 |
| `post-clean` | クリーン後処理 | `clean` ターゲットの処理完了後 |
| `pre-test` | テスト前処理 | `test` ターゲットの処理開始前 |
| `post-test` | テスト後処理 | `test` ターゲットの処理完了後 |
| `install` | インストール処理 | `make install` 実行時 |

### ターゲット未指定時の動作

`make` をターゲット指定なしで実行した場合、`build` ターゲットに読み替えます。  
`make` (default) と `make build` の両方で同じフック処理が実行されます。

## 仕様

### ターゲット定義の検出

GNU Make には、ターゲットが定義されているかを直接検出する標準的な組み込み機能がありません。  
`$(shell ...)` を使用して、`makelocal.mk` ファイル内のターゲット定義を自動検出します。

```makefile
# ターゲット定義パターン: ^ターゲット名[空白]*:
# 実装では 1 回の awk 呼び出しで全フックを検出する (_hooks.mk)
HAS_PRE_BUILD := $(shell grep -qE '^pre-build[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
HAS_POST_BUILD := $(shell grep -qE '^post-build[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
HAS_INSTALL := $(shell grep -qE '^install[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
```

### フック呼び出しの条件分岐

テンプレート ファイル内で、検出結果に基づいて条件分岐します。

```makefile
# 自動検出された HAS_* 変数を使用
ifdef HAS_PRE_BUILD
_pre_build_hook: pre-build
else
_pre_build_hook:
	@:  # 無処理 (null command)
endif
```

### install ターゲットのデフォルト定義

`install` ターゲットは、検出されない場合に無処理のデフォルト ターゲットとして定義します。

```makefile
ifdef HAS_INSTALL
# makelocal.mk で定義された install ターゲットを使用
else
.PHONY: install
install:
	@echo "No install target defined in makelocal.mk"
endif
```

## 注意: PLATFORM 条件との組み合わせ

フック検出は `makelocal.mk` のテキストを走査し、`ifdef` は解釈しません。  
そのため、`pre-build:` などのターゲット定義行を `ifdef PLATFORM_LINUX` のような条件の内側に置くと、検出結果と実ターゲット定義が食い違い、`No rule to make target 'pre-clean'` などのエラーになります。

OS 専用処理が必要な場合は、ターゲット定義自体は条件の外に置き、レシピ内で分岐します。

```makefile
.PHONY: pre-clean
pre-clean:
ifdef PLATFORM_LINUX
	$(RM) "$(OUTPUT_DIR)/mylib.a"
endif
```

## 使用例

フック機能はテキスト走査による自動検出を採用しているため、ユーザーは `makelocal.mk` にターゲットを定義するだけで有効になります。

### 例 1: ビルド前にコード生成を行う

```makefile
# app/myapp/prod/libsrc/generated/makelocal.mk

.PHONY: pre-build
pre-build:
	@echo "Generating code..."
	python $(WORKSPACE_DIR)/tools/codegen.py
```

### 例 2: ビルド後にファイルをコピーする

```makefile
# app/myapp/prod/src/myapp/makelocal.mk

.PHONY: post-build
post-build:
	@echo "Copying configuration files..."
	cp -r $(WORKSPACE_DIR)/config/* $(OUTPUT_DIR)/
```

### 例 3: install ターゲットを定義する

```makefile
# app/myapp/prod/src/myapp/makelocal.mk

INSTALL_DIR ?= /usr/local/bin

.PHONY: install
install: $(OUTPUT_DIR)/$(TARGET)
	@echo "Installing to $(INSTALL_DIR)..."
	mkdir -p $(INSTALL_DIR)
	cp $(OUTPUT_DIR)/$(TARGET) $(INSTALL_DIR)/
```

### 例 4: 複数のフックを組み合わせる

```makefile
# app/myapp/prod/src/myapp/makelocal.mk

.PHONY: pre-build post-build install

pre-build:
	@echo "Checking dependencies..."
	./check_deps.sh

post-build:
	@echo "Running post-build verification..."
	./verify_build.sh

install: $(OUTPUT_DIR)/$(TARGET)
	@echo "Installing..."
	cp $(OUTPUT_DIR)/$(TARGET) /usr/local/bin/
```

### 例 5: エラーの無視

フック ターゲット内でエラーが発生した場合、ビルド全体が停止します。エラーを無視したい場合は次のようにします。

```makefile
.PHONY: post-build
post-build:
	-some_command_that_may_fail
	another_command || true
```
