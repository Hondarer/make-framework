# .NET ライブラリ作成用 Makefile

include $(WORKSPACE_FOLDER)/makefw/makefiles/_hooks.mk

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

$(OUTPUT_ASSEMBLY): $(SOURCES) $(PROJECT_FILE)
	dotnet build -c $(CONFIG) -o $(OUTPUT_DIR)

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
	rm -f $(OUTPUT_DIR)/$(PROJECT_NAME).*
	rm -rf bin obj

.PHONY: restore
restore:
	dotnet restore

.PHONY: rebuild
rebuild: clean build
