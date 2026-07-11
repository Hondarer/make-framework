include $(WORKSPACE_DIR)/framework/makefw/makefiles/_collect_srcs.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_flags.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_should_skip.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_hooks.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_msvc_compile.mk
include $(WORKSPACE_DIR)/framework/makefw/makefiles/_resource_compile.mk

# -fPIC オプションが含まれていない場合に追加
# Add -fPIC option if not already included
ifdef PLATFORM_LINUX
    ifeq ($(findstring -fPIC,$(CFLAGS)),)
        CFLAGS += -fPIC
    endif
    ifeq ($(findstring -fPIC,$(CXXFLAGS)),)
        CXXFLAGS += -fPIC
    endif
endif

# DEFINES を -D として追加する
CFLAGS   += $(addprefix -D,$(DEFINES))
CXXFLAGS += $(addprefix -D,$(DEFINES))

CFLAGS   += $(addprefix -I, $(INCDIR))
CXXFLAGS += $(addprefix -I, $(INCDIR))

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
	printf '%s\n' "$(CURDIR)" | sed 's@^\(.*\/libsrc\/[^/]*\).*@\1@' \
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

# LIB_TYPE の設定 (デフォルトは static)
# LIB_TYPE setting (default is static)
# make LIB_TYPE=shared で、shared となる
ifeq ($(LIB_TYPE),)
	LIB_TYPE := static
endif

# 成果物のディレクトリ名
# 未指定の場合、カレント ディレクトリ/lib に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/lib

# ディレクトリ名をアーカイブ名にする (Make 関数の notdir でプロセス生成を削減)
# Use directory name as archive name if TARGET is not specified (use Make's notdir to avoid process)
ifeq ($(TARGET),)
    TARGET := $(notdir $(CURDIR))
endif
TARGET_BASE := $(TARGET)
ifdef PLATFORM_LINUX
    ifeq ($(LIB_TYPE),shared)
        TARGET := lib$(TARGET).so
    else ifeq ($(LIB_TYPE),both)
        TARGET        := lib$(TARGET).so
        TARGET_STATIC := lib$(TARGET_BASE)_static.a
    else
        TARGET := lib$(TARGET).a
    endif
else ifdef PLATFORM_WINDOWS
    # Linux 同様に lib プレフィックスを付与
    # Add lib prefix like Linux
    ifeq ($(LIB_TYPE),shared)
        TARGET := lib$(TARGET).dll
    else ifeq ($(LIB_TYPE),both)
        TARGET        := lib$(TARGET).dll
        TARGET_STATIC := lib$(TARGET_BASE)_static.lib
    else
        TARGET := lib$(TARGET).lib
    endif
endif

# Windows DLL は IDENT 指定の有無にかかわらず manifest object をリンクする。
# これにより空の翻訳単位でも DLL と import library を通常経路で生成できる。
# Windows DLLs always link the manifest object, even without IDENT.
# This lets empty translation units produce a DLL and import library through the normal path.
MAKEFW_DLL_IDENT_ENABLED :=
MAKEFW_IDENT_EXPORT :=
ifdef PLATFORM_WINDOWS
    ifneq (,$(filter shared both,$(LIB_TYPE)))
        MAKEFW_DLL_IDENT_ENABLED := 1
        MAKEFW_IDENT_EXPORT := 1
    endif
endif

# デフォルト ターゲットの設定
# Default target setting
# makemain.mk で定義される default ターゲットを使用
# Use the default target defined in makemain.mk
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
    .DEFAULT_GOAL := skip_build
else
    .DEFAULT_GOAL := default
endif

.PHONY: skip_build
skip_build:
	@echo "Build skipped (SKIP_BUILD=$(SKIP_BUILD))"

# ライブラリ ファイルの解決 (LIB_TYPE=shared かつ LIBS が定義されている場合のみ)

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
_build_main: $(if $(PLATFORM_WINDOWS),_msvc_compile,$(OBJS)) $(if $(MAKEFW_SHOULD_BUILD_PARENT_ARTIFACT),_makefw_parent_artifact)
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
# Resolve library files (only when LIB_TYPE=shared/both and LIBS is defined)
ifneq ($(filter shared both,$(LIB_TYPE)),)
    ifneq ($(LIBS),)

        #$(info LIBS: $(LIBS))
        #$(info LIBSDIR: $(LIBSDIR))

        # 現在ビルド中のライブラリ名を取得 (拡張子なし)
        # Get the name of the library currently being built (without extension)
        ifdef PLATFORM_LINUX
            CURRENT_LIB := $(patsubst lib%.so,%,$(TARGET))
        else ifdef PLATFORM_WINDOWS
            CURRENT_LIB := $(patsubst lib%,%,$(basename $(TARGET)))
        endif

        # 静的ライブラリ ファイルの検索
        # Search for static library files
        ifdef PLATFORM_LINUX
            # Linux: .a を検索
            # 自身を除外し、複数の LIBSDIR を考慮
            # Linux: search for .a
            # Exclude self and consider multiple LIBSDIR
            STATIC_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).a))))
        else ifdef PLATFORM_WINDOWS
            # Windows: .lib を検索
            # 自身を除外し、複数の LIBSDIR を考慮
            # まず lib なしで検索、なければ lib 付きで再検索
            # (advapi32 等のフレームワーク ライブラリは lib が付かないための対策)
            # Windows: search for .lib
            # Exclude self and consider multiple LIBSDIR
            # First search without lib prefix, then retry with lib prefix
            # (because framework libraries like advapi32 don't have lib prefix)
            STATIC_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(or \
                    $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/$(lib).lib))),\
                    $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).lib)))))
        endif

        # 見つからないライブラリは動的リンク用フラグとして保持
        # Libraries not found are kept as dynamic link flags
        ifdef PLATFORM_LINUX
            FOUND_LIBS := $(patsubst lib%.a,%,$(notdir $(STATIC_LIBS)))
            NOT_FOUND_LIBS := $(filter-out $(CURRENT_LIB) $(FOUND_LIBS),$(LIBS))
            DYNAMIC_LIBS := $(addprefix -l,$(NOT_FOUND_LIBS))
        else ifdef PLATFORM_WINDOWS
            # STATIC_LIBS の結果から見つかったライブラリ名を導出
            # Derive found library names from STATIC_LIBS results
            FOUND_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(if $(filter %/$(lib).lib %/lib$(lib).lib,$(STATIC_LIBS)),$(lib)))
            NOT_FOUND_LIBS := $(filter-out $(CURRENT_LIB) $(FOUND_LIBS),$(LIBS))
            DYNAMIC_LIBS := $(addsuffix .lib,$(NOT_FOUND_LIBS))
        endif

        # リンク ライブラリ フォルダー名の解決 (DYNAMIC_LIBS の -l に対応する -L パスを追加)
        # Add library search paths to LDFLAGS for dynamic link flags
        ifdef PLATFORM_LINUX
            LDFLAGS += $(addprefix -L, $(LIBSDIR))
        else ifdef PLATFORM_WINDOWS
            LDFLAGS += $(addprefix /LIBPATH:, $(LIBSDIR))
        endif
    endif
endif

#$(info STATIC_LIBS: $(STATIC_LIBS))
#$(info FOUND_LIBS: $(FOUND_LIBS))
#$(info NOT_FOUND_LIBS: $(NOT_FOUND_LIBS))
#$(info DYNAMIC_LIBS: $(DYNAMIC_LIBS))

ifndef NO_LINK
    # 最終的なリンク コマンド
    # Final link command: static libs are embedded, dynamic libs remain as -l
    ifeq ($(LIB_TYPE),shared)
        ifdef PLATFORM_LINUX
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_OBJS) $(STATIC_LIBS) $(LINK_INPUTS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_LINUX); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(STATIC_LIBS) $(LINK_INPUTS) $(DYNAMIC_LIBS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(STATIC_LIBS) $(LINK_INPUTS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					all_objs=$$(tr '\n' ' ' < "$$objs_file" | xargs); \
					extra_objs="$(strip $(MAKEFW_EXTRA_OBJS))"; \
					if [ -n "$$extra_objs" ]; then all_objs="$$all_objs $$extra_objs"; fi; \
					printf '%s\n' "$(strip $(CC) -shared -o $(call _relpath,$@) $$all_objs $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS))"; \
					set -o pipefail; $(CC) -shared -o $@ $$all_objs $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS) 2>&1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
        else ifdef PLATFORM_WINDOWS
            # DLL 副産物 (.lib, .pdb) の存在チェック条件を組み立てる
            # Build existence-check condition for DLL side products (.lib, .pdb)
            _DLL_SIDE_CHECK := [ ! -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.lib,$(TARGET))" ]
            ifneq ($(filter /DEBUG /DEBUG:FULL /DEBUG:FASTLINK,$(LDFLAGS)),)
                _DLL_SIDE_CHECK += || [ ! -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.pdb,$(TARGET))" ]
            endif
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_MSVC_COMPILE) $(STATIC_LIBS) $(LINK_INPUTS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_WINDOWS); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(STATIC_LIBS) $(LINK_INPUTS) $(DYNAMIC_LIBS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(STATIC_LIBS) $(LINK_INPUTS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ] || $(_DLL_SIDE_CHECK); then \
					rsp_file="$(OBJDIR)/link_$$.rsp"; \
					cp "$$objs_file" "$$rsp_file"; \
					printf '%s\n' $(MAKEFW_EXTRA_OBJS) >> "$$rsp_file"; \
					echo "$(strip $(basename $(notdir $(LD))) /DLL /OUT:$(call _relpath,$@) @$(call _relpath,$(OBJDIR))/link_$$.rsp $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS))" | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_format_cmd.ps1; \
					set -o pipefail; MSYS_NO_PATHCONV=1 "$(LD)" /DLL /OUT:$@ @$$rsp_file $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS) 2>&1 | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_link_filter.ps1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
				@if [ -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.exp,$(TARGET))" ]; then mv "$(OUTPUT_DIR)/$(patsubst %.dll,%.exp,$(TARGET))" "$(OBJDIR)/"; fi
        endif
    else ifeq ($(LIB_TYPE),both)
        ifdef PLATFORM_LINUX
# static lib: objects をアーカイブ
$(OUTPUT_DIR)/$(TARGET_STATIC): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_OBJS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_LINUX); \
				if [ ! -s "$$objs_file" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					all_objs=$$(tr '\n' ' ' < "$$objs_file" | xargs); \
					extra_objs="$(strip $(MAKEFW_EXTRA_OBJS))"; \
					if [ -n "$$extra_objs" ]; then all_objs="$$all_objs $$extra_objs"; fi; \
					printf '%s\n' "$(strip $(AR) rvs $(call _relpath,$@) $$all_objs)"; \
					set -o pipefail; $(AR) rvs $@ $$all_objs 2>&1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET_STATIC).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET_STATIC).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET_STATIC).warn"; fi; \
				exit $$_rc
# shared lib: static lib 完成後にリンク
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(OUTPUT_DIR)/$(TARGET_STATIC) $(STATIC_LIBS) $(LINK_INPUTS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_LINUX); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(OUTPUT_DIR)/$(TARGET_STATIC) $(STATIC_LIBS) $(LINK_INPUTS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					all_objs=$$(tr '\n' ' ' < "$$objs_file" | xargs); \
					extra_objs="$(strip $(MAKEFW_EXTRA_OBJS))"; \
					if [ -n "$$extra_objs" ]; then all_objs="$$all_objs $$extra_objs"; fi; \
					printf '%s\n' "$(strip $(CC) -shared -o $(call _relpath,$@) $$all_objs $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS))"; \
					set -o pipefail; $(CC) -shared -o $@ $$all_objs $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS) 2>&1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
        else ifdef PLATFORM_WINDOWS
            # DLL 副産物 (.lib, .pdb) の存在チェック条件を組み立てる
            _DLL_SIDE_CHECK := [ ! -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.lib,$(TARGET))" ]
            ifneq ($(filter /DEBUG /DEBUG:FULL /DEBUG:FASTLINK,$(LDFLAGS)),)
                _DLL_SIDE_CHECK += || [ ! -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.pdb,$(TARGET))" ]
            endif
# static lib: objects をアーカイブ
$(OUTPUT_DIR)/$(TARGET_STATIC): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_MSVC_COMPILE) $(RESOURCE_OBJS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_WINDOWS); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(RESOURCE_OBJS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(RESOURCE_OBJS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					rsp_file="$(OBJDIR)/lib_$$.rsp"; \
					cp "$$objs_file" "$$rsp_file"; \
					printf '%s\n' $(MAKEFW_EXTRA_OBJS) $(RESOURCE_OBJS) >> "$$rsp_file"; \
					echo "$(strip $(AR) /NOLOGO $(LIB_LTCG) /OUT:$(call _relpath,$@) @$(call _relpath,$(OBJDIR))/lib_$$.rsp)" | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_format_cmd.ps1; \
					set -o pipefail; MSYS_NO_PATHCONV=1 "$(AR)" /NOLOGO $(LIB_LTCG) /OUT:$@ @$$rsp_file 2>&1 | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_lib_filter.ps1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET_STATIC).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET_STATIC).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET_STATIC).warn"; fi; \
				exit $$_rc
# DLL: static lib 完成後にリンク
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(OUTPUT_DIR)/$(TARGET_STATIC) $(STATIC_LIBS) $(LINK_INPUTS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_WINDOWS); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(OUTPUT_DIR)/$(TARGET_STATIC) $(STATIC_LIBS) $(LINK_INPUTS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ] || $(_DLL_SIDE_CHECK); then \
					rsp_file="$(OBJDIR)/link_$$.rsp"; \
					cp "$$objs_file" "$$rsp_file"; \
					printf '%s\n' $(MAKEFW_EXTRA_OBJS) >> "$$rsp_file"; \
					echo "$(strip $(basename $(notdir $(LD))) /DLL /OUT:$(call _relpath,$@) @$(call _relpath,$(OBJDIR))/link_$$.rsp $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS))" | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_format_cmd.ps1; \
					set -o pipefail; MSYS_NO_PATHCONV=1 "$(LD)" /DLL /OUT:$@ @$$rsp_file $(LINK_INPUTS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS) 2>&1 | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_link_filter.ps1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
				@if [ -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.exp,$(TARGET))" ]; then mv "$(OUTPUT_DIR)/$(patsubst %.dll,%.exp,$(TARGET))" "$(OBJDIR)/"; fi
        endif
    else
        ifdef PLATFORM_LINUX
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_OBJS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_LINUX); \
				if [ ! -s "$$objs_file" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					all_objs=$$(tr '\n' ' ' < "$$objs_file" | xargs); \
					extra_objs="$(strip $(MAKEFW_EXTRA_OBJS))"; \
					if [ -n "$$extra_objs" ]; then all_objs="$$all_objs $$extra_objs"; fi; \
					printf '%s\n' "$(strip $(AR) rvs $(call _relpath,$@) $$all_objs)"; \
					set -o pipefail; $(AR) rvs $@ $$all_objs 2>&1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
        else ifdef PLATFORM_WINDOWS
$(OUTPUT_DIR)/$(TARGET): $(MAKEFW_ARTIFACT_DEPS) $(MAKEFW_ARTIFACT_MSVC_COMPILE) $(RESOURCE_OBJS) | $(OUTPUT_DIR) $(OBJDIR)
				@$(_MAKEFW_OBJLIST_WINDOWS); \
				if [ ! -s "$$objs_file" ] && [ -z "$(strip $(RESOURCE_OBJS))" ]; then \
					_rc=0; \
				else \
				if [ "$$rebuild" = 0 ]; then \
					for dep in $(MAKEFW_EXTRA_OBJS) $(RESOURCE_OBJS); do \
						if [ "$$dep" -nt "$@" ]; then rebuild=1; break; fi; \
					done; \
				fi; \
				if [ "$$rebuild" = 1 ]; then \
					rsp_file="$(OBJDIR)/lib_$$.rsp"; \
					cp "$$objs_file" "$$rsp_file"; \
					printf '%s\n' $(MAKEFW_EXTRA_OBJS) $(RESOURCE_OBJS) >> "$$rsp_file"; \
					echo "$(strip $(AR) /NOLOGO $(LIB_LTCG) /OUT:$(call _relpath,$@) @$(call _relpath,$(OBJDIR))/lib_$$.rsp)" | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_format_cmd.ps1; \
					set -o pipefail; MSYS_NO_PATHCONV=1 "$(AR)" /NOLOGO $(LIB_LTCG) /OUT:$@ @$$rsp_file 2>&1 | powershell -ExecutionPolicy Bypass -File $(WORKSPACE_DIR)/framework/makefw/bin/msvc_lib_filter.ps1 | $(CAPTURE_WARNINGS) $(OUTPUT_DIR)/$(TARGET).warn; \
					_rc=$$?; \
				else \
					_rc=0; \
				fi; fi; \
				if [ ! -s "$(OUTPUT_DIR)/$(TARGET).warn" ]; then rm -f "$(OUTPUT_DIR)/$(TARGET).warn"; fi; \
				exit $$_rc
        endif
    endif
endif

# コンパイル時の依存関係に $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) を定義しているのは
# ヘッダー類などを引き込んでおく必要がある場合に、先に処理を行っておきたいため
# We define $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) as compile-time dependencies to ensure all headers are processed first

# コンパイル ルールのテンプレート定義
# Compile rule template definition
# 引数: $(1)=拡張子 (c/cc/cpp), $(2)=コンパイラ変数名 (CC/CXX), $(3)=フラグ変数名 (CFLAGS/CXXFLAGS)
# Windows のコンパイルは _msvc_compile で処理するため、パターン ルールは Linux のみ定義する
define compile_rule_template
ifdef PLATFORM_LINUX
$$(OBJDIR)/%.o: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR) $$(OUTPUT_DIR)
		@echo $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$<
		@set -o pipefail; LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(ICONV) | $$(CAPTURE_WARNINGS) $$<.warn
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
	ln -s $(2) $(1)
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
		cat $(2) | sh $(1).filter.sh > $(1); \
		diff $(2) $(1); set $?=0; \
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

CLEAN_COMMON := $(strip $(OBJDIR) $(MAKEFW_CLEAN_IMPORTED_SRCS))
ifndef NO_LINK
    CLEAN_COMMON += $(call _relpath,$(OUTPUT_DIR)/$(TARGET))
    CLEAN_COMMON += $(call _relpath,$(OUTPUT_DIR)/$(TARGET).warn)
    ifeq ($(LIB_TYPE),both)
        CLEAN_COMMON += $(call _relpath,$(OUTPUT_DIR)/$(TARGET_STATIC))
        CLEAN_COMMON += $(call _relpath,$(OUTPUT_DIR)/$(TARGET_STATIC).warn)
    endif
    ifdef PLATFORM_WINDOWS
        ifeq ($(LIB_TYPE),shared)
            CLEAN_OS := $(call _relpath,$(OUTPUT_DIR)/$(patsubst %.dll,%.pdb,$(TARGET)))
            CLEAN_OS += $(call _relpath,$(OUTPUT_DIR)/$(patsubst %.dll,%.lib,$(TARGET)))
        else ifeq ($(LIB_TYPE),both)
            # DLL 副産物 (インポート ライブラリ・リンカ PDB) + static コンパイラ PDB
            CLEAN_OS := $(call _relpath,$(OUTPUT_DIR)/$(patsubst %.dll,%.pdb,$(TARGET)))
            CLEAN_OS += $(call _relpath,$(OUTPUT_DIR)/$(patsubst %.dll,%.lib,$(TARGET)))
            CLEAN_OS += $(call _relpath,$(OUTPUT_DIR)/$(basename $(TARGET_STATIC)).pdb)
        else
            # 静的ライブラリの場合は、統合 PDB ファイルを削除対象に追加
            # For static libraries, add the unified PDB file to clean target
            CLEAN_OS := $(call _relpath,$(OUTPUT_DIR)/$(basename $(TARGET)).pdb)
        endif
    endif
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
    ifndef NO_LINK
	@rmdir "$(call _relpath,$(OUTPUT_DIR))" 2>/dev/null; rm -rf obj 2>/dev/null; true
    else
	@rm -rf obj 2>/dev/null; true
    endif

# test は makemain.mk の 2 フェーズ エントリが所有する。
# ライブラリには実行するテストがないため、ビルド フェーズでライブラリを生成し、
# 実行フェーズは何もしない (フック互換のため _test_main は空で残す)。
# 'test' is owned by the 2-phase entry in makemain.mk; a library has nothing to run,
# so build it in the build phase and do nothing in the run phase.
.PHONY: _test_build _test_run _test_main

# ビルド フェーズ: ライブラリのビルドのみ
# Build phase: build the library only
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

# 実行フェーズ: ライブラリには実行するテストがない
# Run phase: a library has no tests to run
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
    # そもそもビルドがスキップされている
    # Build was skipped
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
_test_main:
				@:
endif

ifneq (,$(filter 1,$(IDENT_ENABLED) $(MAKEFW_DLL_IDENT_ENABLED)))
include $(MAKEFW_HOME)/makefiles/_ident.mk
endif
