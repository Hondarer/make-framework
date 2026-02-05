include $(WORKSPACE_FOLDER)/makefw/makefiles/_flags.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_hooks.mk

# 成果物のディレクトリ名
# 未指定の場合、カレントディレクトリ/bin に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/bin

# テストスクリプトのパス
TESTSH := $(WORKSPACE_FOLDER)/testfw/cmnd/exec_test_dotnet.sh

# プロジェクト名 (カレントディレクトリ名から取得)
PROJECT_NAME := $(notdir $(patsubst %/,%,$(CURDIR)))

# 実行体名の解決
ifeq ($(TARGET),)
    TARGET := $(PROJECT_NAME)
endif
ifeq ($(OS),Windows_NT)
    TARGET := $(TARGET).exe
endif

# make での更新判定用ビルドターゲット
OUTPUT_ASSEMBLY := $(OUTPUT_DIR)/$(PROJECT_NAME).dll

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

.PHONY: show-exepath
show-exepath:
	@echo $(OUTPUT_DIR)/$(TARGET)

.PHONY: test _test_main
test: _pre_test_hook _test_main _post_test_hook

# 実際のテスト処理
# Actual test process
_test_main: $(TESTSH) build
	@status=0; \
	export OUTPUT_DIR="$(OUTPUT_DIR)" && export CONFIG="$(CONFIG)" && "$(SHELL)" "$(TESTSH)" > >($(NKF)) 2> >($(NKF) >&2) || status=$$?; \
	exit $$status

.PHONY: run
run: build
	$(OUTPUT_DIR)/$(TARGET)

.PHONY: clean _clean_main
clean: _pre_clean_hook _clean_main _post_clean_hook

# 実際のクリーン処理
# Actual clean process
_clean_main:
	rm -f $(OUTPUT_DIR)/$(PROJECT_NAME).*
	rm -rf bin obj results
    # $(OUTPUT_DIR) に配下がなければ、$(OUTPUT_DIR) を削除する
    # Remove $(OUTPUT_DIR) if it's empty
	@if [ -d "$(OUTPUT_DIR)" ] && [ -z "$$(ls -A "$(OUTPUT_DIR)")" ]; then echo "rmdir \"$(OUTPUT_DIR)\""; rmdir "$(OUTPUT_DIR)"; fi

.PHONY: restore
restore:
	dotnet restore

.PHONY: rebuild
rebuild: clean build
