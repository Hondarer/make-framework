include $(WORKSPACE_DIR)/framework/makefw/makefiles/_flags.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_hooks.mk

# カレント ディレクトリ配下の絶対パスを相対パスに変換する (make の出力を読みやすくする)
# Convert absolute paths under $(CURDIR) to relative paths (for readable make output)
_relpath = $(patsubst $(CURDIR)/%,%,$(1))

# 成果物のディレクトリ名
# 未指定の場合、カレント ディレクトリ/bin に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/bin

# テスト スクリプトのパス
ifneq ($(strip $(TESTFW_HOME)),)
    TESTSH := $(TESTFW_HOME)/bin/exec_test_dotnet.sh
endif

ifneq (,$(findstring /test/,$(CURDIR)))
    MAKEFW_TEST_LEAF := 1
endif

# プロジェクト名 (カレント ディレクトリ名から取得)
PROJECT_NAME := $(notdir $(patsubst %/,%,$(CURDIR)))

# 実行体名の解決
ifeq ($(TARGET),)
    TARGET := $(PROJECT_NAME)
endif
ifdef PLATFORM_WINDOWS
    TARGET := $(TARGET).exe
endif

# make での更新判定用ビルド ターゲット
OUTPUT_ASSEMBLY := $(OUTPUT_DIR)/$(PROJECT_NAME).dll

# ソース ファイルの検出 (obj/bin ディレクトリを除外)
SOURCES := $(shell find . -name "*.cs" -not -path "*/obj/*" -not -path "*/bin/*" 2>/dev/null)
PROJECT_FILE := $(wildcard *.csproj)

.DEFAULT_GOAL := default

.PHONY: default
default: build

# dotnet build ラッパースクリプト (warning/error のみ着色)
# dotnet build wrapper script (colorizes only warnings/errors)
DOTNET_BUILD := $(WORKSPACE_DIR)/framework/makefw/bin/dotnet_build.sh

$(OUTPUT_ASSEMBLY): $(SOURCES) $(PROJECT_FILE)
    # dotnet_build.sh 側にてビルド コマンドは echo される
	@WARN_FILE="$(OUTPUT_DIR)/$(TARGET).warn" DOTNET="$(DOTNET)" "$(SHELL)" "$(DOTNET_BUILD)" -m:$(MAKEFW_MSBUILD_JOBS) -c $(CONFIG) -o $(OUTPUT_DIR)

.PHONY: build _build_main
build: _pre_build_hook _build_main _post_build_hook

# 実際のビルド処理
# Actual build process
_build_main: $(OUTPUT_ASSEMBLY)

.PHONY: show-exepath
show-exepath:
	@echo $(OUTPUT_DIR)/$(TARGET)

# test は makemain.mk の 2 フェーズ エントリが所有する。
# Phase 1 で .NET ビルド、Phase 2 で dotnet test を実行する。
# 'test' is owned by the 2-phase entry in makemain.mk: build in Phase 1, run in Phase 2.
.PHONY: _test_build _test_run _test_main

# ビルド フェーズ: .NET ビルドのみ
# Build phase: .NET build only
_test_build: build

# 実行フェーズ: テスト実行のみ (ビルドは Phase 1 で実施済み)
# Run phase: run tests only (the build is already done in Phase 1)
_test_run: _pre_test_hook _test_main _post_test_hook

# 実際のテスト処理
# Actual test process
_test_main: $(TESTSH)
	@if [ -z "$(TESTSH)" ]; then \
		echo "$(TESTFW_HOME_ERROR)"; \
		exit 1; \
	fi; \
	status=0; \
	export OUTPUT_DIR="$(OUTPUT_DIR)" && export CONFIG="$(CONFIG)" && "$(SHELL)" "$(TESTSH)" > >($(ICONV)) 2> >($(ICONV) >&2) || status=$$?; \
	exit $$status

.PHONY: run
run: build
	$(OUTPUT_DIR)/$(TARGET)

.PHONY: clean _clean_main
clean: _pre_clean_hook _clean_main _post_clean_hook

# 実際のクリーン処理
# Actual clean process
_clean_main:
	rm -rf $(call _relpath,$(OUTPUT_DIR)/$(PROJECT_NAME).*) $(call _relpath,$(OUTPUT_DIR)/$(TARGET).warn) bin obj results
    # $(OUTPUT_DIR) に配下がなければ、$(OUTPUT_DIR) を削除する (rmdir は非空なら失敗するので直接試行)
    # Remove $(OUTPUT_DIR) if it's empty (rmdir fails on non-empty, so just try it)
	@rmdir "$(call _relpath,$(OUTPUT_DIR))" 2>/dev/null && echo "rmdir \"$(call _relpath,$(OUTPUT_DIR))\"" || true

.PHONY: restore
restore:
	"$(DOTNET)" restore

.PHONY: rebuild
rebuild: clean build
