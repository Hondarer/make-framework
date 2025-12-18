include $(WORKSPACE_FOLDER)/makefw/makefiles/_collect_srcs.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_flags.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_should_skip.mk

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
OBJS := $(filter-out $(OBJDIR)/%.inject.o, \
	$(sort $(addprefix $(OBJDIR)/, \
	$(notdir $(patsubst %.c, %.o, $(patsubst %.cc, %.o, $(patsubst %.cpp, %.o, $(SRCS_C) $(SRCS_CPP))))))))
# DEPS
DEPS := $(patsubst %.o, %.d, $(OBJS))
ifeq ($(OS),Windows_NT)
    # Windows の場合は .o を .obj に置換
    OBJS := $(patsubst %.o, %.obj, $(OBJS))
endif

# LIB_TYPE の設定 (デフォルトは static)
# LIB_TYPE setting (default is static)
# make LIB_TYPE=shared で、shared となる
ifeq ($(LIB_TYPE),)
	LIB_TYPE := static
endif

# アーカイブのディレクトリ名とアーカイブ名
# TARGETDIR := . の場合、カレントディレクトリにアーカイブを生成する
# If TARGETDIR := ., the archive is created in the current directory
ifeq ($(TARGETDIR),)
	TARGETDIR := .
endif
# ディレクトリ名をアーカイブ名にする
# Use directory name as archive name if TARGET is not specified
ifeq ($(TARGET),)
    TARGET := $(shell basename `pwd`)
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
    ifeq ($(LIB_TYPE),shared)
        TARGET := $(TARGET).dll
    else
        TARGET := $(TARGET).lib
    endif
endif

# デフォルトターゲットの設定
# Default target setting
ifeq ($(call should_skip,$(SKIP_BUILD)),true)
    .DEFAULT_GOAL := skip_build
else
    .DEFAULT_GOAL := $(TARGETDIR)/$(TARGET)
endif

.PHONY: skip_build
skip_build:
	@echo "Build skipped (SKIP_BUILD=$(SKIP_BUILD))"

# ライブラリファイルの解決（LIB_TYPE=shared かつ LIBS が定義されている場合のみ）
# Resolve library files (only when LIB_TYPE=shared and LIBS is defined)
ifeq ($(LIB_TYPE),shared)
    ifneq ($(LIBS),)

        #$(info LIBS: $(LIBS))
        #$(info LIBSDIR: $(LIBSDIR))

        # 現在ビルド中のライブラリ名を取得 (拡張子なし)
        # Get the name of the library currently being built (without extension)
        ifeq ($(OS),Windows_NT)
            CURRENT_LIB := $(basename $(TARGET))
        else
            CURRENT_LIB := $(patsubst lib%.a,%,$(TARGET))
        endif

        # 静的ライブラリファイルの検索
        # Search for static library files
        ifeq ($(OS),Windows_NT)
            # Windows: .lib を検索
            # 自身を除外し、複数の LIBSDIR を考慮
            # Windows: search for .lib
            # Exclude self and consider multiple LIBSDIR
            STATIC_LIBS := $(foreach lib,$(filter-out $(CURRENT_LIB),$(LIBS)),\
                $(firstword $(foreach dir,$(LIBSDIR),$(wildcard $(dir)/$(lib).lib))))
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
            FOUND_LIBS := $(notdir $(basename $(STATIC_LIBS)))
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

# 最終的なリンクコマンド
# Final link command: static libs are embedded, dynamic libs remain as -l
ifeq ($(LIB_TYPE),shared)
    ifneq ($(OS),Windows_NT)
        # Linux
$(TARGETDIR)/$(TARGET): $(OBJS) $(STATIC_LIBS) | $(TARGETDIR)
			"$(CC)" -shared -o $@ $(OBJS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS)
    else
        # Windows
$(TARGETDIR)/$(TARGET): $(OBJS) $(STATIC_LIBS) | $(TARGETDIR)
		"$(LD)" /DLL /OUT:$@ $(OBJS) $(STATIC_LIBS) $(DYNAMIC_LIBS) $(LDFLAGS)
		@if [ -f "$(TARGETDIR)/$(patsubst %.dll,%.exp,$(TARGET))" ]; then mv "$(TARGETDIR)/$(patsubst %.dll,%.exp,$(TARGET))" "$(OBJDIR)/"; fi
    endif
else
    ifneq ($(OS),Windows_NT)
        # Linux
$(TARGETDIR)/$(TARGET): $(OBJS) | $(TARGETDIR)
			"$(AR)" rvs $@ $(OBJS)
    else
        # Windows
$(TARGETDIR)/$(TARGET): $(OBJS) | $(TARGETDIR)
			"$(AR)" /NOLOGO /OUT:$@ $(OBJS)
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
$$(OBJDIR)/%.o: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR) $$(TARGETDIR)
		set -o pipefail; LANG=$$(FILES_LANG) "$$($(2))" $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF)
else
    # Windows
$$(OBJDIR)/%.obj: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR) $$(TARGETDIR)
		set -o pipefail; MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) "$$($(2))" $$(DEPFLAGS) $$($(3)) /FdD:$$(patsubst %.obj,%.pdb,$$@) /c /Fo:$$@ $$< 2>&1 | sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d | $$(NKF)
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
	echo $(1) >> .gitignore
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
#	.gitignore に対象ファイルを追加
#	Add the file to .gitignore
	echo $(1) >> .gitignore
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

$(TARGETDIR):
	mkdir -p $@

$(OBJDIR):
	mkdir -p $@

# 削除対象の定義
# Define files/directories to clean
CLEAN_COMMON := $(TARGETDIR)/$(TARGET) $(OBJDIR) $(notdir $(CP_SRCS) $(LINK_SRCS))
ifeq ($(OS),Windows_NT)
    # Windows
    CLEAN_OS := $(TARGETDIR)/$(patsubst %.dll,%.pdb,$(TARGET))
    ifeq ($(LIB_TYPE),shared)
        CLEAN_OS += $(TARGETDIR)/$(patsubst %.dll,%.lib,$(TARGET))
    endif
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
			do echo $$ignorefile >> $$tempfile; \
		done && \
		sort $$tempfile | uniq > $$tempfile2 && \
		mv $$tempfile2 .gitignore && \
		rm -f $$tempfile
    endif
	-rm -rf $(CLEAN_COMMON) $(CLEAN_OS)

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
test: $(TARGETDIR)/$(TARGET)
			@echo "Test skipped (SKIP_TEST=$(SKIP_TEST))"
    endif
else
    ifeq ($(call should_skip,$(SKIP_BUILD)),true)
        # そもそもビルドがスキップ
test:
			@echo "Test skipped because it is not included in the build (SKIP_BUILD=$(SKIP_BUILD))"
    else
        # スキップしない
test: $(TARGETDIR)/$(TARGET)
    endif
endif
