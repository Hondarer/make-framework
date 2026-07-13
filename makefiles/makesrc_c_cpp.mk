include $(WORKSPACE_DIR)/framework/makefw/makefiles/_collect_srcs.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_flags.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_should_skip.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_hooks.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_msvc_compile.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_resource_compile.mk

# テスト ライブラリの設定
# Set test libraries
# LINK_TEST が 1 の場合にのみ設定する
ifneq ($(strip $(TESTFW_HOME)),)
    TESTFW_INCLUDE_OVERRIDE := -I$(TESTFW_HOME)/include_override
    TESTSH := $(TESTFW_HOME)/bin/exec_test_c_cpp.sh
endif

ifneq (,$(findstring /test/,$(CURDIR)))
    ifndef NO_LINK
        MAKEFW_TEST_LEAF := 1
    endif
endif

# $(MYAPP_DIR)/test/include_override が存在する場合だけ、テスト対象用優先 include override パスとして使用する
ifneq ($(filter $(WORKSPACE_DIR)/app/%,$(CURDIR)),)
    ifneq ($(wildcard $(MYAPP_DIR)/test/include_override),)
        MYAPP_INCLUDE_OVERRIDE := -I$(MYAPP_DIR)/test/include_override
    endif
endif

ifeq ($(LINK_TEST), 1)
    ifeq ($(strip $(TESTFW_HOME)),)
        $(error $(TESTFW_HOME_ERROR))
    endif
    ifeq ($(wildcard $(TESTFW_HOME)),)
        $(error $(TESTFW_HOME_ERROR))
    endif

    ifdef PLATFORM_LINUX
        LIBS += pthread gcov dl
        # ステップ実行/カバレッジに支障となるオプションを除去
        #   -flto: リンク時最適化 (GCC の LTO)
        LDFLAGS := $(filter-out -flto,$(LDFLAGS))
        # TARGET_ARCH を使用してプラットフォーム固有のパスを指定
        # Use TARGET_ARCH for platform-specific path (e.g., linux_el8_x64)
        LIBSDIR += $(TESTFW_HOME)/gtest/lib/$(TARGET_ARCH)
    else ifdef PLATFORM_WINDOWS
        # ステップ実行/カバレッジに支障となるオプションを除去
        #   /LTCG: リンク時コード生成 (プログラム全体最適化)
        LDFLAGS := $(filter-out /LTCG,$(LDFLAGS))
        # MSVC_CRT_SUBDIR は prepare.mk で CONFIG と MSVC_CRT から計算される
        # MSVC_CRT_SUBDIR is calculated in prepare.mk from CONFIG and MSVC_CRT
        # TARGET_ARCH を使用してプラットフォーム固有のパスを指定
        # Use TARGET_ARCH for platform-specific path (e.g., windows_x64/md)
        LIBSDIR += $(TESTFW_HOME)/gtest/lib/$(TARGET_ARCH)/$(MSVC_CRT_SUBDIR)
    endif

    ifneq ($(NO_GTEST_MAIN), 1)
        # gtest_main 有効
        ifeq ($(USE_WRAP_MAIN), 1)
            # gtest_main 有効 && wrap_main 有効
            LIBS += gtest_wrapmain
        else
            # testfw_gtest_main 有効 && wrap_main 無効
            # gtest_main は利用しない。(Windows 環境のコンソール初期化を testfw で行うため)
            LIBS += testfw_gtest_main
        endif
    endif

    LIBS += test_com gtest gmock
endif

# LIBS で要求されたライブラリの実体パスのみを解決する (.a/.so/.lib)
# LINK_TEST ブロック後なので gtest のパスも含まれる。
# Resolve LIBSFILES from only the libraries requested by LIBS (.a/.so/.lib).
# (After LINK_TEST block so gtest path is included.)
ifdef PLATFORM_LINUX
    # .a を優先し、なければ .so にフォールバック (.a → .so はリンカーの探索順と一致)
    # Prefer .a; fall back to .so if not found (mirrors linker search order)
    LIBSFILES := $(foreach lib,$(LIBS),\
        $(or \
            $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).a))),\
            $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).so)))))
else ifdef PLATFORM_WINDOWS
    # まず lib なしで検索、なければ lib 付きで再検索
    # (advapi32 等のフレームワーク ライブラリは lib が付かないための対策)
    # First search without lib prefix, then retry with lib prefix
    # (because framework libraries like advapi32 don't have lib prefix)
    LIBSFILES := $(foreach lib,$(LIBS),\
        $(or \
            $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/$(lib).lib))),\
            $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).lib)))))
endif

define _MAKEFW_OBJLIST_LINUX
objs_file="$(OBJDIR)/objs_$$.lst"; \
bash "$(MAKEFW_HOME)/bin/filter_existing_source_objs.sh" linux all > "$$objs_file"; \
if [ ! -f "$$objs_file" ]; then : > "$$objs_file"; fi; \
trap 'rm -f "$$objs_file" "$$rsp_file"' EXIT; \
rebuild=0; \
if [ ! -f "$@" ]; then \
    rebuild=1; \
else \
    while IFS= read -r obj; do \
        [ -n "$$obj" ] || continue; \
        if [ "$$obj" -nt "$@" ]; then rebuild=1; break; fi; \
    done < "$$objs_file"; \
fi
endef

define _MAKEFW_OBJLIST_WINDOWS
objs_file="$(OBJDIR)/objs_$$.lst"; \
bash "$(MAKEFW_HOME)/bin/filter_existing_source_objs.sh" windows all "$(MSVC_CRT_SUBDIR)" > "$$objs_file"; \
if [ ! -f "$$objs_file" ]; then : > "$$objs_file"; fi; \
trap 'rm -f "$$objs_file" "$$rsp_file"' EXIT; \
rebuild=0; \
if [ ! -f "$@" ]; then \
    rebuild=1; \
else \
    while IFS= read -r obj; do \
        [ -n "$$obj" ] || continue; \
        if [ "$$obj" -nt "$@" ]; then rebuild=1; break; fi; \
    done < "$$objs_file"; \
fi
endef

#$(info NO_GTEST_MAIN: $(NO_GTEST_MAIN))
#$(info USE_WRAP_MAIN: $(USE_WRAP_MAIN))
#$(info LIBS: $(LIBS))

GCOVDIR := gcov
LCOVDIR := lcov
COVERAGEDIR := coverage

# DEFINES を -D として追加する
CFLAGS   += $(addprefix -D,$(DEFINES))
CXXFLAGS += $(addprefix -D,$(DEFINES))

# NOTE: テスト対象の場合は、CFLAGS の後、通常の include の前に include_override を追加する
#       CFLAGS に追加した include パスは、include_override より前に評価されるので
#       個別のテストでの include 注入に対応できる
# NOTE: For test targets, add include_override after CFLAGS but before normal includes, so that test-specific includes can override

# テスト対象
# For test targets
CFLAGS_TEST := $(CFLAGS) $(TESTFW_INCLUDE_OVERRIDE) $(MYAPP_INCLUDE_OVERRIDE) $(addprefix -I, $(INCDIR))
CXXFLAGS_TEST := $(CXXFLAGS) $(TESTFW_INCLUDE_OVERRIDE) $(MYAPP_INCLUDE_OVERRIDE) $(addprefix -I, $(INCDIR))
ifdef PLATFORM_LINUX
    # ステップ実行/カバレッジに支障となるオプションを除去
    #   -O1, -O2, -O3, -Os, -Ofast: 最適化レベル
    #   -finline-functions: インライン展開
    #   -fomit-frame-pointer: フレーム ポインター省略
    CFLAGS_TEST := $(filter-out -O1 -O2 -O3 -Os -Ofast -finline-functions -fomit-frame-pointer,$(CFLAGS_TEST))
    CXXFLAGS_TEST := $(filter-out -O1 -O2 -O3 -Os -Ofast -finline-functions -fomit-frame-pointer,$(CXXFLAGS_TEST))
    # ステップ実行/カバレッジに必要なオプションを追加 (未定義の場合のみ)
    #   -O0: 最適化無効
    #   -g: デバッグ情報生成
    ifeq ($(findstring -O0,$(CFLAGS_TEST)),)
        CFLAGS_TEST += -O0
    endif
    ifeq ($(findstring -g,$(CFLAGS_TEST)),)
        CFLAGS_TEST += -g
    endif
    ifeq ($(findstring -O0,$(CXXFLAGS_TEST)),)
        CXXFLAGS_TEST += -O0
    endif
    ifeq ($(findstring -g,$(CXXFLAGS_TEST)),)
        CXXFLAGS_TEST += -g
    endif
    # カバレッジ計測用オプション
    #   -coverage: gcov/lcov 用のインストルメンテーション
    CFLAGS_TEST += -coverage
    CXXFLAGS_TEST += -coverage
else ifdef PLATFORM_WINDOWS
    # ステップ実行/カバレッジに支障となるオプションを除去
    #   /O1, /O2: 最適化 (コード再配置・省略が発生)
    #   /Ob1, /Ob2: インライン展開 (関数呼び出しが消える)
    #   /Oi: 組み込み関数 (標準関数がインライン化)
    #   /Oy: フレーム ポインター省略 (スタック トレース不正確)
    #   /GL: リンク時最適化 (LTCG)
    #   /Gw: グローバル データ最適化
    CFLAGS_TEST := $(filter-out /O1 /O2 /Ob1 /Ob2 /Oi /Oy /GL /Gw,$(CFLAGS_TEST))
    CXXFLAGS_TEST := $(filter-out /O1 /O2 /Ob1 /Ob2 /Oi /Oy /GL /Gw,$(CXXFLAGS_TEST))
    # ステップ実行/カバレッジに必要なオプションを追加 (未定義の場合のみ)
    #   /Od: 最適化無効 (コードが元のまま保持)
    #   /Ob0: インライン展開無効 (全関数呼び出しを保持)
    #   /Zi: デバッグ情報生成 (PDB ファイル)
    #   /EHsc: C++ 例外処理
    ifeq ($(findstring /Od,$(CFLAGS_TEST)),)
        CFLAGS_TEST += /Od
    endif
    ifeq ($(findstring /Ob0,$(CFLAGS_TEST)),)
        CFLAGS_TEST += /Ob0
    endif
    ifeq ($(findstring /Zi,$(CFLAGS_TEST)),)
        CFLAGS_TEST += /Zi
    endif
    ifeq ($(findstring /EHsc,$(CFLAGS_TEST)),)
        CFLAGS_TEST += /EHsc
    endif
    ifeq ($(findstring /Od,$(CXXFLAGS_TEST)),)
        CXXFLAGS_TEST += /Od
    endif
    ifeq ($(findstring /Ob0,$(CXXFLAGS_TEST)),)
        CXXFLAGS_TEST += /Ob0
    endif
    ifeq ($(findstring /Zi,$(CXXFLAGS_TEST)),)
        CXXFLAGS_TEST += /Zi
    endif
    ifeq ($(findstring /EHsc,$(CXXFLAGS_TEST)),)
        CXXFLAGS_TEST += /EHsc
    endif
endif

# テスト対象以外
# For non-test targets
CFLAGS   += $(addprefix -I, $(INCDIR))
CXXFLAGS += $(addprefix -I, $(INCDIR))

# リンク ライブラリ ファイル名の解決
ifdef PLATFORM_LINUX
    LIBS := $(addprefix -l, $(LIBS))
else ifdef PLATFORM_WINDOWS
    # まず lib なしでファイルを探索し、無い場合は lib を付けて再探索
    # (advapi32 等のフレームワーク ライブラリは lib が付かないための対策)
    # First search without lib prefix, then retry with lib prefix
    # (because framework libraries like advapi32 don't have lib prefix)
    LIBS := $(foreach lib,$(LIBS),\
        $(if $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/$(lib).lib))),\
            $(lib).lib,\
            $(if $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).lib))),\
                lib$(lib).lib,\
                $(lib).lib)))
endif

# リンク ライブラリ フォルダー名の解決
ifdef PLATFORM_LINUX
    LDFLAGS := $(LDFLAGS) $(addprefix -L, $(LIBSDIR))
else ifdef PLATFORM_WINDOWS
    LDFLAGS := $(LDFLAGS) $(addprefix /LIBPATH:, $(LIBSDIR))
endif

# OBJS
# 直下の obj ディレクトリのオブジェクト ファイル
# Object files in the current obj directory
OBJS := $(filter-out $(OBJDIR)/%.inject.o, \
	$(sort $(addprefix $(OBJDIR)/, \
	$(notdir $(patsubst %.c, %.o, $(patsubst %.cc, %.o, $(patsubst %.cpp, %.o, $(SRCS_C) $(SRCS_CPP))))))))
# DEPS
DEPS := $(patsubst %.o, %.d, $(OBJS))
ifdef PLATFORM_WINDOWS
    # Windows の場合は .o を .obj に置換
    OBJS := $(patsubst %.o, %.obj, $(OBJS))
endif

# サブディレクトリの obj ディレクトリを再帰的に検索して、対応するソースがある
# オブジェクト ファイルだけを収集する。
# Recursively collect object files from subdirectories' obj directories only when
# the matching source file still exists.
ifdef PLATFORM_LINUX
    # Linux: .o ファイルを検索
    SUBDIR_OBJS := $(shell bash "$(MAKEFW_HOME)/bin/filter_existing_source_objs.sh" linux subdirs)
endif
OBJS += $(SUBDIR_OBJS)

MAKEFW_ARTIFACT_ROOT := $(shell \
	dir="$(CURDIR)"; \
	while [ -n "$$dir" ] && [ "$$dir" != "/" ]; do \
		parent="$${dir%/*}"; \
		if [ "$$parent" = "$$dir" ]; then break; fi; \
		if [ -f "$$parent/makechild.mk" ] && grep -Eq '^[[:space:]]*NO_LINK[[:space:]]*[?:+]?=' "$$parent/makechild.mk"; then \
			printf '%s\n' "$$parent"; \
			exit 0; \
		fi; \
		dir="$$parent"; \
	done; \
	printf '%s\n' "$(CURDIR)" | sed 's@^\(.*\/src\/[^/]*\).*@\1@' \
)
MAKEFW_ARTIFACT_DEPS := $(if $(MAKEFW_ARTIFACT_ONLY),_makefw_artifact_recheck,$(SUBDIRS))
MAKEFW_ARTIFACT_OBJS := $(if $(MAKEFW_ARTIFACT_ONLY),,$(OBJS))
MAKEFW_ARTIFACT_MSVC_COMPILE := $(if $(MAKEFW_ARTIFACT_ONLY),,_msvc_compile)
MAKEFW_SHOULD_BUILD_PARENT_ARTIFACT := $(if $(filter $(CURDIR),$(MAKEFW_REQUEST_ROOT)),$(if $(filter-out $(MAKEFW_ARTIFACT_ROOT),$(CURDIR)),$(if $(filter command\ line,$(origin NO_LINK)),,1),),)

.PHONY: _makefw_artifact_recheck _makefw_parent_artifact
_makefw_artifact_recheck:
	@:

_makefw_parent_artifact:
	$(MAKE) -C "$(MAKEFW_ARTIFACT_ROOT)" MAKEFW_ARTIFACT_ONLY=1 _build_main

# 成果物のディレクトリ名
# 未指定の場合、カレント ディレクトリ/bin に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/bin

# ディレクトリ名を実行体名にする (Make 関数の notdir でプロセス生成を削減)
# Use directory name as executable name if TARGET is not specified (use Make's notdir to avoid process)
ifeq ($(TARGET),)
    TARGET := $(notdir $(CURDIR))
endif
ifdef PLATFORM_WINDOWS
    TARGET := $(TARGET).exe
endif

# デフォルト ターゲットの設定
# Default target setting
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
    .DEFAULT_GOAL := skip_build
else
    ifndef NO_LINK
        .DEFAULT_GOAL := default
    else
        .DEFAULT_GOAL := default
    endif
endif

.PHONY: skip_build
skip_build:
	@echo "Build skipped (SKIP_BUILD=$(SKIP_BUILD))"

# default および build ターゲットの定義
# makemain.mk で default: $(SUBDIRS) および build: $(SUBDIRS) が定義されるため、
# ここでは実際のビルド ターゲットへの依存関係のみを追加
# Define default and build targets
.PHONY: default
default: build

.PHONY: build _build_impl _build_main
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
build: skip_build
else ifeq ($(MAKEFW_IS_LEAF),1)
build:
	+$(call _MAKEFW_LEAF_PARALLEL_RECIPE,build,_build_impl)
else
build: _build_impl
endif

_build_impl: _pre_build_hook _build_main _post_build_hook

# 実際のビルド処理
# Actual build process
# Windows では _msvc_compile が完了してから _build_main を実行
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
_build_main: _msvc_compile
	@:
else
    ifndef NO_LINK
_build_main: $(MAKEFW_ARTIFACT_MSVC_COMPILE) $(OUTPUT_DIR)/$(TARGET)
    else
_build_main: $(if $(PLATFORM_WINDOWS),_msvc_compile,$(OBJS)) $(LIBSFILES) $(if $(MAKEFW_SHOULD_BUILD_PARENT_ARTIFACT),_makefw_parent_artifact)
    endif
endif

# .gitignore は CP_SRCS / LINK_SRCS の取り込みより前に原子的に再生成する。
# 既存 .gitignore を読まず、ターゲット一覧から直接生成して mv で置換することで、
# 並列ビルドや中断時の競合・破損を防ぎ、かつファイル配置前に ignore を反映できる。
# Atomically regenerate .gitignore before placing CP/LINK targets:
# write to a temp file and rename, so concurrent writers and partial writes are avoided
# and the ignore is in place before any imported file appears in the directory.
ifneq ($(strip $(notdir $(CP_SRCS) $(LINK_SRCS))),)
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
else
build: $(OBJDIR)/.gitignore_stamp
endif
# スタンプは makepart.mk / makefile 群が更新されたときに再評価する。
# CP_SRCS / LINK_SRCS のリストは makefile 側で静的に決まるため、
# MAKEFILE_LIST を依存に置けばリスト変化を捕捉できる。
$(OBJDIR)/.gitignore_stamp: $(MAKEFILE_LIST) | $(OBJDIR)
	@tmp=$$(mktemp .gitignore.tmp.XXXXXX); \
	printf '%s\n' $(addprefix /,$(sort $(notdir $(CP_SRCS) $(LINK_SRCS)))) > "$$tmp" \
		&& mv "$$tmp" .gitignore \
		|| { rc=$$?; rm -f "$$tmp"; exit $$rc; }
	@touch $@
# CP / LINK 対象ファイルの配置は .gitignore_stamp の完了後に行う (order-only)。
# Place imported files only after .gitignore_stamp is up to date (order-only prerequisite).
$(notdir $(CP_SRCS) $(LINK_SRCS)): | $(OBJDIR)/.gitignore_stamp
endif

ifndef NO_LINK
    # 実行体の生成
    # Build the executable
    ifdef PLATFORM_LINUX
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_OBJS) $(LINK_INPUTS) $(LIBSFILES) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_LINUX); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(LINK_INPUTS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(LINK_INPUTS) $(LIBSFILES); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					all_objs=$$(tr '\n' ' ' < "$$objs_file" | xargs); \
					extra_objs="$(strip $(MAKEFW_EXTRA_OBJS))"; \
					if [ -n "$$extra_objs" ]; then all_objs="$$all_objs $$extra_objs"; fi; \
					printf '%s\n' "$(strip $(LD) $(LDFLAGS) -o $(call _relpath,$@) $$all_objs $(LINK_INPUTS) $(LIBS))"; \
					set -o pipefail; LANG=$(FILES_LANG) $(LD) $(LDFLAGS) -o $@ $$all_objs $(LINK_INPUTS) $(LIBS) -fdiagnostics-color=always 2>&1 | $(ICONV) | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
    else ifdef PLATFORM_WINDOWS
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_MSVC_COMPILE) $(LINK_INPUTS) $(LIBSFILES) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_WINDOWS); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(LINK_INPUTS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(LINK_INPUTS) $(LIBSFILES); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					rsp_file="$(OBJDIR)/link_$$.rsp"; \
					cp "$$objs_file" "$$rsp_file"; \
					printf '%s\n' $(MAKEFW_EXTRA_OBJS) >> "$$rsp_file"; \
					printf '%s\n' $(LINK_INPUTS) >> "$$rsp_file"; \
					echo "$(strip $(basename $(notdir $(LD))) $(LDFLAGS) /PDB:$(call _relpath,$(patsubst %.exe,%.pdb,$@)) /ILK:$(OBJDIR)/$(patsubst %.exe,%.ilk,$@) /OUT:$(call _relpath,$@) @$(call _relpath,$(OBJDIR))/link_$$.rsp $(LIBS))" | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_format_cmd.ps1; \
					set -o pipefail; MSYS_NO_PATHCONV=1 "$(LD)" $(LDFLAGS) /PDB:$(patsubst %.exe,%.pdb,$@) /ILK:$(OBJDIR)/$(patsubst %.exe,%.ilk,$@) /OUT:$@ @$$rsp_file $(LIBS) 2>&1 | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_link_filter.ps1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
    endif
else
# コンパイルのみ
# Compile only
$(OBJS): $(LIBSFILES)
endif

.PHONY: show-exepath
show-exepath:
	@echo $(OUTPUT_DIR)/$(TARGET)

# コンパイル時の依存関係に $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) を定義しているのは
# ヘッダー類などを引き込んでおく必要がある場合に、先に処理を行っておきたいため
# We define $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) as compile-time dependencies to ensure all headers are processed first

# コンパイル ルールのテンプレート定義
# Compile rule template definition
# 引数: $(1)=拡張子 (c/cc/cpp), $(2)=コンパイラ変数名 (CC/CXX), $(3)=フラグ変数名 (CFLAGS/CXXFLAGS)
# Windows のコンパイルは _msvc_compile で処理するため、パターン ルールは Linux のみ定義する
define compile_rule_template
ifdef PLATFORM_LINUX
$$(OBJDIR)/%.o: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR)
		@set -o pipefail; if echo $$(TEST_SRCS) | grep -q $$(notdir $$<); then \
			echo $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -D_IN_TEST_SRC -c -o $$@ $$<; \
			LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -D_IN_TEST_SRC -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(ICONV) | $$(CAPTURE_WARNINGS) $$<.warn; \
		else \
			echo $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$<; \
			LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(ICONV) | $$(CAPTURE_WARNINGS) $$<.warn; \
		fi
endif
endef

# C ソース ファイルのコンパイル
# Compile C source files
$(eval $(call compile_rule_template,c,CC,CFLAGS))

# C++ ソース ファイルのコンパイル (*.cc)
# Compile C++ source files (*.cc)
$(eval $(call compile_rule_template,cc,CXX,CXXFLAGS))

# C++ ソース ファイルのコンパイル (*.cpp)
# Compile C++ source files (*.cpp)
$(eval $(call compile_rule_template,cpp,CXX,CXXFLAGS))

# シンボリック リンク対象のソース ファイルをシンボリック リンク
# Create symbolic links for LINK_SRCS
define generate_link_src_rule
$(1):
	ln -sf $(2) $(1)
endef

# ファイルごとの依存関係を動的に定義
# ただし、from, to が同じになる場合 (一般的には makefile の定義ミス) はスキップ
# Dynamically define file-by-file dependencies
$(foreach link_src,$(LINK_SRCS), \
    $(if \
        $(filter-out $(notdir $(link_src)),$(link_src)), \
        $(eval $(call generate_link_src_rule,$(notdir $(link_src)),$(link_src))) \
    ) \
)

# コピー対象のソース ファイルをコピーして
# 1. フィルター処理をする
# 2. inject 処理をする
# Copy target source files, then apply filter processing and inject
define generate_cp_src_rule
$(1): $(2) $(wildcard $(1).filter.sh) $(wildcard $(basename $(1)).inject$(suffix $(1))) $(filter $(1).filter.sh,$(notdir $(LINK_SRCS))) $(filter $(basename $(1)).inject$(suffix $(1)),$(notdir $(LINK_SRCS)))
	@if [ -f "$(1).filter.sh" ]; then \
		echo "cat $(2) | sh $(1).filter.sh > $(1)"; \
		cat $(2) | sh -e $(1).filter.sh > $(1) && \
		diff $(2) $(1) | $(ICONV) && set $?=0; \
	else \
		echo "cp -p $(2) $(1)"; \
		cp -p $(2) $(1); \
	fi
	@if [ -f "$(basename $(1)).inject$(suffix $(1))" ]; then \
		if [ "$$(tail -c 1 $(1) | od -An -tx1)" != " 0a" ]; then \
			echo "echo \"\" >> $(1)"; \
			echo "" >> $(1); \
		fi; \
		echo "echo \"\" >> $(1)"; \
		echo "" >> $(1); \
		echo "echo \"/* Inject from test framework */\" >> $(1)"; \
		echo "/* Inject from test framework */" >> $(1); \
		echo "echo \"#ifdef _IN_TEST_SRC\" >> $(1)"; \
		echo "#ifdef _IN_TEST_SRC" >> $(1); \
		echo "echo \"#include \"$(basename $(1)).inject$(suffix $(1))\"\" >> $(1)"; \
		echo "#include \"$(basename $(1)).inject$(suffix $(1))\"" >> $(1); \
		echo "echo \"#endif // _IN_TEST_SRC\" >> $(1)"; \
		echo "#endif // _IN_TEST_SRC" >> $(1); \
	fi
endef

# ファイルごとの依存関係を動的に定義
# Dynamically define file-by-file dependencies
$(foreach cp_src,$(CP_SRCS),$(eval $(call generate_cp_src_rule,$(notdir $(cp_src)),$(cp_src))))

# The empty rule is required to handle the case where the dependency file is deleted.
$(DEPS):

include $(wildcard $(DEPS))

$(OUTPUT_DIR):
	mkdir -p $(call _relpath,$@)

$(OBJDIR):
	mkdir -p $@

# 削除対象の定義
# Define files/directories to clean
# カレント ディレクトリ配下の絶対パスを相対パスに変換する (make の出力を読みやすくする)
# Convert absolute paths under $(CURDIR) to relative paths (for readable make output)
_relpath = $(patsubst $(CURDIR)/%,%,$(1))

# clean 時に .gitignore へ反映する対象:
# TEST_SRCS/ADD_SRCS のうち、カレント ディレクトリ外のソース
ifneq (,$(filter clean _clean_main rebuild,$(MAKECMDGOALS)))
MAKEFW_CLEAN_GITIGNORE_SRCS := $(strip $(sort $(shell \
	cur=$$(cd "$(CURDIR)" 2>/dev/null && pwd); \
	for src in $(TEST_SRCS) $(ADD_SRCS); do \
		src_dir=$$(dirname "$$src"); \
		abs_dir=$$(cd "$$src_dir" 2>/dev/null && pwd); \
		if [ -n "$$abs_dir" ] && [ "$$abs_dir" != "$$cur" ]; then \
			basename "$$src"; \
		fi; \
	done)))
else
MAKEFW_CLEAN_GITIGNORE_SRCS :=
endif

MAKEFW_CLEAN_IMPORTED_SRCS := $(strip $(sort $(notdir $(CP_SRCS) $(LINK_SRCS)) $(MAKEFW_CLEAN_GITIGNORE_SRCS)))

CLEAN_COMMON := $(strip $(call _relpath,$(OUTPUT_DIR)/$(TARGET)) $(call _relpath,$(OUTPUT_DIR)/$(TARGET).warn) $(OBJDIR) $(GCOVDIR) $(COVERAGEDIR) $(MAKEFW_CLEAN_IMPORTED_SRCS) results)
ifdef PLATFORM_LINUX
    CLEAN_OS := core $(LCOVDIR)
else ifdef PLATFORM_WINDOWS
    CLEAN_OS := $(call _relpath,$(patsubst %.exe,%.pdb,$(OUTPUT_DIR)/$(TARGET)))
endif
ifeq ($(strip $(MAKEFW_CLEAN_GITIGNORE_SRCS)),)
    CLEAN_COMMON += .gitignore
endif

.PHONY: clean _clean_main
clean: _pre_clean_hook _clean_main _post_clean_hook

# 実際のクリーン処理
# Actual clean process
_clean_main:
    # .gitignore の再生成 (コミット差分が出ないように)
    # Regenerate .gitignore (avoid commit diffs)
    # 一意な一時ファイルを使って .gitignore を置換する
    # Replace .gitignore through a unique temporary file
    ifneq ($(strip $(MAKEFW_CLEAN_GITIGNORE_SRCS)),)
		@tmp=$$(mktemp .gitignore.tmp.XXXXXX); \
		printf '%s\n' $(addprefix /,$(MAKEFW_CLEAN_GITIGNORE_SRCS)) > "$$tmp" && mv "$$tmp" .gitignore || { rc=$$?; rm -f "$$tmp"; exit $$rc; }
    endif
	-rm -rf $(strip $(CLEAN_COMMON) $(CLEAN_OS)) *.warn
    # 空ディレクトリを削除する。obj は全 CRT サブディレクトリを含めて削除する
    # Remove directories. Remove obj entirely including all CRT subdirs
	@rmdir "$(call _relpath,$(OUTPUT_DIR))" 2>/dev/null; rm -rf obj 2>/dev/null; true

# test は makemain.mk の 2 フェーズ エントリが所有する。
# ここでは末端のフェーズ ターゲットだけを定義する。
#   _test_build: テストバイナリのコンパイル/リンクのみ (実行しない)
#   _test_run:   ビルド済みバイナリのテスト実行のみ (ビルド依存は引かない)
# 'test' is owned by the 2-phase entry in makemain.mk; define only the leaf phases.
.PHONY: _test_build _test_run _test_main

# ビルド フェーズ: テストバイナリのコンパイル/リンクのみ
# Build phase: compile/link the test binary only
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
_test_build:
				@echo "Build skipped (SKIP_BUILD=$(SKIP_BUILD))"
else
    ifndef NO_LINK
_test_build: $(OUTPUT_DIR)/$(TARGET)
    else
        # コンパイルのみ
        # Compile only
_test_build: $(OBJS)
    endif
endif

# 実行フェーズ: ビルド済みバイナリのテスト実行のみ
# Run phase: run the already-built test binary only
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
    # そもそもビルドがスキップされているためテスト対象がない
    # Build was skipped, so there is nothing to test
_test_run:
				@echo "Test skipped because it is not included in the build (SKIP_BUILD=$(SKIP_BUILD))"
_test_main:
				@:
else ifeq ($(call should_skip,$(SKIP_TEST)),true)
    # テストのスキップ (ビルドは Phase 1 で実施済み)
    # Skip tests (the build is already done in Phase 1)
_test_run:
				@echo "Test skipped (SKIP_TEST=$(SKIP_TEST))"
_test_main:
				@:
else
_test_run: _pre_test_hook _test_main _post_test_hook
    ifndef NO_LINK
        # テストの実行
        # Run tests
_test_main: $(TESTSH)
				@if [ -z "$(TESTSH)" ]; then \
					echo "$(TESTFW_HOME_ERROR)"; \
					exit 1; \
				fi; \
				status=0; \
				export TEST_SRCS="$(TEST_SRCS)" && "$(SHELL)" "$(TESTSH)" > >($(ICONV)) 2> >($(ICONV) >&2) || status=$$?; \
				exit $$status
    else
        # コンパイルのみ (実行するテストはない)
        # Compile only (nothing to run)
_test_main:
				@:
    endif
endif

ifeq ($(IDENT_ENABLED),1)
include $(MAKEFW_HOME)/makefiles/_ident.mk
endif
