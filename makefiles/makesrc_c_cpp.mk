include $(WORKSPACE_FOLDER)/makefw/makefiles/_collect_srcs.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_flags.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_should_skip.mk

LIBSFILES := $(shell for dir in $(LIBSDIR); do [ -d $$dir ] && find $$dir -maxdepth 1 -type f; done)

# テストライブラリの設定
# Set test libraries
# LINK_TEST が 1 の場合にのみ設定する
ifeq ($(LINK_TEST), 1)
    LIBS += test_com gtest gmock

    ifneq ($(OS),Windows_NT)
        # Linux
        LIBS += pthread gcov
        # ステップ実行/カバレッジに支障となるオプションを除去
        #   -flto: リンク時最適化 (GCC の LTO)
        LDFLAGS := $(filter-out -flto,$(LDFLAGS))
        # TARGET_ARCH を使用してプラットフォーム固有のパスを指定
        # Use TARGET_ARCH for platform-specific path (e.g., linux-el8-x64)
        LIBSDIR += $(WORKSPACE_FOLDER)/testfw/gtest/lib/$(TARGET_ARCH)
    else
        # Windows
        # ステップ実行/カバレッジに支障となるオプションを除去
        #   /LTCG: リンク時コード生成 (プログラム全体最適化)
        LDFLAGS := $(filter-out /LTCG,$(LDFLAGS))
        # MSVC_CRT_SUBDIR は prepare.mk で CONFIG と MSVC_CRT から計算される
        # MSVC_CRT_SUBDIR is calculated in prepare.mk from CONFIG and MSVC_CRT
        # TARGET_ARCH を使用してプラットフォーム固有のパスを指定
        # Use TARGET_ARCH for platform-specific path (e.g., windows-x64/md)
        LIBSDIR += $(WORKSPACE_FOLDER)/testfw/gtest/lib/$(TARGET_ARCH)/$(MSVC_CRT_SUBDIR)
    endif

    ifneq ($(NO_GTEST_MAIN), 1)
        # gtest_main 有効
        ifeq ($(USE_WRAP_MAIN), 1)
            # gtest_main 有効 && wrap_main 有効
            LIBS += gtest_wrapmain
        else
            # gtest_main 有効 && wrap_main 無効
            LIBS += gtest_main
        endif
    endif
endif

#$(info NO_GTEST_MAIN: $(NO_GTEST_MAIN))
#$(info USE_WRAP_MAIN: $(USE_WRAP_MAIN))
#$(info LIBS: $(LIBS))

TESTSH := $(WORKSPACE_FOLDER)/testfw/cmnd/exec_test_c_cpp.sh

GCOVDIR := gcov
LCOVDIR := lcov
COVERAGEDIR := coverage

# c_cpp_properties.json の defines にある値を -D として追加する
# DEFINES は prepare.mk で設定されている
CFLAGS   += $(addprefix -D,$(DEFINES))
CXXFLAGS += $(addprefix -D,$(DEFINES))

# NOTE: テスト対象の場合は、CFLAGS の後、通常の include の前に include_override を追加する
#       CFLAGS に追加した include パスは、include_override より前に評価されるので
#       個別のテストでの include 注入に対応できる
# NOTE: For test targets, add include_override after CFLAGS but before normal includes, so that test-specific includes can override

# テスト対象
# For test targets
CFLAGS_TEST := $(CFLAGS) -I$(WORKSPACE_FOLDER)/testfw/include_override -I$(WORKSPACE_FOLDER)/test/include_override $(addprefix -I, $(INCDIR))
CXXFLAGS_TEST := $(CXXFLAGS) -I$(WORKSPACE_FOLDER)/testfw/include_override -I$(WORKSPACE_FOLDER)/test/include_override $(addprefix -I, $(INCDIR))
ifneq ($(OS),Windows_NT)
    # Linux
    # ステップ実行/カバレッジに支障となるオプションを除去
    #   -O1, -O2, -O3, -Os, -Ofast: 最適化レベル
    #   -finline-functions: インライン展開
    #   -fomit-frame-pointer: フレームポインタ省略
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
else
    # Windows
    # ステップ実行/カバレッジに支障となるオプションを除去
    #   /O1, /O2: 最適化 (コード再配置・省略が発生)
    #   /Ob1, /Ob2: インライン展開 (関数呼び出しが消える)
    #   /Oi: 組み込み関数 (標準関数がインライン化)
    #   /Oy: フレームポインタ省略 (スタックトレース不正確)
    #   /GL: リンク時最適化 (LTCG)
    #   /Gw: グローバルデータ最適化
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

# リンクライブラリファイル名の解決
ifneq ($(OS),Windows_NT)
    # Linux
    LIBS := $(addprefix -l, $(LIBS))
else
    # Windows
    LIBS := $(addsuffix .lib,$(LIBS))
endif

# リンクライブラリフォルダ名の解決
ifneq ($(OS),Windows_NT)
    # Linux
    LDFLAGS := $(LDFLAGS) $(addprefix -L, $(LIBSDIR))
else
    # Windows
    LDFLAGS := $(LDFLAGS) $(addprefix /LIBPATH:, $(LIBSDIR))
endif

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
ifeq ($(OS),Windows_NT)
    # Windows: .obj ファイルを検索
    SUBDIR_OBJS := $(shell find . -type d -name obj -not -path "./obj" -exec find {} -maxdepth 1 -type f -name "*.obj" \; 2>/dev/null)
else
    # Linux: .o ファイルを検索
    SUBDIR_OBJS := $(shell find . -type d -name obj -not -path "./obj" -exec find {} -maxdepth 1 -type f -name "*.o" \; 2>/dev/null)
endif
OBJS += $(SUBDIR_OBJS)

# 成果物のディレクトリ名
# 未指定の場合、カレントディレクトリ/bin に成果物を生成する
OUTPUT_DIR ?= $(CURDIR)/bin

# ディレクトリ名を実行体名にする
# Use directory name as executable name if TARGET is not specified
ifeq ($(TARGET),)
    TARGET := $(shell basename `pwd`)
endif
ifeq ($(OS),Windows_NT)
    # Windows
    TARGET := $(TARGET).exe
endif

# デフォルトターゲットの設定
# Default target setting
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
    .DEFAULT_GOAL := skip_build
else
    ifndef NO_LINK
        .DEFAULT_GOAL := $(OUTPUT_DIR)/$(TARGET)
    else
        .DEFAULT_GOAL := $(OBJS) $(LIBSFILES)
    endif
endif

.PHONY: skip_build
skip_build:
	@echo "Build skipped (SKIP_BUILD=$(SKIP_BUILD))"

ifndef NO_LINK
    # 実行体の生成
    # Build the executable
    ifneq ($(OS),Windows_NT)
        # Linux
$(OUTPUT_DIR)/$(TARGET): $(OBJS) $(LIBSFILES) | $(OUTPUT_DIR)
			set -o pipefail; LANG=$(FILES_LANG) $(LD) $(LDFLAGS) -o $@ $(OBJS) $(LIBS) -fdiagnostics-color=always 2>&1 | $(NKF)
    else
        # Windows
$(OUTPUT_DIR)/$(TARGET): $(OBJS) $(LIBSFILES) | $(OUTPUT_DIR)
			set -o pipefail; MSYS_NO_PATHCONV=1 LANG=$(FILES_LANG) $(LD) $(LDFLAGS) /PDB:$(patsubst %.exe,%.pdb,$@) /ILK:$(OBJDIR)/$(patsubst %.exe,%.ilk,$@) /OUT:$@ $(OBJS) $(LIBS) 2>&1 | $(NKF)
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
# ヘッダ類などを引き込んでおく必要がある場合に、先に処理を行っておきたいため
# We define $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) as compile-time dependencies to ensure all headers are processed first

# コンパイルルールのテンプレート定義
# Compile rule template definition
# 引数: $(1)=拡張子 (c/cc/cpp), $(2)=コンパイラ変数名 (CC/CXX), $(3)=フラグ変数名 (CFLAGS/CXXFLAGS)
define compile_rule_template
ifneq ($$(OS),Windows_NT)
    # Linux
$$(OBJDIR)/%.o: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR)
		@set -o pipefail; if echo $$(TEST_SRCS) | grep -q $$(notdir $$<); then \
			echo LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -D_IN_TEST_SRC -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
			LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -D_IN_TEST_SRC -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
		else \
			echo LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
			LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
		fi
else
    # Windows
$$(OBJDIR)/%.obj: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR)
		@set -o pipefail; if echo $$(TEST_SRCS) | grep -q $$(notdir $$<); then \
			echo MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -D_IN_TEST_SRC /c /Fo$$@ $$< 2>&1 '|' sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d '|' $$(NKF); \
			MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) /FdD:$$(patsubst %.obj,%.pdb,$$@) -D_IN_TEST_SRC /c /Fo$$@ $$< 2>&1 | sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d | $$(NKF); \
		else \
			echo MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) /c /Fo$$@ $$< 2>&1 '|' sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d '|' $$(NKF); \
			MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) /FdD:$$(patsubst %.obj,%.pdb,$$@) /c /Fo$$@ $$< 2>&1 | sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d | $$(NKF); \
		fi
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
define generate_link_src_rule
$(1):
	ln -s $(2) $(1)
#	.gitignore に対象ファイルを追加
#	Add the file to .gitignore
	echo /$(1) >> .gitignore
	@tempfile=$$(mktemp) && \
	sort .gitignore | uniq > $$tempfile && \
	mv $$tempfile .gitignore
endef

# ファイルごとの依存関係を動的に定義
# ただし、from, to が同じになる場合 (一般的には Makefile の定義ミス) はスキップ
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
		cat $(2) | sh -e $(1).filter.sh > $(1) && \
		diff $(2) $(1) | $(NKF) && set $?=0; \
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
#	.gitignore に対象ファイルを追加
#	Add the file to .gitignore
	echo /$(1) >> .gitignore
	@tempfile=$$(mktemp) && \
	sort .gitignore | uniq > $$tempfile && \
	mv $$tempfile .gitignore
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
CLEAN_COMMON := "$(OUTPUT_DIR)/$(TARGET)" $(OBJDIR) $(GCOVDIR) $(COVERAGEDIR) $(notdir $(CP_SRCS) $(LINK_SRCS)) results
ifneq ($(OS),Windows_NT)
    # Linux
    CLEAN_OS := core $(LCOVDIR)
else
    # Windows
    CLEAN_OS := $(patsubst %.exe,%.pdb,$(OUTPUT_DIR)/$(TARGET))
endif
ifeq ($(strip $(notdir $(CP_SRCS) $(LINK_SRCS))),)
    CLEAN_COMMON += .gitignore
endif

.PHONY: clean
clean:
    # .gitignore の再生成 (コミット差分が出ないように)
    # Regenerate .gitignore (avoid commit diffs)
    ifneq ($(strip $(notdir $(CP_SRCS) $(LINK_SRCS))),)
		@tempfile=$$(mktemp) && \
		tempfile2=$$(mktemp) && \
		for ignorefile in $(notdir $(CP_SRCS) $(LINK_SRCS)); \
			do echo /$$ignorefile >> $$tempfile; \
		done && \
		sort $$tempfile | uniq > $$tempfile2 && \
		mv $$tempfile2 .gitignore && \
		rm -f $$tempfile
    endif
	-rm -rf $(CLEAN_COMMON) $(CLEAN_OS)
    # $(OUTPUT_DIR) に配下がなければ、$(OUTPUT_DIR) を削除する
    # Remove $(OUTPUT_DIR) if it's empty
	-rmdir "$(OUTPUT_DIR)" 2>/dev/null || true
    # Windows の場合、obj に配下がなければ、obj を削除する
    # Remove obj if it's empty (Windows only)
ifeq ($(OS),Windows_NT)
	-rmdir obj 2>/dev/null || true
endif

.PHONY: test
ifeq ($(call should_skip,$(SKIP_TEST)),true)
    # テストのスキップ
    # Skip tests
    # test スキップ時は、ビルドスキップもチェックする
    ifeq ($(call should_skip,$(SKIP_BUILD)),true)
        # test もビルドもスキップ
test:
			@echo "Build & Test skipped (SKIP_BUILD=$(SKIP_BUILD), SKIP_TEST=$(SKIP_TEST))"
    else
        # test はスキップするがビルドはする
        ifndef NO_LINK
test: $(OUTPUT_DIR)/$(TARGET)
				@echo "Test skipped (SKIP_TEST=$(SKIP_TEST))"
        else
            # コンパイルのみ
test: $(OBJS)
				@echo "Test skipped (SKIP_TEST=$(SKIP_TEST))"
        endif
    endif
else
    ifeq ($(call should_skip,$(SKIP_BUILD)),true)
        # そもそもビルドがスキップ
test:
			@echo "Test skipped because it is not included in the build (SKIP_BUILD=$(SKIP_BUILD))"
    else
        # スキップしない
        ifndef NO_LINK
            # テストの実行
            # Run tests
test: $(TESTSH) $(OUTPUT_DIR)/$(TARGET)
				@status=0; \
				export TEST_SRCS="$(TEST_SRCS)" && "$(SHELL)" "$(TESTSH)" > >($(NKF)) 2> >($(NKF) >&2) || status=$$?; \
				exit $$status
        else
            # コンパイルのみ
test: $(OBJS)
        endif
    endif
endif
