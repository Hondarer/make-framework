include $(WORKSPACE_FOLDER)/makefw/makefiles/_collect_srcs.mk
include $(WORKSPACE_FOLDER)/makefw/makefiles/_flags.mk

LIBSFILES := $(shell for dir in $(LIBSDIR); do [ -d $$dir ] && find $$dir -maxdepth 1 -type f; done)

# テストライブラリの設定
# Set test libraries
# LINK_TEST が 1 の場合にのみ設定する
ifeq ($(LINK_TEST), 1)
    TEST_LIBS := gtest_main gtest gmock
    ifneq ($(OS),Windows_NT)
        # Linux
        TEST_LIBS += pthread gcov
    endif
    # FIXME: 決め打ちにしているので CONFIG で切替要
    #        Linux 側もここで指定する必要がある
	LIBSDIR += $(WORKSPACE_FOLDER)/testfw/gtest/lib/msvc/v144/x64/md/release
    ifeq ($(NO_GTEST_MAIN), 1)
        TEST_LIBS := $(filter-out gtest_main, $(TEST_LIBS))
    endif
    ifeq ($(USE_WRAP_MAIN), 1)
        TEST_LIBS := $(filter-out gtest_main, $(TEST_LIBS))
    endif
endif
#$(info NO_GTEST_MAIN: $(NO_GTEST_MAIN))
#$(info TEST_LIBS: $(TEST_LIBS))

TESTSH := $(WORKSPACE_FOLDER)/testfw/cmnd/exec_test.sh

GCOVDIR := gcov
LCOVDIR := lcov

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
# テスト対象以外
# For non-test targets
CFLAGS   += $(addprefix -I, $(INCDIR))
CXXFLAGS += $(addprefix -I, $(INCDIR))

# リンクライブラリファイル名の解決
ifneq ($(OS),Windows_NT)
    # Linux
    TEST_LIBS := $(addprefix -l, $(TEST_LIBS))
    LIBS := $(addprefix -l, $(LIBS))
else
    # Windows
    TEST_LIBS := $(addsuffix .lib,$(TEST_LIBS))
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
OBJS := $(filter-out $(OBJDIR)/%.inject.o, \
	$(sort $(addprefix $(OBJDIR)/, \
	$(notdir $(patsubst %.c, %.o, $(patsubst %.cc, %.o, $(patsubst %.cpp, %.o, $(SRCS_C) $(SRCS_CPP))))))))
# DEPS
DEPS := $(patsubst %.o, %.d, $(OBJS))
ifeq ($(OS),Windows_NT)
    # Windows の場合は .o を .obj に置換
    OBJS := $(patsubst %.o, %.obj, $(OBJS))
endif

# 実行体のディレクトリ名と実行体名
# TARGETDIR := . の場合、カレントディレクトリに実行体を生成する
# If TARGETDIR := ., the executable is created in the current directory
ifeq ($(TARGETDIR),)
	TARGETDIR := .
endif
# ディレクトリ名を実行体名にする
# Use directory name as executable name if TARGET is not specified
ifeq ($(TARGET),)
    TARGET := $(shell basename `pwd`)
endif
ifeq ($(OS),Windows_NT)
    # Windows
    TARGET := $(TARGET).exe
endif

ifndef NO_LINK
    # 実行体の生成
    # Build the executable
    ifneq ($(OS),Windows_NT)
        # Linux
$(TARGETDIR)/$(TARGET): $(OBJS) $(LIBSFILES) | $(TARGETDIR)
			set -o pipefail; LANG=$(FILES_LANG) $(LD) $(LDFLAGS) -o $@ $(OBJS) $(LIBS) $(TEST_LIBS) -fdiagnostics-color=always 2>&1 | $(NKF)
    else
        # Windows
$(TARGETDIR)/$(TARGET): $(OBJS) $(LIBSFILES) | $(TARGETDIR)
			set -o pipefail; MSYS_NO_PATHCONV=1 LANG=$(FILES_LANG) $(LD) $(LDFLAGS) /PDB:$(patsubst %.exe,%.pdb,$@) /ILK:$(OBJDIR)/$(patsubst %.exe,%.ilk,$@) /OUT:$@ $(OBJS) $(LIBS) $(TEST_LIBS) 2>&1 | $(NKF)
    endif
else
# コンパイルのみ
# Compile only
$(OBJS): $(LIBSFILES)
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
$$(OBJDIR)/%.o: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR)
		@set -o pipefail; if echo $$(TEST_SRCS) | grep -q $$(notdir $$<); then \
			echo LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -coverage -D_IN_TEST_SRC_ -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
			LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -coverage -D_IN_TEST_SRC_ -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
		else \
			echo LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
			LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)) -c -o $$@ $$< -fdiagnostics-color=always 2>&1 | $$(NKF); \
		fi
else
    # Windows
$$(OBJDIR)/%.obj: %.$(1) $$(OBJDIR)/%.d $$(notdir $$(LINK_SRCS)) $$(notdir $$(CP_SRCS)) | $$(OBJDIR)
		@set -o pipefail; if echo $$(TEST_SRCS) | grep -q $$(notdir $$<); then \
			echo MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) -D_IN_TEST_SRC_ /c /Fo$$@ $$< 2>&1 '|' sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d '|' $$(NKF); \
			MSYS_NO_PATHCONV=1 LANG=$$(FILES_LANG) $$($(2)) $$(DEPFLAGS) $$($(3)_TEST) /FdD:$$(patsubst %.obj,%.pdb,$$@) -D_IN_TEST_SRC_ /c /Fo$$@ $$< 2>&1 | sh $$(WORKSPACE_FOLDER)/makefw/cmnd/msvc_dep.sh $$@ $$< $$(OBJDIR)/$$*.d | $$(NKF); \
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
		echo "echo \"#ifdef _IN_TEST_SRC_\" >> $(1)"; \
		echo "#ifdef _IN_TEST_SRC_" >> $(1); \
		echo "echo \"#include \"$(basename $(1)).inject$(suffix $(1))\"\" >> $(1)"; \
		echo "#include \"$(basename $(1)).inject$(suffix $(1))\"" >> $(1); \
		echo "echo \"#endif // _IN_TEST_SRC_\" >> $(1)"; \
		echo "#endif // _IN_TEST_SRC_" >> $(1); \
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

$(GCOVDIR):
	mkdir -p $@

$(LCOVDIR):
	mkdir -p $@

.PHONY: all
ifndef NO_LINK
    # 実行体の生成
    # Build the executable
    all: $(TARGETDIR)/$(TARGET)
else
    # コンパイルのみ
    # Compile only
    all: $(OBJS) $(LIBSFILES)
endif

.PHONY: clean
clean: clean-cov clean-test
	-rm -rf $(TARGETDIR)/$(TARGET) $(OBJDIR) .gitignore
#   シンボリックリンクされたソース、コピー対象のソースを削除する
#   Remove symbolic-linked or copied source files
	-@if [ -n "$(wildcard $(notdir $(CP_SRCS) $(LINK_SRCS)))" ]; then \
		echo rm -f $(notdir $(CP_SRCS) $(LINK_SRCS)); \
		rm -f $(notdir $(CP_SRCS) $(LINK_SRCS)); \
	fi
#	.gitignore の再生成 (コミット差分が出ないように)
#	Regenerate .gitignore (avoid commit diffs)
	@for ignorefile in $(notdir $(CP_SRCS) $(LINK_SRCS)); \
		do echo $$ignorefile >> .gitignore; \
		tempfile=$$(mktemp) && \
		sort .gitignore | uniq > $$tempfile && \
		mv $$tempfile .gitignore; \
	done
    ifneq ($(OS),Windows_NT)
        # Linux
		-rm -f core
    else
        # Windows
		-rm -f $(patsubst %.exe,%.pdb,$(TARGETDIR)/$(TARGET))
    endif

.PHONY: clean-cov
clean-cov:
    ifneq ($(OS),Windows_NT)
        # Linux
        # カバレッジ情報と、gcov, lcov で生成したファイルを削除する
        # Delete coverage info and files generated by gcov/lcov
		-rm -rf $(OBJDIR)/*.gcda $(OBJDIR)/*.info $(GCOVDIR) $(LCOVDIR)
    endif

.PHONY: clean-test
clean-test:
    ifneq ($(OS),Windows_NT)
        # Linux
        # テスト結果フォルダを削除する
        # Delete test results folder if it exists
		-rm -rf results
    endif

# Check if both variables are empty
ifneq ($(strip $(TEST_SRCS)),)

.PHONY: take-cov
take-cov: take-gcov take-lcov take-gcovr

.PHONY: take-gcovr
take-gcovr:
    ifneq ($(OS),Windows_NT)
        # Linux
        # gcovr (dnf install python3.11 python3.11-pip; pip3.11 install gcovr)
        # If gcovr is available, run coverage. Otherwise skip.
		@if command -v gcovr > /dev/null 2>&1; then \
			#gcovr --exclude-unreachable-branches --cobertura-pretty --output coverage.xml --filter "$(shell echo $(GCOVR_SRCS) | tr ' ' '|')" > /dev/null 2>&1; \
			gcovr --exclude-unreachable-branches --filter "$(shell echo $(GCOVR_SRCS) | tr ' ' '|')"; \
		fi
    else
        # Windows
		@echo "Coverage function not support for Windows."
    endif

.PHONY: take-gcov
take-gcov: $(GCOVDIR)
    ifneq ($(OS),Windows_NT)
        # Linux
        # gcov で生成したファイルを削除する
        # Delete any existing .gcov files
		-rm -rf $(GCOVDIR)/*
        # gcov でカバレッジ情報を取得する
        # Run gcov to collect coverage
        # -bc オプションは可読性に問題があるので、使用しない (lcov の結果で確認可能)
        # Not using -bc for readability, rely on lcov results
        # gcov -bc $(TEST_SRCS) -o $(OBJDIR)
		gcov $(TEST_SRCS) -o $(OBJDIR)
        # カバレッジ未通過の *.gcov ファイルは削除する
        # Delete *.gcov files without coverage
		@if [ -n "$$(ls *.gcov 2>/dev/null)" ]; then \
			for file in *.gcov; do \
				if ! grep -qE '^\s*[0-9]+\*?:' "$$file"; then \
					echo "rm $$file # No coverage data"; \
					rm "$$file"; \
				fi; \
			done \
		fi
		mv *.gcov $(GCOVDIR)/.
    else
        # Windows
		@echo "Coverage function not support for Windows."
    endif

.PHONY: take-lcov
take-lcov: $(LCOVDIR)
    ifneq ($(OS),Windows_NT)
        # Linux
        # lcov で生成したファイルを削除する
        # Delete any existing info files generated by lcov
		-rm -rf $(OBJDIR)/*.info
		-rm -rf $(LCOVDIR)/*
        # lcov でカバレッジ情報を取得する
        # Run lcov to collect coverage
		@if [ -s "$(shell command -v lcov 2> /dev/null)" ]; then \
			echo lcov -d $(OBJDIR) -c -o $(OBJDIR)/$(TARGET).info; \
			lcov -d $(OBJDIR) -c -o $(OBJDIR)/$(TARGET).info; \
		else \
			echo "lcov not found. Skipping."; \
		fi
        # genhtml は空のファイルを指定するとエラーを出力して終了するため
        # lcov の出力ファイルが空でないか確認してから genhtml を実行する
        # genhtml fails on empty files; verify that .info is not empty first
		@if [ -s $(OBJDIR)/$(TARGET).info ]; then \
			echo genhtml --function-coverage -o $(LCOVDIR) $(OBJDIR)/$(TARGET).info; \
			genhtml --function-coverage -o $(LCOVDIR) $(OBJDIR)/$(TARGET).info; \
		else \
			echo "No valid records found in tracefile $(OBJDIR)/$(TARGET).info."; \
		fi
    else
        # Windows
		@echo "Coverage function not support for Windows."
    endif

else

.PHONY: take-cov
take-cov:
#	カバレッジ対象がない場合のメッセージ
#	Message for no coverage targets
	@echo "No target source files for coverage measurement."

.PHONY: take-gcovr
take-gcovr:
	@echo "No target source files for coverage measurement."

.PHONY: take-gcov
take-gcov:
	@echo "No target source files for coverage measurement."

.PHONY: take-lcov
take-lcov:
	@echo "No target source files for coverage measurement."

endif

.PHONY: test
ifndef NO_LINK
# テストの実行
# Run tests
test: $(TESTSH) $(TARGETDIR)/$(TARGET)
	@status=0; \
	export TEST_SRCS="$(TEST_SRCS)" && "$(SHELL)" "$(TESTSH)" > >($(NKF)) 2> >($(NKF) >&2) || status=$$?; \
	$(MAKE) clean-cov; \
	exit $$status
else
# 何もしない
# Do nothing
test: ;
endif
