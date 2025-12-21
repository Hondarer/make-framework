# .NET 実行体作成用 Makefile

# 成果物のディレクトリ名
# 未指定の場合、カレントディレクトリ/bin に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/bin

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

.PHONY: build
build: $(OUTPUT_ASSEMBLY)

.PHONY: test
test: build
	dotnet test -c $(CONFIG) --no-build -o $(OUTPUT_DIR) --verbosity normal

.PHONY: run
run: build
	./$(TARGET)

.PHONY: clean
clean:
	rm -f $(OUTPUT_DIR)/$(TARGET)
	rm -rf bin obj results

.PHONY: restore
restore:
	dotnet restore

.PHONY: rebuild
rebuild: clean build
