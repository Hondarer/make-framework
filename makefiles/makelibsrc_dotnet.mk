# .NET ライブラリ作成用 makefile

include $(WORKSPACE_FOLDER)/makefw/makefiles/_hooks.mk

# カレントディレクトリ配下の絶対パスを相対パスに変換する (make の出力を読みやすくする)
# Convert absolute paths under $(CURDIR) to relative paths (for readable make output)
_relpath = $(patsubst $(CURDIR)/%,%,$(1))

# 成果物のディレクトリ名
# 未指定の場合、カレントディレクトリ/lib に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/lib

# プロジェクト名 (カレントディレクトリ名から取得)
PROJECT_NAME := $(notdir $(patsubst %/,%,$(CURDIR)))

# ライブラリ名の解決
ifeq ($(TARGET),)
    TARGET := $(PROJECT_NAME).dll
endif

# make での更新判定用ビルドターゲット
OUTPUT_ASSEMBLY := $(OUTPUT_DIR)/$(TARGET)

# ソースファイルの検出 (obj/bin ディレクトリを除外)
SOURCES := $(shell find . -name "*.cs" -not -path "*/obj/*" -not -path "*/bin/*" 2>/dev/null)
PROJECT_FILE := $(wildcard *.csproj)

.DEFAULT_GOAL := default

.PHONY: default
default: build

# dotnet build ラッパースクリプト (warning/error のみ着色)
# dotnet build wrapper script (colorizes only warnings/errors)
DOTNET_BUILD := $(WORKSPACE_FOLDER)/makefw/cmnd/dotnet_build.sh

$(OUTPUT_ASSEMBLY): $(SOURCES) $(PROJECT_FILE)
    # dotnet_build.sh 側にてビルドコマンドは echo される
	@"$(DOTNET_BUILD)" -c $(CONFIG) -o $(OUTPUT_DIR)

.PHONY: build _build_main
build: _pre_build_hook _build_main _post_build_hook

# 実際のビルド処理
# Actual build process
_build_main: $(OUTPUT_ASSEMBLY)

.PHONY: clean _clean_main
clean: _pre_clean_hook _clean_main _post_clean_hook

# 実際のクリーン処理
# Actual clean process
_clean_main:
	rm -rf $(call _relpath,$(OUTPUT_DIR)/$(PROJECT_NAME).*) bin obj
    # $(OUTPUT_DIR) に配下がなければ、$(OUTPUT_DIR) を削除する (rmdir は非空なら失敗するので直接試行)
    # Remove $(OUTPUT_DIR) if it's empty (rmdir fails on non-empty, so just try it)
	@rmdir "$(call _relpath,$(OUTPUT_DIR))" 2>/dev/null && echo "rmdir \"$(call _relpath,$(OUTPUT_DIR))\"" || true

.PHONY: restore
restore:
	dotnet restore

.PHONY: rebuild
rebuild: clean build
