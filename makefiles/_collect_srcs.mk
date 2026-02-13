# 入力
# - TEST_SRCS
#   - テストの対象 (カバレッジ対象) のソースファイル
# - ADD_SRCS
#   - フォルダ外にあるソースファイル
# - INCDIR
#   - c_cpp_properties.json に指定のない include

# 出力 (コンパイラ区分)
# - SRCS_C
#   - C のソースファイル
# - SRCS_CPP
#   - C++ のソースファイル

# 出力 (ソースファイルの扱い)
# - DIRECT_SRCS
#   - フォルダに存在するソースファイル
#   - TEST_SRCS, ADD_SRCS に指定されていて、カレントディレクトリに配置されている
# - LINK_SRCS
#   - シンボリックリンクして引き込むソースファイル
#   - Linux にて、inject ファイル および フィルタファイルがない
# - CP_SRCS
#   - フォルダ外からコピーして引き込むソースファイル
#   - inject ファイル または フィルタファイルがある
#   - Windows では、inject ファイル および フィルタファイルがない引き込みファイルも CP_SRCS として扱う

# 出力 (include)
# - INCDIR
#   - c_cpp_properties.json から得た include パスを追加

# 出力 (カバレッジ観点)
# - GCOVR_SRCS
#   - カバレッジ収集対象のソースファイル

# inject, filter 判定
# Determine inject and filter files
CP_SRCS := $(foreach src,$(TEST_SRCS) $(ADD_SRCS), \
	$(if $(or $(wildcard $(notdir $(basename $(src))).inject$(suffix $(src))), \
		$(wildcard $(notdir $(src)).filter.sh)), \
		$(src)))

# DIRECT_SRCS の判定: Make 関数で basename を取得し、1回の shell 呼び出しでまとめて判定
# Determine DIRECT_SRCS: get basenames via Make functions, batch file tests in single shell call
_DIRECT_CANDIDATES := $(filter-out $(CP_SRCS),$(TEST_SRCS) $(ADD_SRCS))
DIRECT_SRCS := $(if $(_DIRECT_CANDIDATES),$(shell for f in $(_DIRECT_CANDIDATES); do \
	b=$${f\#\#*/}; \
	if [ -f "./$$b" ] && [ ! -L "./$$b" ]; then \
		echo $$f; \
	fi; \
	done))

LINK_SRCS := $(filter-out $(CP_SRCS) $(DIRECT_SRCS),$(TEST_SRCS) $(ADD_SRCS))

# 以下の処理は、ADD_SRCS に inject ファイルや filter ファイルを指定するための追加処理
# make 開始時点でファイルが配置されていない場合は、CP_SRCS に正しく移動しきれないファイルがあるため
# This additional process allows specifying inject/filter files under ADD_SRCS before make begins, in case files aren't placed initially

# LINK_SRCS の中から `*.inject.*` に対応する元ファイルを探して CP_SRCS に追加
# Add original files matching `*.inject.*` in LINK_SRCS to CP_SRCS
CP_SRCS += $(foreach f, $(LINK_SRCS), \
	$(if $(findstring .inject.,$(notdir $(f))), \
		$(foreach src, $(filter %$(subst .inject.,.,$(notdir $(f))), $(LINK_SRCS)), $(src))))

# LINK_SRCS の中から `*.filter.sh` に対応する元ファイルを探して CP_SRCS に追加
# Add original files matching `*.filter.sh` in LINK_SRCS to CP_SRCS
CP_SRCS += $(foreach f, $(LINK_SRCS), \
	$(if $(findstring .filter.sh,$(notdir $(f))), \
		$(foreach src, $(filter %$(subst .filter.sh,,$(notdir $(f))), $(LINK_SRCS)), $(src))))

# CP_SRCS の重複排除
# Remove duplicate entries from CP_SRCS
CP_SRCS := $(sort $(CP_SRCS))

# LINK_SRCS から CP_SRCS のファイルを削除
# Remove CP_SRCS files from LINK_SRCS
LINK_SRCS := $(filter-out $(CP_SRCS), $(LINK_SRCS))

# Windows ではシンボリックリンク機能に制限があるため、すべて CP_SRCS 扱いとする
ifeq ($(OS),Windows_NT)
    # Windows
    CP_SRCS += $(LINK_SRCS)
    LINK_SRCS :=
    # Windows ではコピーを行うことにより、inject ファイル および フィルタファイルがないにもかかわらず実体が存在するため、DIRECT_SRCS と判定されることへの対策として、
    # 外部ファイル (実パスがカレントディレクトリと異なるファイル) を DIRECT_SRCS から CP_SRCS に移動する
    # dirname/basename の代わりにシェルパラメータ展開を使用してプロセス生成を削減
    # Use shell parameter expansion instead of dirname/basename to reduce process creation
    EXTERNAL_SRCS := $(shell \
        cur=$$(pwd); \
        for f in $(DIRECT_SRCS); do \
            real_f=$$(cd "$${f%/*}" 2>/dev/null && pwd)/$${f\#\#*/}; \
            if [ "$$real_f" != "$$cur/$${f\#\#*/}" ]; then \
                echo $$f; \
            fi; \
        done)
    CP_SRCS += $(EXTERNAL_SRCS)
    DIRECT_SRCS := $(filter-out $(EXTERNAL_SRCS),$(DIRECT_SRCS))
endif

# gcovr のフィルタを作成
# gcovr では、シンボリックリンクの場合は、実パスを与える必要がある
# Create filters for gcovr (symbolic links require real paths)
GCOVR_SRCS := $(foreach src,$(TEST_SRCS), \
	$(if $(filter $(src),$(LINK_SRCS)), \
		 $(src), \
		 $(notdir $(src))))

# コンパイル対象のソースファイル (カレントディレクトリから自動収集 + 指定ファイル)
# Collect source files for compilation (auto-detect + specified files)
SRCS_C := $(sort $(wildcard *.c) $(notdir $(filter %.c,$(CP_SRCS) $(LINK_SRCS))))
SRCS_CPP := $(sort $(wildcard *.cc) $(wildcard *.cpp) $(notdir $(filter %.cc,$(CP_SRCS) $(LINK_SRCS)) $(filter %.cpp,$(CP_SRCS) $(LINK_SRCS))))

# c_cpp_properties.json から include ディレクトリを得る (get_config.sh に統合)
# Get include directories from c_cpp_properties.json (consolidated into get_config.sh)
INCDIR += $(shell sh $(WORKSPACE_FOLDER)/makefw/cmnd/get_config.sh include_paths)

# INCDIR が指すディレクトリが同じであれば、間引く
# Remove duplicate directories from INCDIR
# 絶対パスに正規化してから重複削除
# Normalize to absolute paths before removing duplicates
# foreach で個別に realpath/cygpath を呼ぶ代わりに、1回のシェルで一括処理
# Batch realpath/cygpath in single shell instead of per-directory foreach
ifneq ($(INCDIR),)
    ifneq ($(OS),Windows_NT)
        # Linux
        INCDIR := $(sort $(shell for d in $(INCDIR); do realpath -m "$$d" 2>/dev/null || echo "$$d"; done))
    else
        # Windows
        # cygpath -m を使って MSYS2 形式から Windows 形式に変換
        # Convert from MSYS2 format to Windows format using cygpath -m
        INCDIR := $(sort $(shell for d in $(INCDIR); do r=$$(realpath -m "$$d" 2>/dev/null || echo "$$d"); cygpath -m "$$r" 2>/dev/null || echo "$$r"; done))
    endif
endif

# デバッグ出力
#$(info ----)
#$(info TEST_SRCS: $(TEST_SRCS))
#$(info ADD_SRCS: $(ADD_SRCS))
#$(info ----)
#$(info DIRECT_SRCS: $(DIRECT_SRCS))
#$(info LINK_SRCS: $(LINK_SRCS))
#$(info CP_SRCS: $(CP_SRCS))
#$(info ----)
#$(info SRCS_C: $(SRCS_C))
#$(info SRCS_CPP: $(SRCS_CPP))
#$(info ----)
#$(info INCDIR: $(INCDIR))
#$(info ----)
#$(info GCOVR_SRCS: $(GCOVR_SRCS))
#$(info ----)
