include $(WORKSPACE_FOLDER)/makefw/makefiles/_collect_srcs.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_flags.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_should_skip.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_hooks.mk

# -fPIC オプションが含まれていない場合に追加
# Add -fPIC option if not already included
ifneq ($(OS),Windows_NT)
    # Linux
    ifeq ($(findstring -fPIC,$(CFLAGS)),)
        CFLAGS += -fPIC
    endif
    ifeq ($(findstring -fPIC,$(CXXFLAGS)),)
        CXXFLAGS += -fPIC
    endif
endif

# c_cpp_properties.json の defines にある値を -D として追加する
# DEFINES は prepare.mk で設定されている
CFLAGS   += $(addprefix -D,$(DEFINES))
CXXFLAGS += $(addprefix -D,$(DEFINES))

CFLAGS   += $(addprefix -I, $(INCDIR))
CXXFLAGS += $(addprefix -I, $(INCDIR))

# OBJS
# 直下の obj ディレクトリのオブジェクトファイル
# Object files in the current obj directory
OBJS := $(filter-out $(OBJDIR)/%.inject.o, \
	$(sort $(addprefix $(OBJDIR)/, \
	$(notdir $(patsubst %.c, %.o, $(patsubst %.cc, %.o, $(patsubst %.cpp, %.o, $(SRCS_C) $(SRCS_CPP))))))))
# DEPS
DEPS := $(patsubst %.o, %.d, $(OBJS))
ifeq ($(OS),Windows_NT)
    # Windows の場合は .o を .obj に置換
    OBJS := $(patsubst %.o, %.obj, $(OBJS))
endif

# サブディレクトリの obj ディレクトリを再帰的に検索して、オブジェクトファイルを収集
# Recursively collect object files from subdirectories' obj directories
# find -exec find を単一の find -path パターンに変更してプロセス生成を削減
# Replace find -exec find with single find using -path pattern to reduce process creation
ifeq ($(OS),Windows_NT)
    # Windows: .obj ファイルを検索
    SUBDIR_OBJS := $(shell find . -path "./obj" -prune -o -path "*/obj/*.obj" -type f -print 2>/dev/null)
else
    # Linux: .o ファイルを検索
    SUBDIR_OBJS := $(shell find . -path "./obj" -prune -o -path "*/obj/*.o" -type f -print 2>/dev/null)
endif
OBJS += $(SUBDIR_OBJS)

# LIB_TYPE の設定 (デフォルトは static)
# LIB_TYPE setting (default is static)
# make LIB_TYPE=shared で、shared となる
ifeq ($(LIB_TYPE),)
	LIB_TYPE := static
endif

# 成果物のディレクトリ名
# 未指定の場合、カレントディレクトリ/lib に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/lib

# ディレクトリ名をアーカイブ名にする (Make 関数の notdir でプロセス生成を削減)
# Use directory name as archive name if TARGET is not specified (use Make's notdir to avoid process)
ifeq ($(TARGET),)
    TARGET := $(notdir $(CURDIR))
endif
ifneq ($(OS),Windows_NT)
    # Linux
    ifeq ($(LIB_TYPE),shared)
        TARGET := lib$(TARGET).so
    else
        TARGET := lib$(TARGET).a
    endif
else
    # Windows
    # Linux 同様に lib プレフィックスを付与
    # Add lib prefix like Linux
    ifeq ($(LIB_TYPE),shared)
        TARGET := lib$(TARGET).dll
    else
        TARGET := lib$(TARGET).lib
    endif
endif

# デフォルトターゲットの設定
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

# ライブラリファイルの解決 (LIB_TYPE=shared かつ LIBS が定義されている場合のみ)

# default および build ターゲットの定義
# makemain.mk で default: $(SUBDIRS) および build: $(SUBDIRS) が定義されるため、
# ここでは実際のビルドターゲットへの依存関係のみを追加
# Define default and build targets
.PHONY: default
default: build

.PHONY: build _build_main
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
build: skip_build
else
build: _pre_build_hook _build_main _post_build_hook
endif

# 実際のビルド処理
# Actual build process
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
_build_main:
	@:
else
    ifndef NO_LINK
_build_main: $(OUTPUT_DIR)/$(TARGET)
    else
_build_main: $(OBJS)
    endif
endif

# ビルド完了後に .gitignore を1回だけソート/重複排除 (スタンプファイルで不要な実行を回避)
# Normalize .gitignore once after build (stamp file avoids unnecessary execution)
# link/copy 対象ファイルが更新された場合のみ sort を実行し、それ以外ではプロセス生成ゼロ
# Only runs sort when link/copy targets changed; zero process creation otherwise
ifneq ($(strip $(notdir $(CP_SRCS) $(LINK_SRCS))),)
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
else
build: $(OBJDIR)/.gitignore_sorted
endif
$(OBJDIR)/.gitignore_sorted: $(notdir $(CP_SRCS) $(LINK_SRCS)) | $(OBJDIR)
	@sort -u -o .gitignore .gitignore && touch $@
endif
# Resolve library files (only when LIB_TYPE=shared and LIBS is defined)
ifeq ($(LIB_TYPE),shared)
    ifneq ($(LIBS),)

        #$(info LIBS: $(LIBS))
        #$(info LIBSDIR: $(LIBSDIR))

        # 現在ビルド中のライブラリ名を取得 (拡張子なし)
        # Get the name of the library currently being built (without extension)
        ifeq ($(OS),Windows_NT)
            CURRENT_LIB := $(patsubst lib%,%,$(basename $(TARGET)))
        else
            CURRENT_LIB := $(patsubst lib%.so,%,$(TARGET))
        endif

        # 静的ライブラリファイルの検索
        # Search for static library files
        ifeq ($(OS),Windows_NT)
            # Windows: .lib を検索
            # 自身を除外し、複数の LIBSDIR を考慮
            # まず lib なしで検索、なければ lib 付きで再検索
            # (advapi32 等のフレームワークライブラリは lib が付かないための対策)
            # Windows: search for .lib
            # Exclude self and consider multiple LIBSDIR
            # First search without lib prefix, then retry with lib prefix
            # (because framework libraries like advapi32 don't have lib prefix)
            STATIC_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(or \
                    $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/$(lib).lib))),\
                    $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).lib)))))
        else
            # Linux: .a を検索
            # 自身を除外し、複数の LIBSDIR を考慮
            # Linux: search for .a
            # Exclude self and consider multiple LIBSDIR
            STATIC_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/lib$(lib).a))))
        endif

        # 見つからないライブラリは動的リンク用フラグとして保持
        # Libraries not found are kept as dynamic link flags
        ifeq ($(OS),Windows_NT)
            # STATIC_LIBS の結果から見つかったライブラリ名を導出
            # Derive found library names from STATIC_LIBS results
            FOUND_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(if $(filter %/$(lib).lib %/lib$(lib).lib,$(STATIC_LIBS)),$(lib)))
            NOT_FOUND_LIBS := $(filter-out $(CURRENT_LIB) $(FOUND_LIBS),$(LIBS))
            DYNAMIC_LIBS := $(addsuffix .lib,$(NOT_FOUND_LIBS))
        else
            FOUND_LIBS := $(patsubst lib%.a,%,$(notdir $(STATIC_LIBS)))
            NOT_FOUND_LIBS := $(filter-out $(CURRENT_LIB) $(FOUND_LIBS),$(LIBS))
            DYNAMIC_LIBS := $(addprefix -l,$(NOT_FOUND_LIBS))
        endif
    endif
endif

#$(info STATIC_LIBS: $(STATIC_LIBS))
#$(info FOUND_LIBS: $(FOUND_LIBS))
#$(info NOT_FOUND_LIBS: $(NOT_FOUND_LIBS))
#$(info DYNAMIC_LIBS: $(DYNAMIC_LIBS))

ifndef NO_LINK
    # 最終的なリンクコマンド
    # Final link command: static libs are embedded, dynamic libs remain as -l
    ifeq ($(LIB_TYPE),shared)
        ifneq ($(OS),Windows_NT)
            # Linux
$(OUTPUT_DIR)/$(TARGET): $(SUBDIRS) $(OBJS) $(STATIC_LIBS) | $(OUTPUT_DIR)
				@all_objs="$(OBJS)"; \
				sub_objs=$$(find . -name "*.o" -not -path "./obj/*"); \
				if [ -n "$$sub_objs" ]; then all_objs="$$all_objs $$sub_objs"; fi; \
				all_objs=$$(echo $$all_objs | tr ' ' '\n' | sort -u | tr '\n' ' '); \
				newest=$$(ls -t $$all_objs $@ 2>/dev/null | head -1); \
				if [ "$$newest" != "$@" ]; then \
					echo "$(CC) -shared -o $@ $$all_objs $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS)"; \
					$(CC) -shared -o $@ $$all_objs $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS); \
				fi
        else
            # Windows
$(OUTPUT_DIR)/$(TARGET): $(SUBDIRS) $(OBJS) $(STATIC_LIBS) | $(OUTPUT_DIR)
			@all_objs="$(OBJS)"; \
			sub_objs=$$(find . -name "*.obj" -not -path "./obj/*"); \
			if [ -n "$$sub_objs" ]; then all_objs="$$all_objs $$sub_objs"; fi; \
			all_objs=$$(echo $$all_objs | tr ' ' '\n' | sort -u | tr '\n' ' '); \
			newest=$$(ls -t $$all_objs $@ 2>/dev/null | head -1); \
			if [ "$$newest" != "$@" ]; then \
				echo "MSYS_NO_PATHCONV=1 LANG=$(FILES_LANG) $(LD) /DLL /OUT:$@ $$all_objs $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS)"; \
				MSYS_NO_PATHCONV=1 LANG=$(FILES_LANG) $(LD) /DLL /OUT:$@ $$all_objs $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS); \
			fi
			@if [ -f "$(OUTPUT_DIR)/$(patsubst %.dll,%.exp,$(TARGET))" ]; then mv "$(OUTPUT_DIR)/$(patsubst %.dll,%.exp,$(TARGET))" "$(OBJDIR)/"; fi
        endif
    else
        ifneq ($(OS),Windows_NT)
            # Linux
$(OUTPUT_DIR)/$(TARGET): $(SUBDIRS) $(OBJS) | $(OUTPUT_DIR)
				@all_objs="$(OBJS)"; \
				sub_objs=$$(find . -name "*.o" -not -path "./obj/*"); \
				if [ -n "$$sub_objs" ]; then all_objs="$$all_objs $$sub_objs"; fi; \
				all_objs=$$(echo $$all_objs | tr ' ' '\n' | sort -u | tr '\n' ' '); \
				newest=$$(ls -t $$all_objs $@ 2>/dev/null | head -1); \
				if [ "$$newest" != "$@" ]; then \
					echo "$(AR) rvs $@ $$all_objs"; \
					$(AR) rvs $@ $$all_objs; \
				fi
        else
            # Windows
$(OUTPUT_DIR)/$(TARGET): $(SUBDIRS) $(OBJS) | $(OUTPUT_DIR)
				@all_objs="$(OBJS)"; \
				sub_objs=$$(find . -name "*.obj" -not -path "./obj/*"); \
				if [ -n "$$sub_objs" ]; then all_objs="$$all_objs $$sub_objs"; fi; \
				all_objs=$$(echo $$all_objs | tr ' ' '\n' | sort -u | tr '\n' ' '); \
				newest=$$(ls -t $$all_objs $@ 2>/dev/null | head -1); \
				if [ "$$newest" != "$@" ]; then \
					echo "MSYS_NO_PATHCONV=1 LANG=$(FILES_LANG) $(AR) /NOLOGO /OUT:$@ $$all_objs"; \
					MSYS_NO_PATHCONV=1 LANG=$(FILES_LANG) $(AR) /NOLOGO /OUT:$@ $$all_objs; \
				fi
        endif
    endif
endif

# コンパイル時の依存関係に $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) を定義しているのは
# ヘッダ類などを引き込んでおく必要がある場合に、先に処理を行っておきたいため
# We define $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) as compile-time dependencies to ensure all headers are processed first

# コンパイルルールのテンプレート定義
# Compile rule template definition
# 引数: $(1)=拡張子 (c/cc/cpp), $(2)=コンパイラ変数名 (CC/CXX), $(3)=フラグ変数名 (CFLAGS/CXXFLAGS)
define compile_rule_template
ifneq ($$(OS),Windows_NT)
    # Linux
$$(OBJDIR)/%.o: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR) $$(OUTPUT_DIR)
		set -o pipefail; LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(ICONV)
else
    # Windows
    # 静的ライブラリの場合は OUTPUT_DIR に統合 PDB を生成、動的ライブラリの場合は個別 PDB を生成
    # For static libraries, generate a unified PDB in OUTPUT_DIR; for shared libraries, generate individual PDBs
    ifeq ($$(LIB_TYPE),shared)
$$(OBJDIR)/%.obj: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR) $$(OUTPUT_DIR)
		set -o pipefail; MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) /Fd$$(patsubst %.obj,%.pdb,$$@) /c /Fo:$$@ $$< 2>&1 | sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d | $$(ICONV)
    else
$$(OBJDIR)/%.obj: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR) $$(OUTPUT_DIR)
		set -o pipefail; MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) /Fd$$(OUTPUT_DIR)/$$(basename $$(TARGET)).pdb /c /Fo:$$@ $$< 2>&1 | sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d | $$(ICONV)
    endif
endif
endef

# C ソースファイルのコンパイル
# Compile C source files
$(eval $(call compile_rule_template,c,CC,CFLAGS))

# C++ ソースファイルのコンパイル (*.cc)
# Compile C++ source files (*.cc)
$(eval $(call compile_rule_template,cc,CXX,CXXFLAGS))

# C++ ソースファイルのコンパイル (*.cpp)
# Compile C++ source files (*.cpp)
$(eval $(call compile_rule_template,cpp,CXX,CXXFLAGS))

# シンボリックリンク対象のソースファイルをシンボリックリンク
# Create symbolic links for LINK_SRCS
# .gitignore への追記のみ行い、ソート/重複排除は行わない (プロセス生成削減)
# Only append to .gitignore, skip sort/uniq per file (reduce process creation)
define generate_link_src_rule
$(1):
	ln -s $(2) $(1)
#	.gitignore に対象ファイルを追加
#	Add the file to .gitignore
	@grep -qxF '/$(1)' .gitignore 2>/dev/null || echo /$(1) >> .gitignore
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

# コピー対象のソースファイルをコピーして
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
#	.gitignore に対象ファイルを追加 (追記のみ、ソート/重複排除は行わない - プロセス生成削減)
#	Add the file to .gitignore (append only, skip sort/uniq per file - reduce process creation)
	@grep -qxF '/$(1)' .gitignore 2>/dev/null || echo /$(1) >> .gitignore
endef

# ファイルごとの依存関係を動的に定義
# Dynamically define file-by-file dependencies
$(foreach cp_src,$(CP_SRCS),$(eval $(call generate_cp_src_rule,$(notdir $(cp_src)),$(cp_src))))

# The empty rule is required to handle the case where the dependency file is deleted.
$(DEPS):

include $(wildcard $(DEPS))

$(OUTPUT_DIR):
	mkdir -p $@

$(OBJDIR):
	mkdir -p $@

# 削除対象の定義
# Define files/directories to clean
CLEAN_COMMON := $(OUTPUT_DIR)/$(TARGET) $(OBJDIR) $(notdir $(CP_SRCS) $(LINK_SRCS))
ifeq ($(OS),Windows_NT)
    # Windows
    ifeq ($(LIB_TYPE),shared)
        CLEAN_OS := $(OUTPUT_DIR)/$(patsubst %.dll,%.pdb,$(TARGET))
        CLEAN_OS += $(OUTPUT_DIR)/$(patsubst %.dll,%.lib,$(TARGET))
    else
        # 静的ライブラリの場合は、統合 PDB ファイルを削除対象に追加
        # For static libraries, add the unified PDB file to clean target
        CLEAN_OS := $(OUTPUT_DIR)/$(basename $(TARGET)).pdb
    endif
endif
ifeq ($(strip $(notdir $(CP_SRCS) $(LINK_SRCS))),)
    CLEAN_COMMON += .gitignore
endif

.PHONY: clean _clean_main
clean: _pre_clean_hook _clean_main _post_clean_hook

# 実際のクリーン処理
# Actual clean process
_clean_main:
    # .gitignore の再生成 (コミット差分が出ないように)
    # Regenerate .gitignore (avoid commit diffs)
    # mktemp の2回呼び出しと for ループを printf + sort -u に簡略化 (プロセス生成削減)
    # Simplify 2x mktemp + for-loop to printf + sort -u (reduce process creation)
    ifneq ($(strip $(notdir $(CP_SRCS) $(LINK_SRCS))),)
		@printf '%s\n' $(addprefix /,$(notdir $(CP_SRCS) $(LINK_SRCS))) | sort -u > .gitignore
    endif
	-rm -rf $(CLEAN_COMMON) $(CLEAN_OS)
    # $(OUTPUT_DIR) に配下がなければ、$(OUTPUT_DIR) を削除する (rmdir は非空なら失敗するので直接試行)
    # Remove $(OUTPUT_DIR) if it's empty (rmdir fails on non-empty, so just try it)
	@rmdir "$(OUTPUT_DIR)" 2>/dev/null && echo "rmdir \"$(OUTPUT_DIR)\"" || true
    # Windows の場合、obj に配下がなければ、obj を削除する
    # Remove obj if it's empty (Windows only)
ifeq ($(OS),Windows_NT)
	@rmdir obj 2>/dev/null && echo "rmdir obj" || true
endif

.PHONY: test _test_main
ifeq ($(call should_skip,$(SKIP_TEST)),true)
    # テストのスキップ
    # Skip tests
    # test スキップ時は、ビルドスキップもチェックする
    ifeq ($(call should_skip,$(SKIP_BUILD)),true)
        # test もビルドもスキップ
test:
			@echo "Build & Test skipped (SKIP_BUILD=$(SKIP_BUILD), SKIP_TEST=$(SKIP_TEST))"
_test_main:
			@:
    else
        # test はスキップするがビルドはする
test: _pre_test_hook _test_main _post_test_hook
        ifndef NO_LINK
_test_main: $(OUTPUT_DIR)/$(TARGET)
				@echo "Test skipped (SKIP_TEST=$(SKIP_TEST))"
        else
            # コンパイルのみ
_test_main: $(OBJS)
				@echo "Test skipped (SKIP_TEST=$(SKIP_TEST))"
        endif
    endif
else
    ifeq ($(call should_skip,$(SKIP_BUILD)),true)
        # そもそもビルドがスキップ
test:
			@echo "Test skipped because it is not included in the build (SKIP_BUILD=$(SKIP_BUILD))"
_test_main:
			@:
    else
        # スキップしない
test: _pre_test_hook _test_main _post_test_hook
        ifndef NO_LINK
_test_main: $(OUTPUT_DIR)/$(TARGET)
        else
            # コンパイルのみ
_test_main: $(OBJS)
        endif
    endif
endif
